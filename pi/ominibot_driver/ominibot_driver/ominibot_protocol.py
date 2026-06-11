#!/usr/bin/env python3
# coding=utf-8
"""Ominibot HV 串列協定層(純協定,不依賴 ROS)。

協定來源:iCShop/CIRCUS Pi 官方 ROSKY repo 的 ominibot_car_com.py
(https://github.com/CIRCUSPi/ROSKY),本檔重新實作並修正上游
omnibot() 內 Vy/Vz 誤用 abs(Vx) 的 bug。

速度封包(全向輪模式,板子內建運動學):
    FF FE 01 | Vx(int16 BE) | Vy(int16 BE) | Vz(int16 BE) | 方向位元組
    三軸速度都送絕對值;方向位元組:
        bit2 = Vx 反向(Vx < 0 時設 1)
        bit1 = Vy 反向(Vy < 0 時設 1)
        bit0 = Vz 方向(Vz >= 0 時設 1,沿用上游/韌體慣例)

自動回報訊框(板子主動發送):
    FF FA + 13 bytes:IMU(accel x/y/z、gyro x/y/z 各 int16 BE + seq)
    FF FB +  9 bytes:編碼器(4 輪 int16 BE + seq)
    FF FC +  5 bytes:電池(電壓 int16 BE、功率 int16 BE、seq)

直接執行本檔即進入測試模式(不經 ROS,驗證硬體用),例:
    python3 ominibot_protocol.py --port /dev/ominibot --vx 300 --duration 1.5
    python3 ominibot_protocol.py --port /dev/ominibot --listen 10
"""
import struct
import threading
import time

import serial


class OminibotProtocol:
    """Ominibot HV 串列通訊:速度指令發送 + 自動回報訊框解析"""

    # 自動回報訊框:type byte → 後續資料長度
    AUTO_FRAME_LEN = {0xFA: 13, 0xFB: 9, 0xFC: 5}

    def __init__(self, port, baud=115200, timeout=0.5):
        self.serial = serial.Serial(port, baud, timeout=timeout)
        self._lock = threading.Lock()      # 寫入互斥(指令可能來自多執行緒)
        self._stop_event = threading.Event()
        self._reader_thread = None
        # 最新的電池資料:(電壓 raw, 功率 raw);電壓 raw 推測為 0.01V 單位
        self.battery = None

    def close(self):
        """停止讀取執行緒、送停車指令並關閉串列埠"""
        self._stop_event.set()
        if self._reader_thread:
            self._reader_thread.join(timeout=2)
            self._reader_thread = None
        try:
            self.send_velocity(0, 0, 0)
        except serial.SerialException:
            pass
        self.serial.close()

    # ------------------------------------------------------------------
    # 指令發送
    # ------------------------------------------------------------------

    def send_velocity(self, vx, vy, vz):
        """送全向輪速度指令;單位為韌體 raw 值(int),正負代表方向。

        夾在 ±32767(上游宣稱 0~65535,但封包用 int16,取安全範圍)。
        """
        vx, vy, vz = (int(max(-32767, min(32767, v))) for v in (vx, vy, vz))
        direction = ((4 if vx < 0 else 0)
                     | (2 if vy < 0 else 0)
                     | (1 if vz >= 0 else 0))
        packet = (b"\xFF\xFE\x01"
                  + struct.pack(">h", abs(vx))
                  + struct.pack(">h", abs(vy))
                  + struct.pack(">h", abs(vz))
                  + struct.pack(">B", direction))
        with self._lock:
            self.serial.write(packet)

    def stop(self):
        """停車(零速度)"""
        self.send_velocity(0, 0, 0)

    # ------------------------------------------------------------------
    # 自動回報訊框接收
    # ------------------------------------------------------------------

    def start_reader(self, on_battery=None, on_frame=None):
        """背景執行緒解析自動回報訊框。

        on_battery(voltage_raw, power_raw):收到電池訊框時呼叫
        on_frame(frame_type, payload bytes):收到任何訊框時呼叫(除錯用)
        """
        def loop():
            while not self._stop_event.is_set():
                try:
                    head = self.serial.read(1)
                    if head != b"\xFF":
                        continue   # 不同步:丟棄直到看到 head
                    ftype = self.serial.read(1)
                    if len(ftype) != 1 or ftype[0] not in self.AUTO_FRAME_LEN:
                        continue
                    payload = self.serial.read(self.AUTO_FRAME_LEN[ftype[0]])
                    if len(payload) != self.AUTO_FRAME_LEN[ftype[0]]:
                        continue
                    if ftype[0] == 0xFC:
                        voltage = struct.unpack(">h", payload[0:2])[0]
                        power = struct.unpack(">h", payload[2:4])[0]
                        self.battery = (voltage, power)
                        if on_battery:
                            on_battery(voltage, power)
                    if on_frame:
                        on_frame(ftype[0], payload)
                except serial.SerialException:
                    break
        self._reader_thread = threading.Thread(target=loop, daemon=True)
        self._reader_thread.start()


# ----------------------------------------------------------------------
# 測試模式:不經 ROS 直接驗證硬體與協定
# ----------------------------------------------------------------------

def _main():
    import argparse
    parser = argparse.ArgumentParser(description="Ominibot HV 協定測試工具")
    parser.add_argument("--port", default="/dev/ominibot")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--vx", type=int, default=0, help="前後速度(raw,正=前)")
    parser.add_argument("--vy", type=int, default=0, help="左右平移(raw,正=左)")
    parser.add_argument("--vz", type=int, default=0, help="旋轉(raw,正=逆時針)")
    parser.add_argument("--duration", type=float, default=1.0, help="持續秒數")
    parser.add_argument("--listen", type=float, default=0,
                        help="只監聽自動回報訊框 N 秒(不送指令)")
    args = parser.parse_args()

    bot = OminibotProtocol(args.port, args.baud)
    try:
        if args.listen > 0:
            # 監聽模式:印出所有訊框,確認板子有在說話
            def show(ftype, payload):
                print(f"frame 0x{ftype:02X}: {payload.hex()}")
            def show_batt(v, p):
                print(f"battery: voltage_raw={v}(≈{v / 100:.2f} V?) power_raw={p}")
            bot.start_reader(on_battery=show_batt, on_frame=show)
            time.sleep(args.listen)
        else:
            # 速度模式:以 10 Hz 連發指令 duration 秒後停車
            print(f"send vx={args.vx} vy={args.vy} vz={args.vz} for {args.duration}s")
            end = time.time() + args.duration
            while time.time() < end:
                bot.send_velocity(args.vx, args.vy, args.vz)
                time.sleep(0.1)
            print("stop")
    finally:
        bot.close()


if __name__ == "__main__":
    _main()
