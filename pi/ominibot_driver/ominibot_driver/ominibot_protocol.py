#!/usr/bin/env python3
# coding=utf-8
"""OminiBot HV 串列協定層(純協定,不依賴 ROS)。

協定來源:官方文件 https://github.com/iCShopMgr/OminiBotHV(Circus Pi)
本車為三顆全向輪(MOTO1~3),UART 115200;板子收到 10 bytes 後
自動由 APP 模式切換為 UART 控制模式,不需額外初始化。

速度控制幀(Mode=1,固定 10 bytes):
    TX[0..1] 0xFF 0xFE 幀頭
    TX[2]    0x01(速度控制)
    TX[3,4]  X 軸速度(左右平移),16-bit 無號,高位元在前
    TX[5,6]  Y 軸速度(前後)
    TX[7,8]  Z 軸速度(旋轉;TX[9] bit4=1 時為角度,900=90.0°)
    TX[9]    方向位元:bit2=X 反轉、bit1=Y 反轉、bit0=Z 反轉、bit4=角度模式
    範例:Y 軸前進 300 → FF FE 01 00 00 01 2C 00 00 00

編碼器回授幀(System mode bit6=1 時板子主動回傳):
    0x24, 目標A, 實際A, 目標B, 實際B, 目標C, 實際C, [目標D, 實際D], 0x19
    每值有號 32-bit,高位元在前;三輪幀長 26 bytes、四輪 34 bytes。

直接執行本檔即進入測試模式(不經 ROS,實機驗證用;輪子先架空!):
    python3 ominibot_protocol.py --port /dev/ominibot --y 200 --duration 1
    python3 ominibot_protocol.py --port /dev/ominibot --listen 5
"""
import struct
import threading
import time

import serial


class OminibotHV:
    """OminiBot HV 串列通訊:速度指令發送 + 編碼器回授解析"""

    FRAME_HEAD = b"\xFF\xFE"
    ENC_HEAD = 0x24   # '$'
    ENC_TAIL = 0x19

    def __init__(self, port, baud=115200, timeout=0.5):
        self.serial = serial.Serial(port, baud, timeout=timeout)
        self._lock = threading.Lock()      # 寫入互斥(指令可能來自多執行緒)
        self._stop_event = threading.Event()
        self._reader_thread = None
        # 最新編碼器值:[(目標, 實際), ...] 每輪一組,有號 32-bit raw
        self.encoder = None

    def close(self):
        """停止讀取執行緒、送停車幀並關閉串列埠"""
        self._stop_event.set()
        if self._reader_thread:
            self._reader_thread.join(timeout=2)
            self._reader_thread = None
        try:
            self.stop()
        except serial.SerialException:
            pass
        self.serial.close()

    # ------------------------------------------------------------------
    # 指令發送
    # ------------------------------------------------------------------

    def send_velocity(self, x, y, z):
        """送速度幀。參數為板子座標的 raw 值(int,正負代表方向):

        x = 左右平移、y = 前後、z = 旋轉(對應 ROS 軸向的轉換在節點層做)。
        數值取絕對值填 16-bit 無號欄位,負號填方向位元(1=反轉)。
        """
        x, y, z = (int(max(-65535, min(65535, v))) for v in (x, y, z))
        direction = ((4 if x < 0 else 0)
                     | (2 if y < 0 else 0)
                     | (1 if z < 0 else 0))
        packet = (self.FRAME_HEAD + b"\x01"
                  + struct.pack(">H", abs(x))
                  + struct.pack(">H", abs(y))
                  + struct.pack(">H", abs(z))
                  + struct.pack(">B", direction))
        with self._lock:
            self.serial.write(packet)

    def stop(self):
        """停車(全零速度幀)"""
        self.send_velocity(0, 0, 0)

    def rotate_angle(self, decidegrees):
        """旋轉指定角度(bit4 角度模式;900 = 90.0°,正=正轉、負=反轉)"""
        a = int(max(-65535, min(65535, decidegrees)))
        direction = 0x10 | (1 if a < 0 else 0)
        packet = (self.FRAME_HEAD + b"\x01"
                  + struct.pack(">H", 0) + struct.pack(">H", 0)
                  + struct.pack(">H", abs(a))
                  + struct.pack(">B", direction))
        with self._lock:
            self.serial.write(packet)

    # ------------------------------------------------------------------
    # 編碼器回授接收(需先以設定幀開啟 System mode bit6;預設關閉)
    # ------------------------------------------------------------------

    def start_reader(self, on_encoder=None):
        """背景執行緒解析編碼器回授幀。

        on_encoder(values):values 為 [(目標, 實際), ...](每輪一組 raw 值)
        """
        def loop():
            buf = bytearray()
            while not self._stop_event.is_set():
                try:
                    chunk = self.serial.read(64)
                except serial.SerialException:
                    break
                if chunk:
                    buf.extend(chunk)
                # 掃描緩衝區找 0x24 ... 0x19 幀(三輪 26 bytes、四輪 34 bytes)
                while buf:
                    if buf[0] != self.ENC_HEAD:
                        buf.pop(0)
                        continue
                    frame_len = None
                    for n_motor, length in ((3, 26), (4, 34)):
                        if len(buf) >= length and buf[length - 1] == self.ENC_TAIL:
                            frame_len = length
                            n = n_motor
                            break
                    if frame_len is None:
                        if len(buf) >= 34:
                            buf.pop(0)   # 對不上幀尾:丟掉這個頭重新同步
                            continue
                        break            # 資料還不夠,等下一批
                    payload = bytes(buf[1:frame_len - 1])
                    del buf[:frame_len]
                    raw = struct.unpack(f">{n * 2}i", payload)
                    values = [(raw[i * 2], raw[i * 2 + 1]) for i in range(n)]
                    self.encoder = values
                    if on_encoder:
                        on_encoder(values)
        self._reader_thread = threading.Thread(target=loop, daemon=True)
        self._reader_thread.start()


# ----------------------------------------------------------------------
# 測試模式:不經 ROS 直接驗證硬體與協定
# ----------------------------------------------------------------------

def _main():
    import argparse
    parser = argparse.ArgumentParser(description="OminiBot HV 協定測試工具(輪子先架空!)")
    parser.add_argument("--port", default="/dev/ominibot")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--x", type=int, default=0, help="左右平移速度(raw)")
    parser.add_argument("--y", type=int, default=0, help="前後速度(raw,正=前進)")
    parser.add_argument("--z", type=int, default=0, help="旋轉速度(raw)")
    parser.add_argument("--duration", type=float, default=1.0, help="持續秒數")
    parser.add_argument("--listen", type=float, default=0,
                        help="只監聽編碼器回授 N 秒(不送指令;需板子已開 bit6)")
    args = parser.parse_args()

    bot = OminibotHV(args.port, args.baud)
    try:
        if args.listen > 0:
            bot.start_reader(on_encoder=lambda v: print("encoder:", v))
            time.sleep(args.listen)
        else:
            print(f"send x={args.x} y={args.y} z={args.z} for {args.duration}s")
            end = time.time() + args.duration
            while time.time() < end:
                bot.send_velocity(args.x, args.y, args.z)
                time.sleep(0.05)   # 20 Hz
            print("stop")
    finally:
        bot.close()


if __name__ == "__main__":
    _main()
