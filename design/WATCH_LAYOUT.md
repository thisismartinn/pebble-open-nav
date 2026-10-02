# Watch layout v4 (from PebbleOpenNav-UI-2.fig)

v4 keeps the v3 layout and adds the 20 turn icons from the designer's icon boards (below) and
the ease-in screen.

The exact values are in `figma-layers.txt` (all layers, positions relative to each screen's
top-left) and `figma-icons.txt` (icon outlines). The Figma file's "Draft/Experiment" section
and colour tab are not part of the design. The decisions agreed with the designer are below;
where they differ from the Figma, they win.

Platforms:
- asterix: Pebble 2 Duo, SDK platform `flint`, 144×168, black and white
- obelix: Pebble Time 2, `emery`, 200×228, colour
- getafix: Pebble Round 2, `gabbro`, 260×260 round, colour

The app also builds for aplite, basalt, chalk and diorite:
- **Size:** only obelix and getafix get v3's bigger fonts and icons. Every other platform keeps
  the v2 sizes: aplite, basalt, diorite and flint use the asterix layout, and chalk uses its
  scaled-getafix layout.
- **Colour:** every colour platform (basalt, chalk, emery, gabbro) gets the v3 colours, and
  every black-and-white platform (aplite, diorite, flint) gets the B&W colours. The turn icons
  and the new texts apply everywhere.

## Fonts
| Figma | Pebble |
|---|---|
| Renaissance 24 Bold | `FONT_KEY_GOTHIC_24_BOLD` |
| Renaissance 18 Bold 18px | `FONT_KEY_GOTHIC_18_BOLD` |
| Renaissance 18 Regular 18px, Renaissance 14 Regular **18px** | `FONT_KEY_GOTHIC_18` |
| Renaissance 18 Bold 15px (remaining distance, small watches) | `FONT_KEY_GOTHIC_14_BOLD` |
| Renaissance 18 Regular 14–15px, Renaissance 14 Regular 14px | `FONT_KEY_GOTHIC_14` |
| Metropolis Black 30 (small watches) | `FONT_KEY_BITHAM_30_BLACK` |
| Metropolis Black 42 (obelix, getafix) | `FONT_KEY_BITHAM_42_BOLD` (the heaviest Pebble font at 42 px with letters; checked: `m`, `k`, `.`, `,` render) |

## Colours
Colour platforms:

| | light | dark |
|---|---|---|
| background (top bar + middle; the whole circle on round) | `#00AA00` | black |
| top bar text, distance, turn icon, arrive arrow | white | white |
| band | white | black |
| band text | black | `#AAAAAA` |
| **Disconnected** background | `#AA0000` | `#AA0000` |
| Disconnected top text, distance, icon | white | white |
| Disconnected band / text | white / black | black / `#AAAAAA` |
| **Connecting…** | as the normal screen | as the normal screen |
| **start**: background / arrow / title / subtitle | white / `#00AA00` / black / black | black / `#00AA00` / white / white |
| **end**: background / arrow / title / subtitle | `#00AA00` / white / white / white | black / `#00AA00` / `#00AA00` / white |

Black-and-white platforms: v2, unchanged.
- **Light:** white background, black text and icons, and a **plain white band**. The Figma's
  `#AAAAAA` band is not used: on a 1-bit screen it is a checkerboard that makes the text hard
  to read (designer decision, 2026-10-02).
- **Dark:** black background, white text and icons, and a black band with white text. The
  Figma's `#AAAAAA` text comes out white on a 1-bit screen anyway.
- **Disconnected:** white band with black text (light), or black band with white text (dark).
- **Start/end arrow:** black (light) or white (dark).

## Screens
All sizes are in pixels.

### obelix (Pebble Time 2) and getafix (Pebble Round 2)
| | obelix | getafix |
|---|---|---|
| top bar | y 0–24. Remaining distance (Gothic 18 Bold) at x 4, y 2.5, h 19. Minutes and `ETA hh:mm` (Gothic 18) right-aligned to x 196, 8 px apart, y 2, h 20 | y 0–45, two centred lines: remaining distance (Gothic 18 Bold) at y 2, h 19; minutes + ETA (Gothic 18, 8 px apart) at y 23, h 20 |
| middle | y 24–128 (104) | y 45–140 (95) |
| band | y 128–228, padding 4 top, 3 right, 8 bottom, 4 left: text box x 4, y 132, w 193, h 88 | y 140–260, padding 4/4/16/4: text box x 26, y 144, w 208, h 100 |
| band text | Gothic 24 Bold, line height 24, centred both ways | same. On round, use PebbleOS's screen text flow (`graphics_text_attributes_enable_screen_text_flow`) so each line fits inside the circle |

**Middle**, as a group centred horizontally: the distance block (64×55), a 20 px gap, then the
icon. Centre the group using the icon width: 48 on obelix and getafix, 44 elsewhere.
- **Distance block:** vertically centred in the middle area, so its top is mid_y + (mid_h − 55) / 2.
  - **Number line:** the box top is 3.5 px above the block top. It is a 42 px line,
    right-aligned to the block's right edge, and may extend left past the block (e.g. "800" is
    87 px wide).
  - **Unit line:** "m" or "km". Its 20 px Figma box starts 38.5 px below the block top, with
    the 42 px line centred on that box, right-aligned to the same edge.
  - **Same rule as v2**, at the new sizes: a two-line block, or one line on round screens when it
    fits (the one-line rule from v2 stays).
- **Turn icon:** 48×56, vertically centred in the middle area (see Turn icons).

### asterix and the other small watches
Unchanged from v2. Top bar y 0–20; middle y 20–85; band y 85–168 (padding 3/2/8/2, text at most
140 wide, Gothic 18 Bold); Bitham 30 Black distance; 44×52 icons. Only the colours, the icons
and the texts change.

### Turn icons (all platforms)
20 icons, one per maneuver code (`PROTOCOL.md` §1): straight, turn-left, turn-right,
slight-left, slight-right, uturn-left, arrive, sharp-left, sharp-right, keep-left, keep-right,
uturn-right, roundabout-right, roundabout-left, roundabout-straight, roundabout-uturn,
ramp-left, ramp-right, merge-left, merge-right.
- **Source:** the designer's boards `icons/icons-48x56.svg` and `icons/icons-44x52.svg`.
  `python3 navwatch/tools/build_icons.py` turns them into bitmaps in
  `navwatch/resources/images/icons/`; run it again after changing a board.
- **Sizes:** 48×56 on obelix and getafix, 44×52 on every other platform.
- **Colour:** white with 2-bit alpha on colour platforms, drawn in the icon colour. 1-bit white
  on black on the black-and-white platforms.
- **Arrive:** the upright navigation arrow, from the same boards.

### Ease-in (the ToCorner phase)
From 25–45 m before the corner being taken, the screen shows the next step's icon, and the
distance counts down to that corner. The band is empty. Below 10 m it switches to the next
step's full screen. Roundabouts have no ease-in.

### Disconnected
The background is `#AA0000` (colour) in both themes.
- **Top bar:** shows `Disconnected` instead of the distances, centred.
  - obelix: Gothic 18 Bold, bar y 0–23, text y 2, h 19; middle y 23–128.
  - getafix: Gothic 18 Bold, bar y 0–35, text y 8, h 19; middle y 35–140.
  - Small watches: v2 (Gothic 14, bar y 0–21).
- **Middle:** keeps the last distance and the current step's icon.
- **Band:** says `Connection lost`.

### Connecting… (new, not in the Figma)
The normal screen, with the same colours and geometry as the step. Only the top bar's contents
change to `Connecting…`, centred, in the font the Disconnected top text uses on that platform.
It is vertically centred in the normal top bar; on getafix, in the 45 px bar.

### Start and end
Padding 10, vertically centred: navigation arrow `Polygon 1` (31.2×33.8, rotated 39.6°
clockwise), a 2 px gap, the title (Gothic 24 Bold, centred), a 10 px gap, then the subtitle
(centred). The subtitle is **Gothic 18** on obelix and getafix (Figma 18 px) and Gothic 14
elsewhere.

| screen | title | subtitle |
|---|---|---|
| start | "Start navigation on the mobile app"; "Finding route..." while routing | GPS line from the JS probe |
| end, arrived | "You have arrived" | "Navigation ended" |
| end, stopped | "Navigation ended" | "Stopped on phone" |

## Texts (watch)
| English | Vietnamese |
|---|---|
| Start navigation on the mobile app | Bắt đầu chỉ đường trên điện thoại |
| Finding route... | Đang tìm đường... |
| You have arrived | Bạn đã tới nơi |
| Navigation ended | Đã kết thúc chỉ đường |
| Stopped on phone | Đã dừng trên điện thoại |
| Arriving at destination | (unchanged from v2) |
| Disconnected | **Kết nối bị ngắt** |
| Connection lost | **Đã mất kết nối** |
| Connecting… | **Đang kết nối…** |
| Waiting for phone… | Đang chờ điện thoại… |
| GPS in 0.4s, ±8m | GPS sau 0.4s, ±8m |
| GPS 3s old, ±8m | GPS cũ 3s, ±8m |

## Connection states (behaviour)
These apply during a trip. A "reply" is any message from the phone JS: a step, a `State`, or an
`Ended`.

| situation | screen |
|---|---|
| a reply within the last 20 s, Bluetooth up | normal |
| no reply for 20 s | Connecting… (the countdown has already stopped at its 20 s limit) |
| no reply for 40 s | Disconnected |
| Bluetooth to the phone drops (`connection_service`) | Connecting… at once; Disconnected if not back within 10 s |
| the JS reports the nav app gone (`State` 3) twice in a row | Disconnected at once |

When the connection comes back, the next good step returns the watch to the normal screen. The
old rule ("Disconnected after 10 s without an update") is removed.
