#!/usr/bin/env python3
# coding=utf-8
"""OminiBot HV 串列協定層(純協定,不依賴 ROS)。

協定來源:官方 OminiBotHV_protocol.pdf(github.com/iCShopMgr/OminiBotHV)
本車為三顆全向輪(System mode bit1:0 = 0),UART2 115200;
板子收到 10 bytes 後自動由 APP 模式切換為 UART 控制,不需初始化。

速度控制幀(1A-1,Mode=1,固定 10 bytes):
    FF FE 01 | X(u16 BE) | Y(u16 BE) | Z(u16 BE) | 方向位元組
    方向位元組:bit2=X 反轉、bit1=Y 反轉、bit0=Z 反轉、bit4=角度模式
    範例:Y 軸前進 300 → FF FE 01 00 00 01 2C 00 00 00

設定幀(2 章,Mode=0x80):FF FE 80 80 <子命令> <資料 4 bytes> 00
    寫 System mode:子命令 0x09,資料 = 32-bit 值(高位元組在前)
    讀 System mode:子命令 0x19,回覆 6 bytes:0x23 0x09 B3 B2 B1 B0
    ※ System mode bit6(編碼器回傳)與 bit7(命令模式)「不能記憶」,
      斷電重置,因此執行期讀-改-寫 bit6 不會動到板子存檔設定。

編碼器回授幀(bit6=1 時主動回傳):
    0x24, 目標A,實際A, 目標B,實際B, 目標C,實際C, [目標D,實際D], 0x19
    每值有號 32-bit BE;三輪幀長 26 bytes、四輪 34 bytes。

直接執行本檔即進入測試模式(不經 ROS,實機驗證用;輪子先架空!):
    python3 ominibot_protocol.py --port /dev/ominibot --y 100 --duration 1
    python3 ominibot_protocol.py --port /dev/ominibot --read-mode
    python3 ominibot_protocol.py --port /dev/ominibot --listen 5
"""
import struct
import threading
import time

import serial


class OminibotHV:
    """OminiBot HV 串列通訊:速度指令、設定讀寫、編碼器回授解析"""

    ENC_HEAD = 0x24    # '$' 編碼器幀頭
    ENC_TAIL = 0x19
    REPLY_HEAD = 0x23  # '#' 設定讀取回覆

    def __init__(self, port, baud=115200, timeout=0.1):
        self.serial = serial.Serial(port, baud, timeout=timeout)
        self._lock = threading.Lock()       # 寫入互斥
        self._stop_event = threading.Event()
        self._reader_thread = None
        self.encoder = None                 # 最新編碼器值 [(目標, 實際), ...]
        self._replies = {}                  # 設定讀取回覆:tag → (value, time)

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
    # 速度指令(1A-1)
    # ------------------------------------------------------------------

    def send_velocity(self, x, y, z):
        """送速度幀。參數為板子座標 raw 值(int,正負代表方向):
        x=左右平移、y=前後、z=旋轉(ROS 軸向轉換在節點層做)。
        """
        x, y, z = (int(max(-65535, min(65535, v))) for v in (x, y, z))
        direction = ((4 if x < 0 else 0)
                     | (2 if y < 0 else 0)
                     | (1 if z < 0 else 0))
        packet = (b"\xFF\xFE\x01"
                  + struct.pack(">HHH", abs(x), abs(y), abs(z))
                  + struct.pack(">B", direction))
        with self._lock:
            self.serial.write(packet)

    def stop(self):
        """停車(全零速度幀)"""
        self.send_velocity(0, 0, 0)

    def rotate_angle(self, decidegrees):
        """角度模式旋轉(bit4=1;900 = 90.0°)。角度會累計,用完自動歸零。"""
        a = int(max(-65535, min(65535, decidegrees)))
        packet = (b"\xFF\xFE\x01"
                  + struct.pack(">HHH", 0, 0, abs(a))
                  + struct.pack(">B", 0x10 | (1 if a < 0 else 0)))
        with self._lock:
            self.serial.write(packet)

    # ------------------------------------------------------------------
    # 設定幀(2 章):讀-改-寫 System mode 開啟編碼器回傳
    # ------------------------------------------------------------------

    def _send_setting_frame(self, sub, data=b"\x00\x00\x00\x00"):
        packet = b"\xFF\xFE\x80\x80" + bytes([sub]) + data + b"\x00"
        with self._lock:
            self.serial.write(packet)

    def read_setting(self, sub, reply_tag, timeout=1.0):
        """送讀取幀(2C 節)並等回覆;回傳 32-bit 值,逾時回 None。
        注意:回覆 tag 與請求子命令不同(例:讀 System mode 用 0x19,回覆 tag 0x09)。
        需先 start_reader()。
        """
        self._replies.pop(reply_tag, None)
        self._send_setting_frame(sub)
        deadline = time.time() + timeout
        while time.time() < deadline:
            if reply_tag in self._replies:
                return self._replies[reply_tag]
            time.sleep(0.02)
        return None

    def read_system_mode(self, timeout=1.0):
        """讀 System mode(2C-9:子命令 0x19 → 回覆 tag 0x09)"""
        return self.read_setting(0x19, 0x09, timeout)

    def write_system_mode(self, value):
        """寫 System mode(2B-9,子命令 0x09)。
        不另做「寫入設定值」存檔,bit6/bit7 本來就不能記憶,
        其餘位元維持讀到的原值,不影響板子既有設定。
        """
        self._send_setting_frame(0x09, struct.pack(">I", value & 0xFFFFFFFF))

    def enable_encoder_feedback(self):
        """讀-改-寫開啟編碼器回傳(bit6)。成功回 True,讀不到板子回 False。"""
        mode = self.read_system_mode()
        if mode is None:
            return False
        if not (mode & 0x40):
            self.write_system_mode(mode | 0x40)
        return True

    # ------------------------------------------------------------------
    # 接收執行緒:編碼器幀(0x24…0x19)與設定回覆(0x23 + tag + 4 bytes)
    # ------------------------------------------------------------------

    def start_reader(self, on_encoder=None):
        """背景解析板子回傳。on_encoder(values):每輪 (目標, 實際) raw 值。"""
        def loop():
            buf = bytearray()
            while not self._stop_event.is_set():
                try:
                    chunk = self.serial.read(64)
                except serial.SerialException:
                    break
                if chunk:
                    buf.extend(chunk)
                while buf:
                    if buf[0] == self.REPLY_HEAD:
                        if len(buf) < 6:
                            break
                        tag = buf[1]
                        self._replies[tag] = struct.unpack(">I", bytes(buf[2:6]))[0]
                        del buf[:6]
                    elif buf[0] == self.ENC_HEAD:
                        frame = self._try_encoder_frame(buf)
                        if frame is None:
                            if len(buf) >= 34:
                                buf.pop(0)   # 對不上幀尾:重新同步
                                continue
                            break            # 等更多資料
                        self.encoder = frame
                        if on_encoder:
                            on_encoder(frame)
                    else:
                        buf.pop(0)
        self._reader_thread = threading.Thread(target=loop, daemon=True)
        self._reader_thread.start()

    def _try_encoder_frame(self, buf):
        """嘗試從緩衝區頭解析編碼器幀;成功則消耗位元組並回傳值,不足回 None"""
        for n_motor, length in ((3, 26), (4, 34)):
            if len(buf) >= length and buf[length - 1] == self.ENC_TAIL:
                raw = struct.unpack(f">{n_motor * 2}i", bytes(buf[1:length - 1]))
                del buf[:length]
                return [(raw[i * 2], raw[i * 2 + 1]) for i in range(n_motor)]
        return None


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
                        help="開編碼器回傳並監聽 N 秒(不送速度指令)")
    parser.add_argument("--read-mode", action="store_true",
                        help="讀取 System mode 後離開(確認板子有回應)")
    args = parser.parse_args()

    bot = OminibotHV(args.port, args.baud)
    bot.start_reader(on_encoder=lambda v: print("encoder:", v))
    try:
        if args.read_mode:
            mode = bot.read_system_mode()
            if mode is None:
                print("讀不到 System mode(板子未上電或未回應)")
            else:
                print(f"System mode = 0x{mode:08X}"
                      f"(驅動類型={mode & 3}, 編碼器回傳={'開' if mode & 0x40 else '關'})")
        elif args.listen > 0:
            ok = bot.enable_encoder_feedback()
            print(f"開啟編碼器回傳:{'成功' if ok else '失敗(板子未回應)'}")
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
