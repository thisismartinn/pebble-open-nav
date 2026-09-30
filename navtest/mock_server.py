"""Stand-in for the iPhone navigation app's local server.

Simulates driving a short route and serves the current step on
http://127.0.0.1:8765/step, the same JSON the iOS app serves.

  GET /step   current step, or {"ended": true, "reason": ...} once the trip is over
  GET /start  restart the trip
  GET /stop   end the trip as if the user tapped "End" on the phone

SPEED (m/s, default 10) speeds up the simulation, e.g. SPEED=60 to reach the end quickly.
"""
import json
import os
import time
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, HTTPServer

SPEED = float(os.environ.get("SPEED", "10"))

# (maneuver, instruction, metres until this maneuver from the previous one)
# maneuver: 1 straight, 2 left, 3 right, 4 slight left, 5 slight right, 6 u-turn, 7 arrive
ROUTE = [
    (3, "Rẽ phải vào Đ. 160", 180),
    (2, "Turn left onto Kim Ma", 320),
    (5, "Keep right onto Lieu Giai", 250),
    (1, "Continue on Dao Tan", 400),
    (7, "Arrive at destination", 150),
]
TOTAL = sum(d for _, _, d in ROUTE)
trip = {"start": time.time(), "stopped": False}


def current_step():
    if trip["stopped"]:
        return {"active": False, "ended": True, "reason": "Stopped on phone"}
    travelled = (time.time() - trip["start"]) * SPEED
    if travelled >= TOTAL:
        return {"active": False, "ended": True, "reason": "You have arrived"}
    done = 0
    for maneuver, instruction, dist in ROUTE:
        if travelled < done + dist:
            remaining = TOTAL - travelled
            secs = remaining / SPEED
            arrive = datetime.now() + timedelta(seconds=secs)
            return {
                "active": True,
                "maneuver": maneuver,
                "distance": int(done + dist - travelled),
                "instruction": instruction,
                "remaining": f"{remaining / 1000:.1f} km left",
                "eta": f"{max(1, round(secs / 60))} min · Arrive {arrive:%H:%M}",
            }
        done += dist


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/start":
            trip.update(start=time.time(), stopped=False)
            body = {"ok": True}
        elif path == "/stop":
            trip["stopped"] = True
            body = {"ok": True}
        elif path == "/step":
            body = current_step()
        else:
            self.send_error(404)
            return
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        print(time.strftime("%H:%M:%S"), path, data.decode(), flush=True)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 8765), Handler).serve_forever()
