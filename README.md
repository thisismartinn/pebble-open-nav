# PebbleOpenNav

A navigation app on the iPhone does the routing and GPS and serves the next step on
`127.0.0.1:8765`. A Pebble watchapp polls it every 3 s through the Pebble app's
JavaScript runtime and shows the step. This is the same idea as G Navigation's
Amazfit mode.

```
iPhone: Nav Test app ──127.0.0.1──> Pebble app (watchapp JS) ──Bluetooth──> Pebble watch
        GPS + Valhalla + Photon                                          arrow, distance, ETA
```

## What's here

| Folder | What it is |
| --- | --- |
| `navtest/` | Pebble watchapp (C + JavaScript). `navtest/build/navtest.pbw` is ready to install. |
| `navtest/mock_server.py` | Fake route server for the emulator (`SPEED=60` for a fast trip, `/start`, `/stop`). |
| `navapp/Sources/Core/` | Routing (Valhalla), search (Photon), guidance, 127.0.0.1 server. Shared by the app and `navsim`. |
| `navapp/Sources/App/` | iPhone app (SwiftUI + MapKit): search, trip, background GPS. |
| `navapp/Tools/navsim/` | Mac stand-in for the iPhone app: drives a real route and serves the watch emulator. |
| `navapp/scripts/build-ipa.sh` | Builds an unsigned `NavTest.ipa` (needs Xcode + `brew install xcodegen`). |
| `.github/workflows/build-ipa.yml` | Same build on GitHub's macOS runners, for when there's no Xcode locally. |

## Watch ↔ phone protocol

See [PROTOCOL.md](PROTOCOL.md): the `/step` JSON, the AppMessage keys, and how the watch
counts down between updates.

## Language

Both apps follow the phone's language: Vietnamese if it's set to Vietnamese,
English otherwise.

- **iPhone app:** UI texts in `navapp/Resources/{en,vi}.lproj/Localizable.strings`,
  the permission prompt in `vi.lproj/InfoPlist.strings`, and Valhalla directions in
  `vi-VN` or `en-US`.
- **Watchapp:** the nav app sends `"lang": "vi" | "en"` in every reply, and the
  JavaScript passes it to the watch as `Lang`. Until the nav app answers, the watch
  uses its own language (`Pebble.getActiveWatchInfo().language`, set by its language
  pack). `navigator.language` isn't used, because the Pebble iOS app is English-only
  and reports e.g. `en_VN` on a Vietnamese phone.
- Vietnamese uses a decimal comma for distances ("Còn 8,4 km").

## Watch display

Light theme (white background, dark text) on every watch, colour or black-and-white,
because it's easier to read in sunlight. It's set in the iPhone app under
**Pebble → Watch Display**:

- **Automatic** (default): light between sunrise and sunset at your GPS position,
  from `Sources/Core/Sun.swift`.
- **Light** or **Dark**: always that theme.

Every payload carries `"theme": "light" | "dark"`. The watch remembers the last theme
for its next launch.

## Liquid Glass

The iPhone app only gets the iOS 26 look when built with the iOS 26+ SDK, so CI
uses the `macos-26` runner with its newest stable Xcode. `build-ipa.sh` fails if the
built app's `DTSDKName` is older than `iphoneos26`.

## Test on your iPhone

### 1. Background test (works now, no .ipa needed)

1. AirDrop `navtest/build/navtest.pbw` to the iPhone and open it with the Pebble app.
2. Open **Nav Test** on the watch. With no nav app running it goes into **probe mode**:
   `Tick N, max gap X s` plus the age of the Pebble app's own GPS fix.
3. Lock the phone, put it in your pocket and walk for 10 minutes.

- **Tick keeps rising, max gap stays around 3–6 s:** the Pebble app answers the watch
  from the background. This is what the full design relies on.
- **"No reply for N s" on top:** iOS suspended the Pebble app. The design needs rethinking.
- **GPS error or stale while locked:** expected. The Pebble app has no background
  location, which is why the nav app does its own GPS.

### 2. Full test (needs the .ipa)

1. Install `NavTest.ipa` with Sideloadly or AltStore. A free Apple ID build lasts 7 days.
2. In Nav Test, search for a place, pick **Motorbike**, then tap a result.
3. Open Nav Test on the watch, lock the phone and ride.
4. Afterwards the app shows `Watch checked in … · longest gap N s`, which shows whether
   polling kept up while locked.

## Emulator (Mac)

```bash
navapp/build/navsim --route-json route.json --speed 10   # or pass from/to "lat,lon"
cd navtest && pebble install --emulator emery
```

Start the server **before** the watchapp. The emulator's JavaScript runtime hangs on a
refused connection, which the real Pebble iPhone app doesn't do.
