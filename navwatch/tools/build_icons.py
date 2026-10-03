#!/usr/bin/env python3
"""Turn icons from the Figma icon boards into the watchapp's bitmaps.

    python3 navwatch/tools/build_icons.py

Reads design/icons/icons-48x56.svg and icons-44x52.svg: Figma exports of a 5x4 board of frames
named icon/<name>/<WxH>, each with its name as a label underneath. Every icon is rasterized at
exact coverage (8x8 samples per pixel) and written to navwatch/resources/images/icons/:
  48/<name>.png      white with 2-bit alpha, for Time 2 and Round 2 (recoloured on the watch)
  44/<name>.png      the same at 44x52, for Time, Time Steel and Time Round
  44-bw/<name>.png   1 bit, white on black, for Pebble, Pebble 2 and Pebble 2 Duo
It also writes the launcher icon, navwatch/resources/images/menu-icon.png, from
design/icons/icon-menu-25x25.svg: its own greys with 2-bit alpha, which the launcher tints
(at most 25x25 px for an SDK 4 app, or the watch shows its default icon).

Figma exports a frame's position only when it clips its content, so the other frames are found
from their labels: centred above the label, at the offset the clipped frames show.
Needs numpy and Pillow.
"""
import os, re, sys
import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
NAMES = ["straight", "turn-left", "turn-right", "slight-left", "slight-right", "sharp-left", "sharp-right",
         "keep-left", "keep-right", "arrive", "uturn-left", "uturn-right", "roundabout-right", "roundabout-left",
         "roundabout-straight", "roundabout-uturn", "ramp-left", "ramp-right", "merge-left", "merge-right"]
SS = 8  # samples per pixel, each way

# --- SVG paths ---

def parse(d):
    """M L H V C S Q Z, absolute or relative -> subpaths of ('L', pt) / ('C', c1, c2, pt)."""
    toks = re.findall(r'[MmLlHhVvCcSsQqZz]|-?(?:\d+\.?\d*|\.\d+)(?:e-?\d+)?', d)
    i, cmd, cur, start, subs, sub, last_c2 = 0, None, (0.0, 0.0), (0.0, 0.0), [], None, None
    def num():
        nonlocal i
        i += 1
        return float(toks[i - 1])
    while i < len(toks):
        if re.match(r'[A-Za-z]', toks[i]):
            cmd = toks[i]; i += 1
        rel, C = cmd.islower(), cmd.upper()
        ox, oy = cur if rel else (0, 0)
        if C == 'M':
            cur = (ox + num(), oy + num()); start = cur; sub = [('M', cur)]; subs.append(sub)
            cmd = 'l' if rel else 'L'; last_c2 = None
        elif C == 'L':
            cur = (ox + num(), oy + num()); sub.append(('L', cur)); last_c2 = None
        elif C == 'H':
            cur = ((cur[0] if rel else 0) + num(), cur[1]); sub.append(('L', cur)); last_c2 = None
        elif C == 'V':
            cur = (cur[0], (cur[1] if rel else 0) + num()); sub.append(('L', cur)); last_c2 = None
        elif C == 'C':
            c1 = (ox + num(), oy + num()); c2 = (ox + num(), oy + num()); p = (ox + num(), oy + num())
            sub.append(('C', c1, c2, p)); cur = p; last_c2 = c2
        elif C == 'S':
            c1 = (2 * cur[0] - last_c2[0], 2 * cur[1] - last_c2[1]) if last_c2 else cur
            c2 = (ox + num(), oy + num()); p = (ox + num(), oy + num())
            sub.append(('C', c1, c2, p)); cur = p; last_c2 = c2
        elif C == 'Q':
            q = (ox + num(), oy + num()); p = (ox + num(), oy + num())
            c1 = (cur[0] + 2 / 3 * (q[0] - cur[0]), cur[1] + 2 / 3 * (q[1] - cur[1]))
            c2 = (p[0] + 2 / 3 * (q[0] - p[0]), p[1] + 2 / 3 * (q[1] - p[1]))
            sub.append(('C', c1, c2, p)); cur = p; last_c2 = None
        elif C == 'Z':
            sub.append(('L', start)); cur = start; last_c2 = None
    return subs

def flatten(subs, step):
    """Polylines, with a point every ~step px along curves."""
    out = []
    for sub in subs:
        pts = [sub[0][1]]
        for seg in sub[1:]:
            if seg[0] == 'L':
                pts.append(seg[1]); continue
            p0, (c1, c2, p) = pts[-1], seg[1:]
            n = max(2, int(sum(np.hypot(a[0] - b[0], a[1] - b[1]) for a, b in [(p0, c1), (c1, c2), (c2, p)]) / step))
            for k in range(1, n + 1):
                t = k / n; u = 1 - t
                pts.append((u**3 * p0[0] + 3 * u * u * t * c1[0] + 3 * u * t * t * c2[0] + t**3 * p[0],
                            u**3 * p0[1] + 3 * u * u * t * c1[1] + 3 * u * t * t * c2[1] + t**3 * p[1]))
        out.append(pts)
    return out

def bbox(d):
    pts = np.array([p for poly in flatten(parse(d), 0.5) for p in poly])
    return (*pts.min(axis=0), *pts.max(axis=0))

# --- coverage in a w x h frame at (ox, oy) ---

def samples(ox, oy, w, h):
    ys, xs = np.mgrid[0:h * SS, 0:w * SS]
    return (xs + 0.5) / SS + ox, (ys + 0.5) / SS + oy

def fill(d, ox, oy, w, h, evenodd=False):
    """Nonzero (or even-odd) fill; open subpaths are closed, as SVG fills them."""
    px, py = samples(ox, oy, w, h)
    wind = np.zeros(px.shape, int)
    for poly in flatten(parse(d), 0.1):
        if poly[0] != poly[-1]: poly = poly + [poly[0]]
        for (x0, y0), (x1, y1) in zip(poly, poly[1:]):
            if y0 == y1: continue
            up = y1 > y0
            lo, hi = (y0, y1) if up else (y1, y0)
            m = (py >= lo) & (py < hi)
            cx = x0 + (py - y0) * (x1 - x0) / (y1 - y0)
            wind += np.where(m & (cx > px), 1 if up else -1, 0)
    inside = (wind % 2 == 1) if evenodd else (wind != 0)
    return inside.reshape(h, SS, w, SS).mean(axis=(1, 3))

def stroke(d, width, ox, oy, w, h):
    """Round caps and joins: every sample within width/2 of the centre line."""
    px, py = samples(ox, oy, w, h)
    inside = np.zeros(px.shape, bool)
    for poly in flatten(parse(d), 0.05):
        if len(poly) == 1: poly = poly * 2
        for (x0, y0), (x1, y1) in zip(poly, poly[1:]):
            dx, dy = x1 - x0, y1 - y0; L2 = dx * dx + dy * dy
            t = np.clip(((px - x0) * dx + (py - y0) * dy) / L2, 0, 1) if L2 else 0
            inside |= (px - (x0 + t * dx)) ** 2 + (py - (y0 + t * dy)) ** 2 <= (width / 2) ** 2
    return inside.reshape(h, SS, w, SS).mean(axis=(1, 3))

# --- the board ---

def attrs(s):
    return dict(re.findall(r'([\w:-]+)="([^"]*)"', s))

def load(path, w, h):
    """name -> coverage (h x w, 0..1)."""
    s = open(path).read()
    clips = {}
    for m in re.finditer(r'<clipPath id="([^"]+)">\s*<rect ([^>]*)/>', s):
        a = attrs(m.group(2))
        if (a.get('width'), a.get('height')) != (str(w), str(h)): continue
        clips[m.group(1)] = tuple(map(float, re.search(r'translate\(([-\d.]+) ([-\d.]+)\)', a['transform']).groups()))
    els, clip = [], None
    for m in re.finditer(r'<g clip-path="url\(#([^)]+)\)">|</g>|<path ([^>]*?)/>', s):
        tag = m.group(0)
        if tag.startswith('<g'): clip = m.group(1); continue
        if tag == '</g>': clip = None; continue
        a = attrs(m.group(2)); b = bbox(a['d'])
        if a.get('fill') == '#444444' or b[2] - b[0] > 500: continue  # the board's background and border
        els.append(dict(a=a, b=b, clip=clip))
    is_label = lambda e: 'stroke' not in e['a'] and e['b'][3] - e['b'][1] < 14 and e['b'][2] - e['b'][0] > 60
    labels = sorted([e for e in els if is_label(e)], key=lambda e: (round(e['b'][1] / 50), e['b'][0]))
    shapes = [e for e in els if not is_label(e)]
    if len(labels) != len(NAMES): sys.exit(f'{path}: expected {len(NAMES)} labels, found {len(labels)}')
    cx = lambda e: (e['b'][0] + e['b'][2]) / 2
    for e in shapes:  # each shape belongs to the nearest label below it
        y = (e['b'][1] + e['b'][3]) / 2
        e['icon'] = min(range(len(labels)), key=lambda i: abs(cx(labels[i]) - cx(e)) +
                        (1e6 if labels[i]['b'][1] < y else labels[i]['b'][1] - y))
    clipped = {e['icon']: clips[e['clip']] for e in shapes if e['clip'] in clips}
    if not clipped: sys.exit(f'{path}: no clipped frame to calibrate the label offset from')
    off = [(f[0] - (cx(labels[i]) - w / 2), labels[i]['b'][1] - f[1]) for i, f in clipped.items()]
    dx, dy = np.median([o[0] for o in off]), np.median([o[1] for o in off])
    if max(abs(o[0] - dx) for o in off) > 0.5 or max(abs(o[1] - dy) for o in off) > 0.5:
        sys.exit(f'{path}: the labels sit at different offsets from their frames: {off}')
    out = {}
    for i, name in enumerate(NAMES):
        fx, fy = clipped.get(i, (round(cx(labels[i]) - w / 2 + dx), round(labels[i]['b'][1] - dy)))
        cov = np.zeros((h, w))
        for e in (e for e in shapes if e['icon'] == i):
            a, b = e['a'], e['b']
            if 'stroke' in a:
                width = float(a['stroke-width'])
                if a.get('stroke-linecap') != 'round' or a.get('stroke-linejoin', 'round') != 'round':
                    sys.exit(f'{path}: {name}: only round caps and joins are supported')
                c, pad = stroke(a['d'], width, fx, fy, w, h), width / 2
            else:
                c, pad = fill(a['d'], fx, fy, w, h, a.get('fill-rule') == 'evenodd'), 0
            if b[0] - pad < fx - .01 or b[1] - pad < fy - .01 or b[2] + pad > fx + w + .01 or b[3] + pad > fy + h + .01:
                print(f'warning: {path}: {name} reaches outside its frame and is cut off', file=sys.stderr)
            cov = np.maximum(cov, c)
        out[name] = cov
    return out

def save(cov, path, bw):
    if bw:  # 1 bit: white where at least half covered
        Image.fromarray(np.where(cov >= 0.5, 255, 0).astype(np.uint8)).convert('1').save(path)
    else:   # white, alpha in Pebble's 4 levels
        a = (np.round(cov * 3) * 85).astype(np.uint8)
        rgba = np.dstack([np.full(cov.shape, 255, np.uint8)] * 3 + [a])
        Image.fromarray(rgba).save(path)  # 4 channels: RGBA

def menu_icon(path, out):
    """The whole of a single-icon SVG (its viewBox): filled rects and paths, painted in order in
    their own grey (black, white or #rrggbb), over transparent."""
    s = open(path).read()
    w, h = (int(float(v)) for v in re.search(r'viewBox="0 0 ([\d.]+) ([\d.]+)"', s).groups()[:2])
    if w > 25 or h > 25: sys.exit(f'{path}: {w}x{h} is larger than the 25x25 the launcher shows')
    s = re.sub(r'<defs>.*?</defs>', '', s, flags=re.S)  # clip paths: the frame itself
    grey, alpha = np.zeros((h, w)), np.zeros((h, w))
    for m in re.finditer(r'<(path|rect)\b([^>]*?)/>', s):
        a = attrs(m.group(2))
        if 'stroke' in a: sys.exit(f'{path}: outline the strokes first (only fills are supported here)')
        if m.group(1) == 'rect':
            x, y, rw, rh = (float(a.get(k, 0)) for k in ('x', 'y', 'width', 'height'))
            d = f'M{x} {y}H{x + rw}V{y + rh}H{x}Z'
        else:
            d = a['d']
        colour = a.get('fill', 'black').lower()
        if colour == 'none': continue
        rgb = {'black': '000000', 'white': 'ffffff'}.get(colour, colour.lstrip('#'))
        g = sum(int(rgb[i:i + 2], 16) for i in (0, 2, 4)) / 3 / 255
        c = fill(d, 0, 0, w, h, a.get('fill-rule') == 'evenodd')
        grey = (grey * alpha * (1 - c) + g * c) / np.maximum(alpha * (1 - c) + c, 1e-9)
        alpha = alpha * (1 - c) + c
    v = (np.round(grey * 3) * 85).astype(np.uint8)
    Image.fromarray(np.dstack([v, v, v, (np.round(alpha * 3) * 85).astype(np.uint8)])).save(out)  # RGBA

def main():
    images = os.path.join(ROOT, 'navwatch', 'resources', 'images')
    menu_icon(os.path.join(ROOT, 'design', 'icons', 'icon-menu-25x25.svg'), os.path.join(images, 'menu-icon.png'))
    print('menu icon: 1')
    out = os.path.join(images, 'icons')
    for size, w, h, kinds in (('48x56', 48, 56, [('48', False)]), ('44x52', 44, 52, [('44', False), ('44-bw', True)])):
        icons = load(os.path.join(ROOT, 'design', 'icons', f'icons-{size}.svg'), w, h)
        for folder, bw in kinds:
            os.makedirs(os.path.join(out, folder), exist_ok=True)
            for name, cov in icons.items():
                save(cov, os.path.join(out, folder, name + '.png'), bw)
        print(f'{size}: {len(icons)} icons')

if __name__ == '__main__':
    main()
