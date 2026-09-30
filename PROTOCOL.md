# PebbleOpenNav protocol (v2)

How the iPhone app (`navapp/`), the watchapp's JavaScript (`navtest/src/pkjs/index.js`,
running inside the Pebble iPhone app) and the watch (`navtest/src/c/navtest.c`) talk.

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

Then one of:

| state | extra fields |
|---|---|
| idle | `active: false` |
| routing | `active: false, routing: true` |
| ended | `active: false, ended: true, arrived: bool` (true: reached the destination; false: stopped on the phone) |
| step | `active: true, maneuver: int, distance: int, instruction: string, remainM: int, remainS: int, speed: number, fixTime: number` |

Step fields:
- `maneuver`: 1 straight, 2 left, 3 right, 4 slight left, 5 slight right, 6 U-turn, 7 arrive.
- `distance`: metres from the GPS fix to the next maneuver, **at `fixTime`**.
- `instruction`: at most 90 UTF-8 bytes, cut on a character boundary, no trailing full stop.
- `remainM` / `remainS`: metres / seconds to the destination at `fixTime`.
- `speed`: m/s along the route (≥ 0; 0 when unknown or standing still).
- `fixTime`: Unix time in **milliseconds** of the GPS fix these numbers come from.

## 2. AppMessage keys (JS ↔ watch)

Watch → phone: `Tick` (uint8 1). The watch polls every 3 s, and every 1 s when the
predicted distance to the next maneuver is under 300 m.

Phone → watch (every message carries `Lang`, `Theme`, `ThemeAuto` once the nav app has answered):

| key | type | when |
|---|---|---|
| `Maneuver` | int32 | step |
| `Distance` | int32 m | step (at the fix) |
| `Instruction` | cstring | step |
| `RemainM` | int32 m | step |
| `RemainS` | int32 s | step |
| `Speed` | int32 cm/s | step |
| `Age` | int32 ms | step: `Date.now() - fixTime` when the JS received it |
| `Ended` | int32 1 | trip over; with `Arrived` int32 0/1 |
| `State` | int32 | 1 no trip, 2 routing, 3 phone not answering (see below) |
| `Gps` | cstring | start-screen GPS line from the JS's own location probe, e.g. `GPS in 0.4s, ±8m` |
| `Lang` | cstring `vi`/`en` | |
| `Theme` | int32 1 light / 0 dark | |
| `ThemeAuto` | int32 1/0 | |

`State` 3 is sent when a `/step` fetch fails (error or 2.5 s timeout).

## 3. Watch behaviour

- **Counting down between updates:** on each step the watch notes its own receive time.
  Every second it shows `distance - speed × (Age + time since receipt)`, clamped at 0, and
  counts `RemainM` / `RemainS` down the same way.
  - It stops predicting after 20 s or 250 m since the last good step.
  - After 10 s without a good step during a trip, it shows the Disconnected screen, keeping
    the last distance and the current step's icon.
- **Vibration:** a short pulse on each new step, and "nudge nudge" (30 ms on, 118 ms off,
  30 ms on) when the predicted distance crosses 200 m and 100 m. A threshold that was already
  passed when the step started doesn't fire.
- **End screen:** shown for 10 s, then the app exits.
- **Retry:** after an outbox failure or APP_MSG_BUSY, the next Tick goes out after 500 ms
  instead of waiting for the next slot.

## 4. Text formats (both apps)

- Seconds are always written without a space: `10s` (English and Vietnamese).
- Watch top bar: remaining `3.7km` (Vietnamese `3,7km`), `11min` (Vietnamese `11 phút`),
  `ETA 19:25` (Vietnamese `Đến 19:25`, 24-hour).
