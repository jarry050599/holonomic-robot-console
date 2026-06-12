#!/usr/bin/env python3
# coding=utf-8
"""OminiBot HV v1.2 串列協定層(大括號協定;純協定,不依賴 ROS)。

⚠ 重要:GitHub iCShopMgr/OminiBotHV 的 2020 PDF(FF FE 幀頭)是舊韌體,
對本板無效!本板用「大括號協定」,權威參考實作:OminiBot_HV_Meca.py
(出土自舊 SD 卡,2026-06-12 實機驗證輪子會轉),本檔幀格式照抄該檔。

幀格式:0x7B('{') + cmd + 資料 + BCC + 0x7D('}'),固定 14 bytes
    BCC = 幀尾前所有 bytes 的 XOR
    0x23 系統設定、0x24 車體尺寸、0x40 PID(建構子初始化順序:
    forced_stop → 0.5s → 0x23 → 0.1s → 0x24 → 0.1s → 0x40 → 0.1s)
    0x25 整車速度:7B 25 02 mode lx(2) ly(2) az(2) 00 00 BCC 7D
        速度 = m/s × 1000,有號 16-bit BE;第 3 byte 0x00 = 強制停止
    0x26 單顆馬達、0x33/0x34/0x50 讀回設定/狀態

板子主動串流遙測幀(32 bytes):
    7B 00 | lx ly az(各 int16,m/s×1000) | IMU 20 bytes
    (末 8 bytes 為四元數 qw qx qy qz,×1000) | 電池 2 bytes | BCC | 7D

測試模式(輪子先架空!):
    python3 ominibot_protocol.py --port /dev/ominibot --read 3
    python3 ominibot_protocol.py --port /dev/ominibot --x 0.08 --duration 2
"""
import struct
import threading
import time

import serial


class OminibotHV:
    """OminiBot HV v1.2 大括號協定(API 與 OminiBot_HV_Meca.py 的 ominibothv 相同)"""

    def __init__(self, port="/dev/ominibot", baud=115200,
                 divisor_mode=4, motor_direct=0, encoder_direct=10,
                 motor_pwm_max=3600, motor_pwm_min=2100, encoder_ppr=165,
                 wheel_space=110, axle_space=110, gear_ratio=55, wheel_diameter=60,
                 pos_kp=3000, pos_ki=1050, pos_kd=0, vel_kp=3000, vel_ki=1050):
        self.ser = serial.Serial(port, baud, timeout=0.5)
        self.robot_mode = divisor_mode
        self._lock = threading.Lock()
        self._stop_event = threading.Event()
        self._reader_thread = None

        # --- 初始化順序(照參考實作) ---
        self.forced_stop()
        time.sleep(0.5)
        # 0x23 系統設定(馬達方向/編碼器方向/PWM 範圍/編碼器 PPR)
        self._send_frame(0x23,
                         motor_direct.to_bytes(1, "big")
                         + encoder_direct.to_bytes(1, "big")
                         + motor_pwm_max.to_bytes(2, "big")
                         + motor_pwm_min.to_bytes(2, "big")
                         + encoder_ppr.to_bytes(2, "big")
                         + b"\x00\x00")
        time.sleep(0.1)
        # 0x24 車體尺寸(輪距/軸距/齒比/輪徑 mm)
        self._send_frame(0x24,
                         wheel_space.to_bytes(2, "big")
                         + axle_space.to_bytes(2, "big")
                         + gear_ratio.to_bytes(2, "big")
                         + wheel_diameter.to_bytes(2, "big")
                         + b"\x00\x00")
        time.sleep(0.1)
        # 0x40 PID
        self._send_frame(0x40,
                         pos_kp.to_bytes(2, "big") + pos_ki.to_bytes(2, "big")
                         + pos_kd.to_bytes(2, "big")
                         + vel_kp.to_bytes(2, "big") + vel_ki.to_bytes(2, "big"))
        time.sleep(0.1)

    # ------------------------------------------------------------------
    # 幀組裝
    # ------------------------------------------------------------------

    @staticmethod
    def calculate_bcc(data):
        bcc = 0
        for byte in data:
            bcc ^= byte
        return bcc

    def _send_frame(self, cmd, payload):
        """7B + cmd + payload + BCC + 7D"""
        frame = bytearray(b"\x7b") + bytes([cmd]) + payload
        frame += self.calculate_bcc(frame).to_bytes(1, "big") + b"\x7d"
        with self._lock:
            self.ser.write(frame)

    @staticmethod
    def _s16(value):
        """m/s(或 rad/s)→ ×1000 有號 16-bit BE(同參考的 pack('!i')[2:])"""
        return struct.pack("!i", int(value * 1000))[2:]

    # ------------------------------------------------------------------
    # 駕駛指令
    # ------------------------------------------------------------------

    def robot_speed(self, lx, ly, az):
        """整車速度:lx 前後 m/s、ly 左右 m/s、az 旋轉 rad/s(板子做運動學)"""
        self._send_frame(0x25, b"\x02" + bytes([self.robot_mode])
                         + self._s16(lx) + self._s16(ly) + self._s16(az)
                         + b"\x00\x00")

    def motor_speed(self, m1, m2, m3, m4):
        """單顆馬達速度(除錯用)"""
        self._send_frame(0x26, b"\x02" + bytes([self.robot_mode])
                         + self._s16(m1) + self._s16(m2)
                         + self._s16(m3) + self._s16(m4))

    def forced_stop(self):
        """強制停止(0x25 第 3 byte = 0x00)"""
        self._send_frame(0x25, b"\x00" + bytes([self.robot_mode])
                         + b"\x00" * 8)

    # ------------------------------------------------------------------
    # 遙測串流解析(板子主動廣播,32 bytes/幀)
    # ------------------------------------------------------------------

    FRAME_LEN = 32   # 7B 00 vel(6) imu(20) bat(2) BCC 7D

    def start_reader(self, on_telemetry=None):
        """背景解析遙測幀。on_telemetry(dict):
        vx, vy, wz(m/s, rad/s)、quat(qw,qx,qy,qz)、battery_raw、bcc_ok
        """
        def loop():
            buf = bytearray()
            while not self._stop_event.is_set():
                try:
                    chunk = self.ser.read(64)
                except serial.SerialException:
                    break
                if chunk:
                    buf.extend(chunk)
                while buf:
                    if buf[0] != 0x7B:
                        buf.pop(0)
                        continue
                    if len(buf) < self.FRAME_LEN:
                        break
                    if buf[self.FRAME_LEN - 1] != 0x7D:
                        buf.pop(0)   # 假幀頭,重新同步
                        continue
                    frame = bytes(buf[:self.FRAME_LEN])
                    del buf[:self.FRAME_LEN]
                    bcc_ok = self.calculate_bcc(frame[:30]) == frame[30]
                    s16 = lambda i: int.from_bytes(frame[i:i + 2], "big", signed=True)
                    telemetry = {
                        "vx": s16(2) / 1000, "vy": s16(4) / 1000, "wz": s16(6) / 1000,
                        # IMU 區段 20 bytes 從 offset 8;四元數在其後段 [12:20]
                        "quat": (s16(20) / 1000, s16(22) / 1000,
                                 s16(24) / 1000, s16(26) / 1000),   # qw qx qy qz
                        "battery_raw": int.from_bytes(frame[28:30], "big"),
                        "bcc_ok": bcc_ok,
                    }
                    if on_telemetry:
                        on_telemetry(telemetry)
        self._reader_thread = threading.Thread(target=loop, daemon=True)
        self._reader_thread.start()

    def close(self):
        """停止讀取、煞車並關埠"""
        self._stop_event.set()
        if self._reader_thread:
            self._reader_thread.join(timeout=2)
            self._reader_thread = None
        try:
            self.forced_stop()
        except serial.SerialException:
            pass
        self.ser.close()

    # 與參考實作同名的別名
    serial_close = close


# 參考實作的類別名稱別名
ominibothv = OminibotHV


# ----------------------------------------------------------------------
# 測試模式
# ----------------------------------------------------------------------

def _main():
    import argparse
    parser = argparse.ArgumentParser(description="OminiBot HV v1.2 協定測試(輪子先架空!)")
    parser.add_argument("--port", default="/dev/ominibot")
    parser.add_argument("--x", type=float, default=0.0, help="前後 m/s")
    parser.add_argument("--y", type=float, default=0.0, help="左右 m/s")
    parser.add_argument("--z", type=float, default=0.0, help="旋轉 rad/s")
    parser.add_argument("--duration", type=float, default=1.0)
    parser.add_argument("--read", type=float, default=0, help="只讀遙測 N 秒")
    args = parser.parse_args()

    bot = OminibotHV(port=args.port)
    print("初始化完成(forced_stop + 0x23/0x24/0x40)")
    try:
        if args.read > 0:
            count = [0]
            def show(t):
                count[0] += 1
                if count[0] % 10 == 1:
                    print(f"vel=({t['vx']:+.3f},{t['vy']:+.3f},{t['wz']:+.3f}) "
                          f"quat={t['quat']} bat_raw={t['battery_raw']} bcc={'✓' if t['bcc_ok'] else '✗'}")
            bot.start_reader(on_telemetry=show)
            time.sleep(args.read)
            print(f"共收到 {count[0]} 幀遙測")
        else:
            print(f"robot_speed({args.x}, {args.y}, {args.z}) for {args.duration}s")
            end = time.time() + args.duration
            while time.time() < end:
                bot.robot_speed(args.x, args.y, args.z)
                time.sleep(0.05)   # 20 Hz
            print("forced_stop")
    finally:
        bot.close()


if __name__ == "__main__":
    _main()
