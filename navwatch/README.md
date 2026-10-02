# PebbleOpenNav watchapp

A Pebble watchapp/watchface written in C using the Pebble SDK.

## Building & running

```sh
pebble build                          # build for all targetPlatforms
pebble install --emulator emery       # install on the emery emulator
pebble install --phone <ip>           # install to a paired phone
```

After changing `messageKeys` in `package.json`, run `pebble clean` before `pebble build`;
the build doesn't regenerate the keys otherwise.

The build writes `build/navwatch.pbw`. To install it on a watch, open that file with the
Pebble iPhone app (from Files or AirDrop); the iPhone app no longer bundles it.

The turn icons are bitmaps made from `../design/icons/icons-48x56.svg` (Time 2, Round 2) and
`icons-44x52.svg` (the other watches, 1 bit on black and white). After changing a board, run
this from the repository root (needs numpy and Pillow):

```sh
python3 navwatch/tools/build_icons.py
```

`VERSION` in `src/pkjs/index.js` (now `0.4`) is sent as `&v=` with every `/step` request, so
the iPhone app can tell when the watchapp is out of date. Bump it with `package.json`'s
`version`.

## Emulator with the mock server

`mock_server.py` stands in for the iPhone app (see its docstring and `../PROTOCOL.md`):

```sh
python3 mock_server.py &              # 127.0.0.1:8765; SPEED=60 for a fast trip, PORT=... elsewhere
pebble install --emulator emery
curl '127.0.0.1:8765/start?at=1500&lang=en&theme=light'
curl 127.0.0.1:8765/plan              # where each step and corner of the scripted trip is (for at=)
curl '127.0.0.1:8765/step?maneuver=13&text=Test'   # any icon; maneuver=0 for the trip's own again
curl 127.0.0.1:8765/pause             # no answer in time: Connecting… after 20 s, Disconnected after 40 s
curl 127.0.0.1:8765/error             # 503: State 3, Disconnected after two
curl 127.0.0.1:8765/resume
```

## Target platforms

`targetPlatforms` in `package.json` controls which watches you build for. The
modern Pebble hardware is **emery** (Pebble Time 2), **gabbro** (Pebble Round
2), and **flint** (Pebble 2 Duo); the original Pebble platforms (aplite,
basalt, chalk, diorite) are included by default for backwards compatibility.

## Project layout

```
src/c/           C source for the watchapp
src/pkjs/        PebbleKit JS (phone-side) source, if any
worker_src/c/    Background worker source, if any
resources/       Images, fonts, and other bundled resources
tools/           build_icons.py: the 20 turn icons in resources/images/icons, from ../design/icons
package.json     Project metadata (UUID, platforms, resources, message keys)
wscript          Build rules — usually no need to edit
```

By default this project is configured as a watchapp. To make it a watchface,
set `pebble.watchapp.watchface` to `true` in `package.json`.

## Documentation

Full SDK docs, tutorials, and API reference: <https://developer.repebble.com>
