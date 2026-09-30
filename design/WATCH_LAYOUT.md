# Watch layout (from PebbleOpenNav-UI.fig)

The exact values are in `figma-layers.txt` (all layers, positions relative to each screen's
top-left) and `figma-icons.txt` (icon outlines). The decisions agreed with the designer
are below.

Platforms:
- asterix: Pebble 2 Duo, SDK platform `flint`, 144×168, black and white
- obelix: Pebble Time 2, `emery`, 200×228, colour
- getafix: Pebble Round 2, `gabbro`, 260×260 round, colour

The app also builds for aplite, basalt, chalk and diorite. Use the asterix layout for
rectangular screens under 200 px tall, obelix for the others, and getafix for round ones.

## Fonts
| Figma | Pebble |
|---|---|
| Renaissance 24 Bold | `FONT_KEY_GOTHIC_24_BOLD` |
| Renaissance 18 Bold 18px | `FONT_KEY_GOTHIC_18_BOLD` |
| Renaissance 18 Bold 15px (remaining distance) | `FONT_KEY_GOTHIC_14_BOLD` |
| Renaissance 18 Regular 14–15px, Renaissance 14 Regular | `FONT_KEY_GOTHIC_14` |
| Metropolis Black 30 | `FONT_KEY_BITHAM_30_BLACK` |

## Colours
| use | light (colour) | dark (colour) | light (B&W) | dark (B&W) |
|---|---|---|---|---|
| background | white | black | white | black |
| text, icons, distance | black | white | black | white |
| band | `#00AA00` (Figma #00B50F) | black | white (Figma #F9F9F9) | black (Figma #303030) |
| band text | white | `#AAAAAA` (Figma #CAB8AC) | black | white |
| Disconnected band | `#AA0000` (Figma #B50000), white text | black band, text `#AA0000` | white band, black text | black band, white text |
| start/end arrow | `#00AA00` | `#00AA00` | black | white |

## Screens
All sizes are in pixels. Band text is always centred horizontally and vertically, and at
most 140 px wide.

**Normal / arriving / disconnected**

| | asterix | obelix | getafix |
|---|---|---|---|
| top bar | y 0–20, padding 2/4 | y 0–20 | y 0–40, two centred lines at y 2 and y 22 |
| middle | y 20–85 | y 20–128 | y 40–130 |
| band | y 85–168 | y 128–228 | y 130–260 |

- **Top bar (asterix, obelix):** remaining distance on the left, then the minutes, an 8 px
  gap and `ETA hh:mm` on the right. Both are 16 px tall at y 2.
- **Middle:** distance block (64×55: number line 30 px, unit line under it, right-aligned),
  a 20 px gap, then the icon (44×52). The group is centred in the area.
- **Disconnected:** a centred `Disconnected` replaces the top bar. The middle keeps the last
  distance and the current step's icon, and the band says `Disconnected`.
- **Arrive icon:** a ring (46 px across, 5.75 px thick) with a 29.6 px dot in the centre.
- **Turn arrows:** keep the current shapes, drawn in the 44×52 box with an 8 px stroke and
  rounded ends, like `Vector 1 (Stroke)`.

**Start and end** (padding 10, vertically centred):
- navigation arrow `Polygon 1` (31.2×33.8, rotated 39.6° clockwise)
- 2 px gap
- title, `FONT_KEY_GOTHIC_24_BOLD`, centred
- 10 px gap
- subtitle, `FONT_KEY_GOTHIC_14`, centred (regular on every platform)

| screen | title | subtitle |
|---|---|---|
| start | "Start navigation on the mobile app"; "Finding route..." while routing | GPS line from the JS probe |
| end, arrived | "You have arrived" | "Navigation ended" |
| end, stopped | "Navigation ended" | "Stopped on phone" |

## Vietnamese texts (watch)
| English | Vietnamese |
|---|---|
| Start navigation on the mobile app | Bắt đầu chỉ đường trên điện thoại |
| Finding route... | Đang tìm đường... |
| You have arrived | Bạn đã tới nơi |
| Navigation ended | Đã kết thúc chỉ đường |
| Stopped on phone | Đã dừng trên điện thoại |
| Disconnected | Mất kết nối |
| Waiting for phone… | Đang chờ điện thoại… |
| GPS in 0.4s, ±8m | GPS sau 0.4s, ±8m |
| GPS 3s old, ±8m | GPS cũ 3s, ±8m |
