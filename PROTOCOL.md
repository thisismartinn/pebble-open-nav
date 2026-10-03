# PebbleOpenNav protocol (v4)

How the iPhone app (`navapp/`), the watchapp's JavaScript (`navwatch/src/pkjs/index.js`,
running inside the Pebble iPhone app) and the watch (`navwatch/src/c/pebbleopennav.c`) talk.

```
PebbleOpenNav (iPhone)  --HTTP 127.0.0.1:8765-->  watchapp JS (Pebble app)  --AppMessage-->  watch
                                                  <-------------------- Tick --------------
```

## 1. `GET http://127.0.0.1:8765/step` (phone → JS)

The JS asks `/step?t=<ms>&v=0.4`: `t` only defeats caching, `v` is the watchapp's version
(`VERSION` in `index.js`, `package.json`'s `version` without the patch number). Watchapps
before v0.4 send no `v`. The phone keeps the last one it got (§5).

Every payload has:

| field | type | meaning |
|---|---|---|
| `lang` | `"vi"` \| `"en"` | phone language; the watch's texts follow it |
| `theme` | `"light"` \| `"dark"` | watch theme |
| `themeAuto` | bool | the phone setting is Automatic (sunrise/sunset) |
| `poll` | int ms | the phone's suggested time until the watch's next Tick (below) |

Then one of:

| state | extra fields |
|---|---|
| idle | `active: false` |
| routing | `active: false, routing: true` |
| ended | `active: false, ended: true, arrived: bool` (true: reached the destination; false: stopped on the phone) |
| step | `active: true, stepId: int, maneuver: int, distance: int, instruction: string, remainM: int, remainS: int, speed: number, fixTime: number`, and `toCorner: int` during the ToCorner phase |

`poll` during a step depends on *near*: the nearer of the shown maneuver and the corner being
taken (for a roundabout, its exit). The first rule that applies wins:

| state | `poll` |
|---|---|
| step: the rider is more than 15 m from the route, or near is under 60 m (also standing still) | 1000 |
| step: `speed` is 0 (standing still, e.g. at a red light) and near is under 300 m | 3000 |
| step: near is under 300 m | 2000 |
| step: near is under 1000 m | 3000 |
| step: otherwise | 10000 |
| routing | 1000 |
| idle, ended | 3000 |

Step fields:
- `stepId`: identifies the step: `routeGeneration × 1000 + maneuverIndex`. The generation goes up with each
  new route or reroute. The watch treats a change as a new step, even when two turns have the same text.
- `maneuver`: the icon code, 1–20 (below).
- `distance`: metres from the GPS fix to the shown maneuver, **at `fixTime`**.
- `toCorner`: only during the ToCorner phase, while the shown step is the one after the corner
  being taken: metres from the fix to that corner, at `fixTime`. Absent otherwise.
- `instruction`: at most 90 UTF-8 bytes, cut on a character boundary, no trailing full stop.
- `remainM` / `remainS`: metres / seconds to the destination at `fixTime`.
- `speed`: m/s **along the route** towards the shown maneuver (≥ 0; 0 when unknown, standing still, or
  moving away from the route). It is also 0 when the rider is more than 15 m from the route, so the
  watch stops counting the distance down, and while a fix is held (below).
- `fixTime`: Unix time in **milliseconds** of the GPS fix these numbers come from.

**Maneuver codes** (v3's 1–7 keep their meaning; the names are the watch's icon files):

| code | icon | Valhalla maneuver types |
|---|---|---|
| 1 | `straight` | 1–3 start, 7 becomes, 8 continue, 17 ramp straight, 22 stay straight, 25 merge, 28 ferry and any other |
| 2 | `turn-left` | 15 |
| 3 | `turn-right` | 10 |
| 4 | `slight-left` | 16 |
| 5 | `slight-right` | 9 |
| 6 | `uturn-left` | 13 |
| 7 | `arrive` | 4–6 |
| 8 | `sharp-left` | 14 |
| 9 | `sharp-right` | 11 |
| 10 | `keep-left` | 24 |
| 11 | `keep-right` | 23 |
| 12 | `uturn-right` | 12 |
| 13 | `roundabout-right` | 26 (see below) |
| 14 | `roundabout-left` | 26 |
| 15 | `roundabout-straight` | 26 |
| 16 | `roundabout-uturn` | 26 |
| 17 | `ramp-left` | 19 ramp left, 21 exit left |
| 18 | `ramp-right` | 18 ramp right, 20 exit right |
| 19 | `merge-left` | 38 |
| 20 | `merge-right` | 37 |

A roundabout (type 26, with its exit maneuver merged in) shows the way it leads. The phone
compares the heading of the last ~15 m of route into the ring with the heading of the first
~15 m after its exit: the turn angle, from -180° to 180°, is positive to the right (clockwise).
Under 45° either way is 15, 45–135° is 13 (right) or 14 (left), and over 135° is 16. Only when
either stretch is under 5 m (e.g. a route that starts in the ring) the exit count decides, for
right-hand traffic: the 1st exit 13, the 2nd 15, the 3rd 14, the 4th or later 16. So a
"2nd exit" that turns 111° left shows 14. The watch draws no icon for an unknown code.

**Step switch (the ToCorner phase):** the phone shows the step after the corner being taken
from about 25 m before that corner, plus about 1 s of travel to cover the update delay (at most
45 m). Until the corner the step carries `toCorner`: the watch shows the new step's icon and
counts down to the corner without the text, then switches to the step's full screen by itself
just before the corner (§3). The watch's new-step buzz is the cue to signal. Rules:
- The shown step is never more than one ahead of the first corner not yet passed.
- **Only while moving:** the phase starts only at a speed along the route of at least 1.5 m/s
  (0.5 m/s walking). Stopped at a light, or before setting off, the corner's own step stays up
  with its text. Once started, the phase stays until the corner.
- **Close turns:** a corner's own step stays up at least 3 s first, counted from when it became
  the corner being taken (the corner before it was passed, or a new route began). So when a turn
  is already within the lead as the last corner is passed, its full screen stays 3 s before its
  phase starts, and a route (trip start or reroute) that begins within the lead of its first turn
  still shows that turn.
- The shown step doesn't go back to an earlier one unless the fix falls more than 65 m before the
  corner passed last, so GPS jitter between two close corners doesn't make the watch buzz again.
- **Roundabouts:** a roundabout counts as passed at its exit (its exit maneuver is merged into
  it), and nothing is shown early: its icon and instruction ("Take the 2nd exit onto …") stay
  up while riding round, at 0 m.
  The step after it appears after the exit as a normal step, without a ToCorner phase.
- Arrival is still detected from the real next maneuver.

**Route requests:** Valhalla `/route` from the fix to the destination. When the fix's course is
valid (course ≥ 0, course accuracy ≥ 0 and under 45°, GPS speed at least 2 m/s), the origin also
carries `heading` (the course in whole degrees) and `heading_tolerance: 45`, so the route starts
the way the rider is going. A reroute passes it whenever the course is valid, and so does the
trip start when the rider is already moving. Without a valid course the request has neither.

**Held fixes (off the route):** a fix is placed on the route near where the last one was. One
further than 40 m from it (or than the fix's accuracy, if worse), or near only stretches facing
the other way (more than 100° from the course), is re-acquired anywhere on the route, e.g. to
rejoin it after a detour. If that finds no stretch within the corridor facing the right way
either, the fix is held: the step keeps the last placed fix's state (the same `stepId`,
`distance`, `toCorner`, `remainM` and `remainS`) with `speed` 0, and only `fixTime` is new. The
fix's own distance from the route still sets `poll` and counts towards a reroute. The next fix
back within the corridor is placed as usual. This keeps a fix from jumping to far parts of the
route, which made the watch jump steps (2→7→3→1) and the remaining time jump. A held fix
facing the wrong way still counts as off the route, so riding back along it reroutes after
2 such fixes (below) instead of holding for good.

**Reroute:** 2 fixes in a row more than 25 m (or the fix's accuracy, if worse) from the route,
or near only stretches of it facing the other way (riding back along the route), each with a GPS
speed of at least 1 m/s (0.5 m/s walking). A fix without a speed neither counts nor resets; a
slower one resets. At most one reroute per 15 s. When a reroute brings back the same next two
turns as the route it replaces (e.g. riding on along a street the map has as one-way the other
way), the route generation stays, so the step ids don't change and the watch doesn't buzz, and the
next reroute waits twice as long, up to 60 s. Back on a route, it's 15 s again.

**Route parsing:** a "Continue" (Valhalla type 8) or a road changing its name (7) shorter than
2 km is dropped, so the step before it runs on to the next real turn. Longer ones stay.

**Local server:** the app replaces its listener whenever it comes to the foreground, because iOS
can tear the socket down while the app is suspended (e.g. locked after a trip, with GPS off).

## 2. AppMessage keys (JS ↔ watch)

Watch → phone: `Tick` (uint8 1). The watch schedules its next Tick `Poll` ms ahead, clamped
to 500–10000 ms. Without `Poll` (an older nav app, or `State` 3) it polls every 3 s, and every
1 s when the predicted distance to the next maneuver, or the predicted `ToCorner`, is under 300 m.

Phone → watch (every message carries `Lang`, `Theme`, `ThemeAuto` once the nav app has answered):

| key | type | when |
|---|---|---|
| `StepId` | int32 | step (see `stepId`) |
| `Maneuver` | int32 | step |
| `Distance` | int32 m | step (at the fix) |
| `ToCorner` | int32 m | step, only when the `/step` reply had `toCorner` (at the fix) |
| `Instruction` | cstring | step |
| `RemainM` | int32 m | step |
| `RemainS` | int32 s | step |
| `Speed` | int32 cm/s | step |
| `Age` | int32 ms | step: `Date.now() - fixTime` when the JS received it |
| `Ended` | int32 1 | trip over; with `Arrived` int32 0/1 |
| `State` | int32 | 1 no trip, 2 routing, 3 nav app not answering (see below) |
| `Poll` | int32 ms | every message whose `/step` reply had `poll` |
| `Gps` | cstring | start-screen GPS line from the JS's own location probe, e.g. `GPS in 0.4s, ±8m` |
| `Lang` | cstring `vi`/`en` | |
| `Theme` | int32 1 light / 0 dark | |
| `ThemeAuto` | int32 1/0 | |

The largest message is a step with `ToCorner`, a 90-byte Vietnamese instruction and `Lang` "vi":
13 keys, 230 bytes. The watch's inbox is that size.

**The v4 phone needs the v4 watchapp.** The v3 watchapp draws no icon for codes 8–20, and its
219-byte inbox drops a step that has `ToCorner` and an instruction of 80 bytes or more. The
watchapp is installed on its own: open its `.pbw` (`navwatch/build/navwatch.pbw`) with the
Pebble app. The iPhone app says when the watchapp is older (§5).

`State` 3 is sent only when the `/step` request fails with an error (e.g. connection refused
because PebbleOpenNav is closed), answers with a status other than 200, or sends bad JSON.
A request with no answer within the 2.5 s timeout sends the watch **nothing**; the watch
notices the silence itself (§3).

## 3. Watch behaviour

- **Counting down between updates:** on each step the watch notes its own receive time.
  Every second it shows `distance - speed × (Age + time since receipt)`, clamped at 0, and
  counts `ToCorner`, `RemainM` and `RemainS` down the same way. With `Speed` 0 (e.g. more than
  15 m off the route) the numbers stay as sent.
  - It stops predicting after 20 s or 500 m since the last good step.
- **The ToCorner phase:** a new step (a new `StepId`) that carries `ToCorner` starts it. The
  screen shows the new step's icon, the big number counts down the predicted `ToCorner` (the same
  prediction and the same 5 m / 10 m rounding as the distance), and the band is empty.
  - When the predicted `ToCorner` drops below 10 m (when the count would show 5), the watch
    switches by itself to the step's full screen: its icon, the predicted `Distance` and its
    instruction. It wakes up for that moment instead of waiting for the next second.
  - Once switched, it never goes back to the countdown for that `StepId`, even if a later
    message still carries `ToCorner`. A message for the same `StepId` without `ToCorner` (the
    phone has passed the corner) also ends the phase.
  - With `Speed` 0 there is no prediction: the count holds until a message brings `ToCorner`
    below 10 m.
  - A watchapp that ignores `ToCorner` shows the full screen at once, as in v3.
- **Connection states** during a trip. A "reply" is any message from the JS: a step, `State`
  or `Ended`.

  | situation | screen |
  |---|---|
  | a reply within the last 20 s, Bluetooth up | normal |
  | no reply for 20 s | Connecting… (top bar only; the step stays) |
  | no reply for 40 s | Disconnected |
  | Bluetooth to the phone drops (`connection_service`) | Connecting… at once; Disconnected if not back within 10 s |
  | `State` 3 twice in a row | Disconnected at once |

  Disconnected keeps the last distance and the current step's icon. The next good step returns
  the watch to the normal screen.
- **Vibration:**

  | when | buzz |
  |---|---|
  | a new `StepId`, except the trip's first step | short pulse (250 ms) |
  | a new `StepId` from a new route (`StepId / 1000` changed, e.g. a reroute) | long pulse (500 ms) instead |
  | the predicted `Distance` reaches 100 m | 150 ms on, 100 ms off, 150 ms on |
  | the local switch at the end of the ToCorner phase, or the phone's message for the same step after the corner | none |
  | trip end | one light tap (120 ms) |

  - The 100 m buzz fires once per step, and only if the step's predicted distance was over
    100 m when it arrived. A step that arrives with `ToCorner` arms it only when its maneuver is
    more than 100 m past that corner (`Distance - ToCorner` over 100), so a turn that follows
    the corner closely doesn't buzz on top of the new-step pulse. There is no 200 m buzz any more.
  - PebbleOS ignores a vibe asked for while another one plays, so the watch plays one at a
    time, at least 2 s from the end of one to the start of the next. One buzz can wait: a newer
    one replaces it, and one still waiting after 3 s is dropped. The trip end drops it too.
- **End screen:** shown for 10 s, then the app exits.
- **Retry:** after an outbox failure or APP_MSG_BUSY, the next Tick goes out after 500 ms
  instead of waiting for the next poll.

## 4. Text formats (both apps)

- Seconds are always written without a space: `10s` (English and Vietnamese).
- Watch top bar: remaining `3.7km` (Vietnamese `3,7km`), `11min` (Vietnamese `11 phút`),
  `ETA 19:25` (Vietnamese `Đến 19:25`, 24-hour).
- Watch connection texts: `Connecting…` (Vietnamese `Đang kết nối…`) in the top bar; on the
  Disconnected screen `Disconnected` (`Kết nối bị ngắt`) on top and `Connection lost`
  (`Đã mất kết nối`) in the band.

## 5. Version footer (phone)

The footer of the iPhone app's Pebble section shows the versions. The phone's is its
`CFBundleShortVersionString` (`MARKETING_VERSION` in `project.yml`); the watchapp's is the last
`v` it sent. The two are compared as numbers.

| watchapp | footer |
|---|---|
| hasn't polled yet | `PebbleOpenNav · v0.4 (iPhone)` |
| sent the same version or a newer one | `PebbleOpenNav · v0.4 (iPhone) & v0.4 (Pebble)` |
| sent an older one, or none (before v0.4) | `PebbleOpenNav · v0.4 (iPhone) · Pebble app not up to date` (Vietnamese `… · Vui lòng cập nhật app trên Pebble`) |

Both apps are v0.5: `project.yml` `MARKETING_VERSION` 0.5, `CURRENT_PROJECT_VERSION` 5, and
`package.json` `"version": "0.5.0"`. A new release bumps both and `VERSION` in `index.js`.
