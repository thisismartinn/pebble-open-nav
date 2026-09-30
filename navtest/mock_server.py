"""Stand-in for the iPhone navigation app's local server (protocol v2, PROTOCOL.md).

Simulates riding a short route and serves the current step on
http://127.0.0.1:8765/step, the same JSON the iOS app serves.

  GET /step     current step, {"active": false, "ended": true, "arrived": ...} once over
  GET /start    restart the trip (routing for ROUTING_S seconds first)
  GET /stop     end the trip as if the user tapped "End" on the phone (arrived: false)
  GET /idle     no trip (the watch's start screen)
  GET /pause    /step answers 503 until /resume, so the watch sees State 3
  GET /resume   answer /step again

Any request also takes these query switches:
  theme=light|dark   watch theme (themeAuto becomes false)
  lang=vi|en         phone language: watch texts and the route's instructions
  at=<metres>        with /start: begin this far along the route (no routing delay)
  routing=<s>        with /start: route for this long first (default ROUTING_S)
  speed=<m/s>        riding speed (0: stand still, e.g. for screenshots)

SPEED (m/s, default 10) speeds up the simulation, e.g. SPEED=60 to reach the end quickly.
"""
import json
import os
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit

SPEED = float(os.environ.get("SPEED", "10"))
ROUTING_S = 3
FIX_AGE_S = 0.6  # how old the GPS fix is when /step is asked

# (maneuver, English, Vietnamese, metres until this maneuver from the previous one)
# maneuver: 1 straight, 2 left, 3 right, 4 slight left, 5 slight right, 6 u-turn, 7 arrive
ROUTE = [
    (3, "Turn right onto Duong 160", "Rẽ phải vào Đường 160", 180),
    (2, "Turn left onto Kim Ma", "Rẽ trái vào Kim Mã", 1500),
    (5, "Keep right onto Lieu Giai", "Đi về bên phải vào Liễu Giai", 250),
    # The longest instruction the nav app sends: 90 bytes of Vietnamese.
    (6, "Make a left U-turn at Pho Lieu Giai to stay in Pho Lieu Giai",
     "Quay đầu bên trái tại Phố Liễu Giai để tiếp tục đi trên Phố Liễu Giai rồi đi thẳng qua nút giao Đội Cấn", 900),
    (4, "Keep left onto Dao Tan", "Đi về bên trái vào Đào Tấn", 300),
    (1, "Continue on Dao Tan", "Tiếp tục đi trên Đào Tấn", 400),
    (7, "Arriving at destination", "Sắp đến nơi", 150),
]
TOTAL = sum(d for *_, d in ROUTE)
state = {
    "start": time.time(), "offset": 0.0, "speed": SPEED, "mode": "trip",  # trip | idle | stopped
    "paused": False, "lang": "vi", "theme": "dark", "themeAuto": True,
    "generation": 1,  # goes up with each /start, like the nav app's route generation
}


def cut_utf8(text, max_bytes=90):
    """At most max_bytes of UTF-8, cut on a character boundary, no trailing full stop."""
    data = text.encode()[:max_bytes]
    return data.decode(errors="ignore").rstrip(" .")


def current_step():
    common = {"lang": state["lang"], "theme": state["theme"], "themeAuto": state["themeAuto"]}
    if state["mode"] == "idle":
        return {**common, "active": False}
    if state["mode"] == "stopped":
        return {**common, "active": False, "ended": True, "arrived": False}
    now = time.time()
    if now < state["start"]:
        return {**common, "active": False, "routing": True}
    fix_time = now - FIX_AGE_S
    travelled = state["offset"] + max(0.0, fix_time - state["start"]) * state["speed"]
    if travelled >= TOTAL:
        return {**common, "active": False, "ended": True, "arrived": True}
    done = 0
    for index, (maneuver, english, vietnamese, dist) in enumerate(ROUTE):
        if travelled < done + dist:
            remaining = TOTAL - travelled
            return {
                **common,
                "active": True,
                "stepId": state["generation"] * 1000 + index,
                "maneuver": maneuver,
                "distance": int(done + dist - travelled),
                "instruction": cut_utf8(vietnamese if state["lang"] == "vi" else english),
                "remainM": int(remaining),
                "remainS": int(remaining / (state["speed"] or SPEED)),
                "speed": state["speed"],
                "fixTime": int(fix_time * 1000),
            }
        done += dist


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlsplit(self.path)
        query = {k: v[-1] for k, v in parse_qs(url.query).items()}
        if query.get("theme") in ("light", "dark"):
            state.update(theme=query["theme"], themeAuto=False)
        if query.get("lang") in ("vi", "en"):
            state["lang"] = query["lang"]
        if "speed" in query:
            state["speed"] = max(0.0, float(query["speed"]))
        path = url.path
        body = {"ok": True}
        if path == "/start":
            at = float(query.get("at", 0))
            # Routing first, unless starting somewhere along the route.
            routing = float(query.get("routing", 0 if "at" in query else ROUTING_S))
            state.update(mode="trip", offset=at, start=time.time() + routing,
                         generation=state["generation"] + 1)
        elif path == "/stop":
            state["mode"] = "stopped"
        elif path == "/idle":
            state["mode"] = "idle"
        elif path == "/pause":
            state["paused"] = True
        elif path == "/resume":
            state["paused"] = False
        elif path == "/step":
            if state["paused"]:
                self.send_error(503)
                print(time.strftime("%H:%M:%S"), path, "503 (paused)", flush=True)
                return
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
