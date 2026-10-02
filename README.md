# PebbleOpenNav

Turn-by-turn navigation on your Pebble watch, driven by your iPhone. The iPhone app plans
the route on OpenStreetMap data and follows you by GPS, even with the phone locked in a
pocket. The watch shows the next turn, how far away it is, and when you'll arrive, and
buzzes you before each turn.

It is built for riding a motorbike or scooter in a city like Hanoi, where a glance at the
wrist beats a phone on the handlebars. It works just as well by car, bike or on foot.

![PebbleOpenNav on Pebble Time 2, Pebble Round 2 and Pebble 2 Duo, light theme](docs/screenshots/watches-light.png)
![The same screens in the dark theme](docs/screenshots/watches-dark.png)

## Features

### On the watch
- **The next turn at a glance:** a turn icon, the distance to the turn, a short instruction
  ("U-turn at Liễu Giai", "Take the 2nd exit onto Khuất Duy Tiến"), the remaining distance,
  the minutes left and your ETA.
- **20 turn icons:** straight, left and right, slight, sharp, keep, U-turns both ways,
  roundabouts (right, left, straight, U-turn), ramps, merges and arrival. A roundabout's icon
  shows the way it really leads, from the route's shape.
- **A smooth countdown:** between updates from the phone, the watch counts the distance down
  itself from your speed, so the number moves every second without draining the battery.
- **Vibrations:**
  - a short buzz when a new turn appears, which is your cue to signal, and a long one after
    a reroute;
  - a double nudge 100 m before a turn;
  - a single light tap when you arrive.
  - Buzzes never overlap: they come one at a time, at least 2 s apart.
- **Ease-in to the next turn:** 25–45 m before a corner (more when you're faster), the watch
  shows the next turn's icon and counts down to the corner. Just before the corner it switches
  to the next turn's full screen by itself. Close turns stay on screen at least 3 s, and a
  roundabout's exit stays up until you leave it.
- **Honest connection status:** "Connecting…" after 20 s without news from the phone, then
  "Disconnected" after 40 s, or at once if PebbleOpenNav was closed. The last step stays on
  screen meanwhile.
- **Light and dark themes**, switching automatically at sunrise and sunset where you are.
  The light theme is easier to read in sunlight.
- **Designed for each watch:** bigger text on Pebble Time 2 and Pebble Round 2 (it wraps
  inside the circle), and a crisp black-and-white layout on Pebble 2 Duo.
- **Start and end screens:** a start screen with a GPS check, and an end screen that closes
  the app by itself after 10 s.

![Pebble Round 2: start, Connecting…, Disconnected and arrival screens](docs/screenshots/round-states.png)

### On the iPhone
- **Search the way you do in Apple Maps:** suggestions as you type, and any place on the
  map can be tapped to open a place card with a **Go** button. Street addresses with a house
  number also come from OpenStreetMap (Photon).
- **Routes for motorbike, car, bicycle or walking**, from the Valhalla routing engine on
  OpenStreetMap data, with live traffic shown on the map.
- **Works in your pocket:** background GPS keeps guiding with the phone locked.
- **Fast rerouting:** a new route within seconds of leaving the old one, without false alarms
  while GPS warms up indoors.
- **Live Activity** on the Lock Screen and in the Dynamic Island.
- **Pebble section:**
  - the watch's connection ("Checked in 2s ago • 340 times, longest gap: 11s");
  - the watch theme: Automatic, Light or Dark;
  - **Share Trip Log**: a CSV of your last five trips, for checking a ride afterwards;
  - the versions in the footer ("v0.4 (iPhone) & v0.4 (Pebble)"), with a note when the
    watchapp needs an update.
- **Native iOS look:** SwiftUI, the system font and Liquid Glass on iOS 26. It runs from
  iOS 17.

### Languages
Vietnamese and English, following the phone's language, in both the iPhone app and the
watchapp. Directions on the watch need the watch's Vietnamese language pack for the accented
letters.

## How it works

```
 iPhone                                                                         Pebble
┌───────────────────────────┐   127.0.0.1:8765   ┌──────────────────────┐  Bluetooth  ┌──────────┐
│ PebbleOpenNav             │ ◀──── GET /step ── │ Pebble iPhone app    │ ◀── Tick ── │ watchapp │
│ GPS · route · guidance    │ ── next step ────▶ │ (watchapp JavaScript)│ ── step ──▶ │          │
└───────────────────────────┘                    └──────────────────────┘             └──────────┘
```

1. **GPS and guidance:** PebbleOpenNav gets a GPS fix about once a second. It places you on
   the route and works out the next instruction, the distance to it, your speed along the
   route, and the distance and time left.
2. **A tiny local server:** it serves the latest step on `127.0.0.1:8765`, which only the
   phone itself can reach.
3. **The watch asks:** the watchapp's JavaScript runs inside the Pebble iPhone app, which
   holds the Bluetooth link. Each time the watch asks for an update, the JavaScript fetches
   the step and sends it to the watch as one small message.
4. **The phone sets the pace:** each answer says when to ask next. That's every second within
   60 m of a turn or when you're off the route, every 2 s within 300 m (3 s when you're
   stopped), every 3 s within 1 km, and every 10 s beyond. In between, the watch counts down by
   itself.

Your coordinates never reach the watch, only the result. The full contract (JSON fields,
message keys, timings, connection states) is in [PROTOCOL.md](PROTOCOL.md).

## Install

You need:
- an iPhone with iOS 17 or later;
- a Pebble watch, paired with the Pebble iPhone app;
- a Mac or PC to sideload the iPhone app.

1. **Get the iPhone app.**
   - Open the latest successful [**Build iPhone app**](../../actions/workflows/build-ipa.yml)
     run on GitHub Actions and download the **PebbleOpenNav-ipa** artifact. It's an unsigned
     `PebbleOpenNav.ipa`.
   - Or build it yourself (see below).
2. **Sideload it** with [Sideloadly](https://sideloadly.io) or [AltStore](https://altstore.io)
   using your Apple ID.
   - With a free Apple ID, the app must be re-signed every 7 days.
   - On iOS 16 and later, turn on **Settings → Privacy & Security → Developer Mode**.
3. **Allow location** when PebbleOpenNav asks. Keep **Precise Location** on, because
   turn-by-turn needs it.
4. **Install the watchapp.** It is a separate file: `navwatch/build/navwatch.pbw` in this
   repository, or the `.pbw` that comes with each build. Open it with the Pebble app from Files
   or AirDrop. When the Pebble section's footer says "Pebble app not up to date", install the
   newer `.pbw` the same way.
5. **Ride.**
   - Search for a place, pick your vehicle and tap **Go**.
   - Open **PebbleOpenNav** on the watch.
   - Lock the phone and put it away.

## Build it yourself

### iPhone app
- **GitHub Actions** (no Mac needed): pushing changes under `navapp/` runs
  [`build-ipa.yml`](.github/workflows/build-ipa.yml). It builds on the `macos-26` runner with
  its newest stable Xcode 26, which Liquid Glass needs. You can also start it by hand from
  the Actions tab.
- **Locally:** you need Xcode 26 or later and XcodeGen.

  ```bash
  brew install xcodegen
  ```

  ```bash
  navapp/scripts/build-ipa.sh
  ```

  The project is generated from [`navapp/project.yml`](navapp/project.yml). The build writes
  `navapp/build/PebbleOpenNav.ipa`.
- **Type-check without Xcode** (Mac Catalyst with the Command Line Tools):

  ```bash
  navapp/scripts/typecheck.sh
  ```

### Watchapp
You need the [Pebble SDK](https://developer.repebble.com) (`pebble` tool).

```bash
cd navwatch && pebble build
```

The build writes `navwatch/build/navwatch.pbw` for all seven Pebble platforms. After changing
`messageKeys` in `navwatch/package.json`, run `pebble clean` first.

The turn icons are bitmaps made from the designs in `design/icons/` (`icons-48x56.svg` and
`icons-44x52.svg`). After changing them, regenerate the bitmaps in
`navwatch/resources/images/icons/`:

```bash
python3 navwatch/tools/build_icons.py
```

### Testing without a ride
- **Watch emulator with a fake phone:** [`navwatch/mock_server.py`](navwatch/mock_server.py)
  plays a scripted trip on `127.0.0.1:8765`. Start it **before** installing the watchapp,
  because the emulator's JavaScript hangs on a refused connection.

  ```bash
  python3 navwatch/mock_server.py
  ```

  ```bash
  pebble install --emulator emery
  ```

  ```bash
  curl '127.0.0.1:8765/start?at=1500&theme=light&lang=en'
  ```

  `/pause` shows Connecting… and then Disconnected, `/error` shows Disconnected after two
  failed requests, and `/resume` goes back to normal. See
  [`navwatch/README.md`](navwatch/README.md).
- **Real routes on the Mac:** [`navsim`](navapp/Tools/navsim/main.swift) runs the iPhone
  app's guidance code.
  - It can drive a real Valhalla route at a set speed and serve it to the watch emulator.
  - `--replay` feeds a trip log from **Share Trip Log** back through the guidance, to see
    what the watch would have shown.

## Supported watches

| Watch | SDK platform | Layout |
|---|---|---|
| Pebble Time 2 | `emery` | colour, large text |
| Pebble Round 2 | `gabbro` | colour, round, large text |
| Pebble 2 Duo | `flint` | black and white |
| Pebble Time, Time Steel | `basalt` | colour |
| Pebble Time Round | `chalk` | colour, round |
| Pebble 2 | `diorite` | black and white |
| Pebble, Pebble Steel | `aplite` | black and white |

## Project layout

| Path | What it is |
|---|---|
| `navapp/Sources/Core/` | Routing (Valhalla), address search (Photon), guidance, the turn texts, the local server, trip logs. Shared with `navsim`. |
| `navapp/Sources/App/` | The iPhone app (SwiftUI and MapKit): search, place cards, trip, Pebble settings. |
| `navapp/Sources/Widget/` | The Live Activity. |
| `navapp/Tools/navsim/` | Mac stand-in for the iPhone app, and the trip-log replay. |
| `navwatch/src/c/` | The watchapp (C). |
| `navwatch/src/pkjs/` | The watchapp's JavaScript, which runs inside the Pebble iPhone app. |
| `navwatch/mock_server.py` | Fake phone for the watch emulator. |
| `navwatch/tools/build_icons.py` | Makes the watch's icon bitmaps from `design/icons/`. |
| `design/` | The watch layout spec ([`WATCH_LAYOUT.md`](design/WATCH_LAYOUT.md)), the exact values from the Figma design, and the icon designs (`icons/`). |
| `PROTOCOL.md` | The phone ↔ JavaScript ↔ watch contract. |

## Privacy

There are no accounts, analytics or servers of our own. Three services are involved:
- **Apple** receives your search text through MapKit, as in Apple Maps.
- **[Photon](https://photon.komoot.io)** by komoot receives searches that start with a house
  number.
- **Valhalla**, on the public FOSSGIS server `valhalla1.openstreetmap.de`, receives
  your position and the destination when a route is calculated, and your position again on a
  reroute.

GPS runs only during a trip you start. Trip logs stay on the phone (the last five trips) and
leave it only when you tap **Share Trip Log**.

## Limitations
- iPhone only.
- The app isn't on the App Store: it is sideloaded, and with a free Apple ID it is re-signed
  every 7 days.
- Routing needs an internet connection and uses a public server without guarantees.
- Live traffic is shown on the map but not used for routes or ETAs: Valhalla has no traffic
  data.

## Credits
- Map data © [OpenStreetMap](https://www.openstreetmap.org/copyright) contributors, under
  the ODbL.
- Routing by [Valhalla](https://github.com/valhalla/valhalla), on the public server run by
  [FOSSGIS](https://www.fossgis.de).
- Address search by [Photon](https://github.com/komoot/photon) from komoot.
- Place search, the map and traffic by Apple MapKit.
- Built on [PebbleOS](https://github.com/coredevices/pebbleos) and the Pebble SDK.

## License

[MIT](LICENSE)
