# PebbleOpenNav protocol (v3)

How the iPhone app (`navapp/`), the watchapp's JavaScript (`navwatch/src/pkjs/index.js`,
running inside the Pebble iPhone app) and the watch (`navwatch/src/c/pebbleopennav.c`) talk.

```
PebbleOpenNav (iPhone)  --HTTP 127.0.0.1:8765-->  watchapp JS (Pebble app)  --AppMessage-->  watch
                                                  <-------------------- Tick --------------
```

## 1. `GET http://127.0.0.1:8765/step` (phone → JS)

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
| step | `active: true, stepId: int, maneuver: int, distance: int, instruction: string, remainM: int, remainS: int, speed: number, fixTime: number` |

`poll`:

| state | `poll` |
|---|---|
| step | 1000 when the shown maneuver or the corner being taken is under 300 m away, or the rider is more than 15 m from the route; else 3000 when one of them is under 1000 m away; else 10000 |
| routing | 1000 |
| idle, ended | 3000 |

Step fields:
- `stepId`: identifies the step: `routeGeneration × 1000 + maneuverIndex`. The generation goes up with each
  new route or reroute. The watch treats a change as a new step, even when two turns have the same text.
- `maneuver`: 1 straight, 2 left, 3 right, 4 slight left, 5 slight right, 6 U-turn, 7 arrive.
- `distance`: metres from the GPS fix to the shown maneuver, **at `fixTime`**.
- `instruction`: at most 90 UTF-8 bytes, cut on a character boundary, no trailing full stop.
- `remainM` / `remainS`: metres / seconds to the destination at `fixTime`.
- `speed`: m/s **along the route** towards the shown maneuver (≥ 0; 0 when unknown, standing still, or
  moving away from the route). It is also 0 when the rider is more than 15 m from the route, so the
  watch stops counting the distance down.
- `fixTime`: Unix time in **milliseconds** of the GPS fix these numbers come from.

**Step switch:** the phone shows the next instruction about 30 m before the corner, plus about 1 s
of travel to cover the update delay (at most 50 m), so the rider sees the following maneuver while
still taking this one; the watch's new-step buzz is the cue to signal. Rules:
- The shown step is never more than one ahead of the first corner not yet passed.
- A corner's own step stays up at least 3 s first, so a route (trip start or reroute) that begins
  within 30–50 m of its first turn still shows that turn.
- The shown step doesn't go back to an earlier one unless the fix falls more than 65 m before the
  corner passed last, so GPS jitter between two close corners doesn't make the watch buzz again.
- A roundabout counts as passed at its exit (its exit maneuver is merged into it), so "exit 2"
  stays up while riding round, at 0 m.
- Arrival is still detected from the real next maneuver.

**Reroute:** 2 fixes in a row more than 25 m (or the fix's accuracy, if worse) from the route, each
with a GPS speed of at least 1 m/s (0.5 m/s walking). A fix without a speed neither counts nor
resets; a slower one resets. At most one reroute per 15 s.

## 2. AppMessage keys (JS ↔ watch)

Watch → phone: `Tick` (uint8 1). The watch schedules its next Tick `Poll` ms ahead, clamped
to 500–10000 ms. Without `Poll` (an older nav app, or `State` 3) it polls every 3 s, and every
1 s when the predicted distance to the next maneuver is under 300 m.

Phone → watch (every message carries `Lang`, `Theme`, `ThemeAuto` once the nav app has answered):

| key | type | when |
|---|---|---|
| `StepId` | int32 | step (see `stepId`) |
| `Maneuver` | int32 | step |
| `Distance` | int32 m | step (at the fix) |
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

`State` 3 is sent only when the `/step` request fails with an error (e.g. connection refused
because PebbleOpenNav is closed), answers with a status other than 200, or sends bad JSON.
A request with no answer within the 2.5 s timeout sends the watch **nothing**; the watch
notices the silence itself (§3).

## 3. Watch behaviour

- **Counting down between updates:** on each step the watch notes its own receive time.
  Every second it shows `distance - speed × (Age + time since receipt)`, clamped at 0, and
  counts `RemainM` / `RemainS` down the same way. With `Speed` 0 (e.g. more than 15 m off the
  route) the numbers stay as sent.
  - It stops predicting after 20 s or 500 m since the last good step.
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
- **Vibration:** a short pulse on each new step, and "nudge nudge" (30 ms on, 118 ms off,
  30 ms on) when the predicted distance crosses 200 m and 100 m. A threshold that was already
  passed when the step started doesn't fire.
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
