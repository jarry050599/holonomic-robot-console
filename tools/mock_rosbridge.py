#!/usr/bin/env python3
"""模擬 rosbridge:記錄收到的封包、發送假 /scan,用來離線驗證 Mac App。"""
import asyncio, json, math, time, sys
import websockets

LOG = "/tmp/mock_rosbridge.log"

def log(line):
    with open(LOG, "a") as f:
        f.write(f"{time.time():.3f} {line}\n")

async def fake_scan_publisher(ws, subscribed):
    """訂閱 /scan 後,以 10 Hz 發送模擬點雲(一面 2m 遠的牆 + 一個 0.25m 近障礙)"""
    t0 = time.time()
    while True:
        await asyncio.sleep(0.1)
        if "/scan" not in subscribed:
            continue
        n = 360
        t = time.time() - t0
        ranges = []
        for i in range(n):
            ang = -math.pi + i * (2 * math.pi / n)
            r = 2.0 + 0.5 * math.sin(3 * ang + t)   # 波浪牆
            if 20 <= t and abs(ang) < 0.3:           # 20 秒後出現近距離障礙(測警示)
                r = 0.25
            ranges.append(round(r, 3))
        msg = {"op": "publish", "topic": "/scan", "msg": {
            "angle_min": -math.pi, "angle_max": math.pi,
            "angle_increment": 2 * math.pi / n,
            "time_increment": 0.0, "scan_time": 0.1,
            "range_min": 0.15, "range_max": 12.0,
            "ranges": ranges, "intensities": []}}
        await ws.send(json.dumps(msg))

async def handler(ws):
    log("CONNECTED")
    subscribed = set()
    pub_task = asyncio.create_task(fake_scan_publisher(ws, subscribed))
    try:
        async for raw in ws:
            data = json.loads(raw)
            op = data.get("op")
            if op == "publish" and data.get("topic") == "/cmd_vel":
                m = data["msg"]
                log(f"cmd_vel x={m['linear']['x']:+.2f} y={m['linear']['y']:+.2f} z={m['angular']['z']:+.2f}")
            else:
                log(f"OP {raw[:200]}")
                if op == "subscribe":
                    subscribed.add(data.get("topic"))
    except websockets.ConnectionClosed:
        pass
    finally:
        pub_task.cancel()
        log("DISCONNECTED")

async def main():
    async with websockets.serve(handler, "127.0.0.1", 9090):
        print("mock rosbridge on ws://127.0.0.1:9090")
        await asyncio.Future()

asyncio.run(main())
