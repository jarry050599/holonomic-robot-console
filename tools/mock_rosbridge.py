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

async def fake_map_publisher(ws, subscribed):
    """訂閱 /map 後,每 2 秒發一張假地圖(60x40 房間,牆+未知區),
    並發機器人位姿 /pose(緩慢移動,驗證箭頭方向)"""
    t0 = time.time()
    w, h, res = 60, 40, 0.05
    while True:
        await asyncio.sleep(2.0)
        if "/map" not in subscribed:
            continue
        t = time.time() - t0
        data = []
        for row in range(h):
            for col in range(w):
                if row in (0, h - 1) or col in (0, w - 1):
                    data.append(100)            # 牆
                elif col > w * 0.7 and row < h * 0.3:
                    data.append(-1)             # 未知區
                else:
                    data.append(0)              # 自由區
        await ws.send(json.dumps({"op": "publish", "topic": "/map", "msg": {
            "info": {"resolution": res, "width": w, "height": h,
                     "origin": {"position": {"x": -1.5, "y": -1.0, "z": 0},
                                "orientation": {"x": 0, "y": 0, "z": 0, "w": 1}}},
            "data": data}}))
        yaw = t * 0.3
        await ws.send(json.dumps({"op": "publish", "topic": "/pose", "msg": {
            "pose": {"pose": {
                "position": {"x": 0.4 * math.cos(t * 0.2), "y": 0.3 * math.sin(t * 0.2), "z": 0},
                "orientation": {"x": 0, "y": 0,
                                "z": math.sin(yaw / 2), "w": math.cos(yaw / 2)}}}}}))

async def handler(ws):
    log("CONNECTED")
    subscribed = set()
    tasks = [asyncio.create_task(fake_scan_publisher(ws, subscribed)),
             asyncio.create_task(fake_map_publisher(ws, subscribed))]
    try:
        async for raw in ws:
            data = json.loads(raw)
            op = data.get("op")
            if op == "publish" and data.get("topic") == "/cmd_vel":
                m = data["msg"]
                log(f"cmd_vel x={m['linear']['x']:+.2f} y={m['linear']['y']:+.2f} z={m['angular']['z']:+.2f}")
            elif op == "publish" and data.get("topic") == "/goal_pose":
                p = data["msg"]["pose"]["position"]
                log(f"goal_pose x={p['x']:.2f} y={p['y']:.2f}")
            else:
                log(f"OP {raw[:200]}")
                if op == "subscribe":
                    subscribed.add(data.get("topic"))
    except websockets.ConnectionClosed:
        pass
    finally:
        for task in tasks:
            task.cancel()
        log("DISCONNECTED")

async def main():
    async with websockets.serve(handler, "127.0.0.1", 9090):
        print("mock rosbridge on ws://127.0.0.1:9090")
        await asyncio.Future()

asyncio.run(main())
