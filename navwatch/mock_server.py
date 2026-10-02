"""Stand-in for the iPhone navigation app's local server (protocol v4, PROTOCOL.md).

Simulates riding a scripted trip and serves the current step on
http://127.0.0.1:8765/step, the same JSON the iOS app serves. The trip has the cases the
watch has to handle: the ToCorner phase before each corner, close turns (25 m apart, and
one where the 3 s minimum holds the next phase back), roundabouts (no phase, "exit N" until
the exit), a reroute (new route generation) and most of the maneuver codes.

  GET /step     current step, {"active": false, "ended": true, "arrived": ...} once over
  GET /start    restart the trip (routing for ROUTING_S seconds first)
  GET /stop     end the trip as if the user tapped "End" on the phone (arrived: false)
  GET /idle     no trip (the watch's start screen)
  GET /pause    /step answers only after PAUSE_HOLD_S, too late for the JS (a timeout: it
                sends the watch nothing), until /resume: Connecting… after 20 s,
                Disconnected after 40 s
  GET /error    /step answers 503 until /resume, so the JS sends State 3: Disconnected
                after two
  GET /resume   answer /step normally again
  GET /plan     where each step starts (at) and its corner is, in metres along the trip

Any request also takes these query switches:
  theme=light|dark   watch theme (themeAuto becomes false)
  lang=vi|en         phone language: watch texts and the route's instructions
  at=<metres>        with /start: begin this far along the trip (no routing delay)
  routing=<s>        with /start: route for this long first (default ROUTING_S)
  speed=<m/s>        riding speed from now on (0: stand still, e.g. for screenshots)
  maneuver=<code>    show this maneuver code on every step (0: the trip's own again);
  text=<text>        with maneuver=: and this instruction

Every payload carries "poll", the phone's suggested ms until the watch's next Tick.

SPEED (m/s, default 10) speeds up the simulation, e.g. SPEED=60 to reach the end quickly.
PORT (default 8765) serves elsewhere, e.g. to test this server next to a running one.
"""
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

SPEED = float(os.environ.get("SPEED", "10"))
PORT = int(os.environ.get("PORT", "8765"))
ROUTING_S = 3
FIX_AGE_S = 0.6  # how old the GPS fix is when /step is asked
PAUSE_HOLD_S = 3  # longer than the JS's 2.5 s request timeout
MIN_STEP_S = 3  # a corner's own step stays up this long before the next one's phase
ARRIVAL_M = 20

# (maneuver, English, Vietnamese, metres from the previous corner to this maneuver, ring)
# ring: a roundabout's metres from its entry to its exit, which is its corner.
# maneuver: 1 straight, 2 left, 3 right, 4 slight left, 5 slight right, 6 U-turn left,
# 7 arrive, 8 sharp left, 9 sharp right, 10 keep left, 11 keep right, 12 U-turn right,
# 13-16 roundabout right/left/straight/U-turn, 17/18 ramp left/right, 19/20 merge left/right
FIRST_ROUTE = [
    (3, "Turn right onto Duong 160", "Rẽ phải vào Đường 160", 180, 0),
    (2, "Turn left onto Kim Ma", "Rẽ trái vào Kim Mã", 400, 0),
    # 25 m after the left: its own screen until its corner, then the keep left's.
    (9, "Sharp right onto Ngo 20", "Rẽ gắt phải vào Ngõ 20", 25, 0),
    # 50 m: the roundabout's phase waits for the keep left's 3 s.
    (10, "Keep left on Lieu Giai", "Giữ bên trái vào Liễu Giai", 50, 0),
    (14, "Take the 3rd exit onto Dao Tan", "Rẽ lối thứ 3 vào Đào Tấn", 300, 60),
    (18, "Take the ramp to Nguyen Chi Thanh", "Vào đường dẫn lên Nguyễn Chí Thanh", 200, 0),
    (20, "Merge onto Nguyen Chi Thanh", "Nhập vào Nguyễn Chí Thanh", 150, 0),
    # Not reached: the rider leaves the route before it.
    (12, "U-turn at Lang Ha", "Quay đầu tại Láng Hạ", 600, 0),
    (7, "Destination ahead", "Điểm đến ở phía trước", 300, 0),
]
SECOND_ROUTE = [
    # Starts within the lead of its first turn: that turn's own screen first.
    (8, "Sharp left onto Ngo 12", "Rẽ gắt trái vào Ngõ 12", 45, 0),
    (11, "Keep right on Hoang Dao Thuy", "Giữ bên phải vào Hoàng Đạo Thúy", 250, 0),
    (15, "Take the 2nd exit onto Le Van Luong", "Rẽ lối thứ 2 vào Lê Văn Lương", 200, 40),
    (17, "Take the ramp to Vanh Dai 3", "Vào đường dẫn lên Vành đai 3", 150, 0),
    (19, "Merge onto Vanh Dai 3", "Nhập vào Vành đai 3", 120, 0),
    (5, "Bear right onto Khuat Duy Tien", "Chếch phải vào Khuất Duy Tiến", 400, 0),
    # The longest instruction the nav app sends: 90 bytes of Vietnamese.
    (6, "Make a left U-turn at Pho Lieu Giai to stay in Pho Lieu Giai",
     "Quay đầu bên trái tại Phố Liễu Giai để tiếp tục đi trên Phố Liễu Giai rồi đi thẳng qua nút giao Đội Cấn",
     200, 0),
    (4, "Bear left onto Ngo 75", "Chếch trái vào Ngõ 75", 150, 0),
    (13, "Take the 1st exit onto Tran Duy Hung", "Rẽ lối thứ 1 vào Trần Duy Hưng", 100, 20),
    (16, "Take the 4th exit onto Tran Duy Hung", "Rẽ lối thứ 4 vào Trần Duy Hưng", 200, 70),
    (1, "Continue on Tran Duy Hung", "Đi thẳng vào Trần Duy Hưng", 250, 0),
    (7, "Destination on the left", "Điểm đến ở bên trái", 150, 0),
]
# (route, metres along it where the rider leaves it, metres ridden off it until the
# reroute's new route starts there); the last route is ridden to the end.
TRIP = [(FIRST_ROUTE, 1615, 40), (SECOND_ROUTE, None, 0)]


def layout(route):
    """Each maneuver's start and corner, in metres along its route; index 0 is the start."""
    begin, corner = [0.0], [0.0]
    for *_, dist, ring in route:
        begin.append(corner[-1] + dist)
        corner.append(begin[-1] + ring)
    return begin, corner


PIECES = []  # (route, begin, corner, trip metres where it starts, leave, off)
_at = 0.0
for _route, _leave, _off in TRIP:
    _begin, _corner = layout(_route)
    PIECES.append((_route, _begin, _corner, _at, _leave, _off))
    _at += (_leave + _off) if _leave is not None else _corner[-1]
TOTAL = _at

state = {
    "start": time.time(), "offset": 0.0, "speed": SPEED, "mode": "trip",  # trip | idle | stopped
    "fault": None,  # None | "pause" | "error"
    "lang": "vi", "theme": "dark", "themeAuto": True,
    "generation": 1,  # the trip's first route generation; each /start moves past the last trip's
    "corner_since": {},  # (generation, corner index) -> when it became the corner being taken
    "shown": {},  # generation -> the shown index, which never goes back
    "force": None,  # (maneuver, text) from maneuver=&text=
}


def cut_utf8(text, max_bytes=90):
    """At most max_bytes of UTF-8, cut on a character boundary, no trailing full stop."""
    data = text.encode()[:max_bytes]
    return data.decode(errors="ignore").rstrip(" .")


def step_poll(near, speed, off_route):
    """The nav app's poll hint during a step; near is the closer of the shown maneuver and
    the corner being taken."""
    if off_route or near < 60:
        return 1000
    if speed == 0 and 15 < near < 300:
        return 3000  # stopped near a turn
    if near < 300:
        return 2000
    return 3000 if near < 1000 else 10000


def travelled_at(t):
    return state["offset"] + max(0.0, t - state["start"]) * state["speed"]


def passed_at(metres):
    """When the rider passed this point of the trip, if since the last speed change."""
    if state["speed"] > 0 and metres >= state["offset"]:
        return state["start"] + (metres - state["offset"]) / state["speed"]
    return None


def route_step(piece, generation, along, fix_time, off_route):
    """The step at `along` metres on the piece's route, as the nav app would serve it. Off the
    route it is the last on-route one, frozen (speed 0)."""
    route, begin, corner, at, *_ = piece
    last = len(route)
    corner_index = next((i for i in range(1, last + 1) if corner[i] > along + 0.5), last)
    to_corner = max(0.0, corner[corner_index] - along)
    if corner_index == last and to_corner <= ARRIVAL_M and not off_route:
        return None  # arrived
    speed = 0.0 if off_route else state["speed"]
    # When the corner index last changed: when the rider passed the corner before (or the
    # start of a new route), or when first asked if that was before the last speed change.
    since = state["corner_since"].setdefault(
        (generation, corner_index), passed_at(at + corner[corner_index - 1]) or fix_time)
    # The step after the corner shows from 25 m (+1 s of travel, at most 45 m) before it,
    # once the corner's own step has been up for MIN_STEP_S; never after a roundabout,
    # which keeps "exit N" until its exit.
    lead = min(25 + speed, 45)
    roundabout = route[corner_index - 1][4] > 0
    early = (corner_index < last and not roundabout and to_corner <= lead
             and fix_time - since >= MIN_STEP_S)
    shown = corner_index + 1 if early else corner_index
    shown = max(shown, min(state["shown"].get(generation, 0), corner_index + 1))
    if not off_route:
        state["shown"][generation] = shown
    maneuver, english, vietnamese, *_ = route[shown - 1]
    distance = max(0.0, begin[shown] - along)
    remaining = corner[last] - along
    if state["force"]:
        maneuver = state["force"][0]
        english = vietnamese = state["force"][1] or english
    body = {
        "poll": step_poll(min(distance, to_corner), speed, off_route),
        "active": True,
        "stepId": generation * 1000 + shown,
        "maneuver": maneuver,
        "distance": int(distance),
        "instruction": cut_utf8(vietnamese if state["lang"] == "vi" else english),
        "remainM": int(remaining),
        "remainS": int(remaining / (state["speed"] or SPEED)),
        "speed": speed,
        "fixTime": int(fix_time * 1000),
    }
    if shown > corner_index:
        body["toCorner"] = int(to_corner)
    return body


def current_step():
    common = {"lang": state["lang"], "theme": state["theme"], "themeAuto": state["themeAuto"]}
    if state["mode"] == "idle":
        return {**common, "poll": 3000, "active": False}
    if state["mode"] == "stopped":
        return {**common, "poll": 3000, "active": False, "ended": True, "arrived": False}
    now = time.time()
    if now < state["start"]:
        return {**common, "poll": 1000, "active": False, "routing": True}
    fix_time = now - FIX_AGE_S
    travelled = travelled_at(fix_time)
    for k, piece in enumerate(PIECES):
        *_, at, leave, off = piece
        if leave is None or travelled < at + leave + off:
            along = travelled - at
            off_route = leave is not None and along >= leave
            body = route_step(piece, state["generation"] + k, leave if off_route else along, fix_time, off_route)
            break
    if body is None:
        return {**common, "poll": 3000, "active": False, "ended": True, "arrived": True}
    return {**common, **body}


def plan():
    rows = []
    for k, (route, begin, corner, at, leave, off) in enumerate(PIECES):
        for i, (maneuver, english, *_rest) in enumerate(route, start=1):
            if leave is not None and begin[i] >= leave:
                break
            rows.append({"stepId": (state["generation"] + k) * 1000 + i, "maneuver": maneuver,
                         "text": english, "at": round(at + begin[i]), "corner": round(at + corner[i])})
        if leave is not None:
            rows.append({"reroute": round(at + leave), "newRoute": round(at + leave + off)})
    return rows


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlsplit(self.path)
        query = {k: v[-1] for k, v in parse_qs(url.query, keep_blank_values=True).items()}
        if query.get("theme") in ("light", "dark"):
            state.update(theme=query["theme"], themeAuto=False)
        if query.get("lang") in ("vi", "en"):
            state["lang"] = query["lang"]
        if "speed" in query:
            # Carry on from where the rider is now.
            now = time.time()
            if now > state["start"]:
                state.update(offset=travelled_at(now), start=now)
            state["speed"] = max(0.0, float(query["speed"]))
        if "maneuver" in query:
            code = int(query["maneuver"] or 0)
            state["force"] = (code, query.get("text")) if code else None
        path = url.path
        body = {"ok": True}
        note = ""
        if path == "/start":
            at = float(query.get("at", 0))
            # Routing first, unless starting somewhere along the trip.
            routing = float(query.get("routing", 0 if "at" in query else ROUTING_S))
            state.update(mode="trip", offset=at, start=time.time() + routing,
                         generation=state["generation"] + len(PIECES), corner_since={}, shown={})
        elif path == "/stop":
            state["mode"] = "stopped"
        elif path == "/idle":
            state["mode"] = "idle"
        elif path == "/pause":
            state["fault"] = "pause"
        elif path == "/error":
            state["fault"] = "error"
        elif path == "/resume":
            state["fault"] = None
        elif path == "/plan":
            body = plan()
        elif path == "/step":
            if state["fault"] == "error":
                self.send_error(503)
                print(time.strftime("%H:%M:%S"), path, "503 (error)", flush=True)
                return
            if state["fault"] == "pause":
                # A slow phone: the JS has given up by the time this answers.
                time.sleep(PAUSE_HOLD_S)
                note = "(held %ss) " % PAUSE_HOLD_S
            body = current_step()
        else:
            self.send_error(404)
            return
        data = json.dumps(body, ensure_ascii=False).encode()
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            note = "(dropped by the JS) " + note  # it aborted a held request
        print(time.strftime("%H:%M:%S"), path, note + data.decode(), flush=True)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
