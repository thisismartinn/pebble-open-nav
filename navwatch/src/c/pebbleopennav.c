#include <pebble.h>

// Polls the phone for the current navigation step (PROTOCOL.md). The watch drives
// the polling so that each request wakes the (possibly suspended) Pebble iOS app;
// the phone suggests when to ask next (Poll).
#define POLL_MS 3000            // without the phone's Poll (older nav app, State 3)
#define POLL_NEAR_MS 1000       // poll faster when the turn is close
#define POLL_NEAR_M 300
#define POLL_HINT_MIN_MS 500    // the phone's Poll is clamped to this range
#define POLL_HINT_MAX_MS 10000
#define RETRY_MS 500            // after an outbox failure or APP_MSG_BUSY
#define PREDICT_MAX_MS 20000    // stop counting down this long after the fix...
#define PREDICT_MAX_M 500       // ...or this far from it (10 s polls at highway speed)
#define CONNECTING_MS 20000     // no reply for this long during a trip: Connecting…
#define LOST_MS 40000           // ...and for this long: Disconnected
#define BT_LOST_MS 10000        // Bluetooth to the phone down for this long: Disconnected
#define END_SCREEN_MS 10000

enum {
  M_NONE = 0, M_STRAIGHT, M_LEFT, M_RIGHT, M_SLIGHT_LEFT, M_SLIGHT_RIGHT, M_UTURN, M_ARRIVE
};
enum { SCR_START, SCR_NAV, SCR_CONNECTING, SCR_DISCONNECTED, SCR_END };
// State values from the JS; ST_WAITING until the JS first answers.
enum { ST_WAITING = 0, ST_NO_TRIP = 1, ST_ROUTING = 2, ST_NO_PHONE = 3 };

static Window *s_window;
static Layer *s_layer;
static GPath *s_nav_arrow, *s_arrive_arrow;
static GTextAttributes *s_band_flow;  // getafix: the band's lines follow the circle
static AppTimer *s_poll_timer, *s_second_timer;
static int64_t s_poll_due_ms;

// The current step, as received. Distance and remaining are at the GPS fix, which
// was s_age_ms old when the JS got it; s_rx_ms is when the watch got it.
static int32_t s_step_id;       // from the nav app; a change means a new step (0: not sent)
static int s_maneuver = M_NONE;
static int s_distance, s_remain_m, s_remain_s, s_speed_cms, s_age_ms;
static int64_t s_rx_ms;
static char s_instr[96] = "";
static char s_gps[48] = "";
static int s_state = ST_WAITING;
static bool s_trip = false;      // showing a step (or Connecting…/Disconnected with the last one)
static bool s_had_trip = false;  // seen a real step this session, so an "ended" is ours
static bool s_ended = false, s_arrived = false;
static bool s_nudge_200, s_nudge_100;  // armed "nudge nudge" thresholds of this step

// The link to the phone during a trip (design/WATCH_LAYOUT.md, connection states). A
// reply is any message from the JS: a step, a State or an Ended.
static int64_t s_reply_ms;    // the last reply
static int64_t s_bt_down_ms;  // when Bluetooth to the phone dropped; 0 while it is up
static bool s_no_phone;       // the last reply was State 3 (the nav app not answering)
static bool s_lost;           // Disconnected, until the next good step

// Vietnamese or English. Starts from the watch's language (set by its language
// pack), then follows the phone's language, which the JS sends with every message.
static bool s_vi = false;
#define TR(en, vi) (s_vi ? (vi) : (en))

// Light theme: dark text on white is far easier to read in sunlight. The phone
// decides (automatic: sunrise to sunset). Until it answers at launch, a fixed
// Light/Dark choice is reused; with Automatic the watch guesses by the time of day.
#define PERSIST_KEY_LIGHT 1
#define PERSIST_KEY_AUTO 2
static bool s_light = false;

// fg is the top bar, distance and icon on the step screens, and the subtitle on the
// start and end screens; band and band_text are only used by the step screens.
typedef struct {
  GColor bg, fg, band, band_text, arrow, title;
} Theme;

// Colours from design/WATCH_LAYOUT.md. On black and white the band is the background.
static Theme prv_theme(int screen) {
#ifdef PBL_COLOR
  const GColor green = GColorIslamicGreen;  // #00AA00
  if (screen == SCR_START) {
    if (s_light) return (Theme){ .bg = GColorWhite, .fg = GColorBlack, .arrow = green, .title = GColorBlack };
    return (Theme){ .bg = GColorBlack, .fg = GColorWhite, .arrow = green, .title = GColorWhite };
  }
  if (screen == SCR_END) {
    if (s_light) return (Theme){ .bg = green, .fg = GColorWhite, .arrow = GColorWhite, .title = GColorWhite };
    return (Theme){ .bg = GColorBlack, .fg = GColorWhite, .arrow = green, .title = green };
  }
  // The step, Connecting… and Disconnected: on round screens the background is the whole circle.
  const GColor bg = screen == SCR_DISCONNECTED ? GColorDarkCandyAppleRed : s_light ? green : GColorBlack;
  if (s_light) return (Theme){ .bg = bg, .fg = GColorWhite, .band = GColorWhite, .band_text = GColorBlack };
  return (Theme){ .bg = bg, .fg = GColorWhite, .band = GColorBlack, .band_text = GColorLightGray };
#else
  if (s_light) return (Theme){ GColorWhite, GColorBlack, GColorWhite, GColorBlack, GColorBlack, GColorBlack };
  return (Theme){ GColorBlack, GColorWhite, GColorBlack, GColorWhite, GColorWhite, GColorWhite };
#endif
}

// A system font, its dy (see prv_text) and its line height.
typedef struct {
  GFont font;
  int8_t dy, h;
} Font;

// Screen areas (Figma: asterix for short rectangular screens, obelix for tall ones,
// getafix for round ones). Only obelix and getafix have v3's bigger fonts and icons;
// the others keep v2's sizes, and chalk gets getafix's v2 layout scaled to 180 px.
typedef struct {
  int16_t top1_y, top2_y;          // top bar text line boxes; top2_y 0: one line
  int16_t mid_y;                   // distance and icon, down to the band
  int16_t band_y;                  // instruction band, to the bottom of the screen
  int16_t band_text_w, band_pad_top, band_pad_bottom;
  int16_t lost_top_y, lost_mid_y;  // Disconnected: its top bar text, and where the middle starts
  int16_t icon_w, icon_h;          // turn arrows
  bool big;                        // obelix, getafix: v3 sizes
} Layout;
static Layout s_layout;

// The fonts for the layout. status: Connecting… and Disconnected in the top bar;
// band_small: the band text when it doesn't fit in band.
typedef struct {
  Font remain, top, status, dist, band, band_small, title, sub;
} Fonts;
static Fonts s_fonts;

// Everything on screen. The layer is only redrawn when this changes.
typedef struct {
  uint8_t screen, maneuver;
  bool light;
  const char *title;                   // start and end screens
  const char *status;                  // top bar instead of the distances
  char num[12], unit[4];               // distance to the next maneuver
  char remain[16], mins[16], eta[24];  // top bar
  char band[96];
  char sub[48];                        // start and end screens
} View;
static View s_view;

static int64_t prv_now_ms(void) {
  time_t s;
  uint16_t ms;
  time_ms(&s, &ms);
  return (int64_t)s * 1000 + ms;
}

// Dead reckoning since the fix: distance to the maneuver and to the destination
// count down at the last speed, until the prediction limits.
static void prv_predict(int *dist, int *remain_m, int64_t *remain_ms) {
  int64_t ms = s_age_ms + (prv_now_ms() - s_rx_ms);
  if (ms < 0) ms = 0;
  if (ms > PREDICT_MAX_MS) ms = PREDICT_MAX_MS;
  if (s_speed_cms > 0 && ms * s_speed_cms > (int64_t)PREDICT_MAX_M * 100000) {
    ms = (int64_t)PREDICT_MAX_M * 100000 / s_speed_cms;
  }
  const int moved = (int)(ms * s_speed_cms / 100000);  // cm/s × ms → m
  const int64_t spent = s_speed_cms > 0 ? ms : 0;  // standing still: the time estimate holds
  *dist = s_distance > moved ? s_distance - moved : 0;
  if (remain_m) *remain_m = s_remain_m > moved ? s_remain_m - moved : 0;
  if (remain_ms) *remain_ms = (int64_t)s_remain_s * 1000 > spent ? (int64_t)s_remain_s * 1000 - spent : 0;
}

// Distance to the maneuver: number and unit ("800" "m", "1.2" "km"), on two lines except on round screens.
static void prv_format_distance(View *v, int m) {
  if (m < 1000) {
    snprintf(v->num, sizeof(v->num), "%d", (m < 100) ? (m / 5) * 5 : (m / 10) * 10);
    strcpy(v->unit, "m");
  } else {
    if (m < 100000) snprintf(v->num, sizeof(v->num), TR("%d.%d", "%d,%d"), m / 1000, (m % 1000) / 100);
    else snprintf(v->num, sizeof(v->num), "%d", m / 1000);
    strcpy(v->unit, "km");
  }
}

// Top bar: "3.7km  11min  ETA 19:25" (PROTOCOL.md §4).
static void prv_format_top(View *v, int remain_m, int64_t remain_ms) {
  if (remain_m < 1000) snprintf(v->remain, sizeof(v->remain), "%dm", (remain_m / 10) * 10);
  else if (remain_m < 100000) {
    snprintf(v->remain, sizeof(v->remain), TR("%d.%dkm", "%d,%dkm"), remain_m / 1000, (remain_m % 1000) / 100);
  } else snprintf(v->remain, sizeof(v->remain), "%dkm", remain_m / 1000);
  const int remain_s = (int)(remain_ms / 1000);
  const int mins = remain_s > 0 ? (remain_s + 30) / 60 : 0;
  if (mins < 60) snprintf(v->mins, sizeof(v->mins), TR("%dmin", "%d phút"), mins < 1 && remain_s > 0 ? 1 : mins);
  else snprintf(v->mins, sizeof(v->mins), "%dh%02d", mins / 60, mins % 60);
  // While counting down this is the fix time + RemainS, so it doesn't flicker.
  const time_t eta = (time_t)((prv_now_ms() + remain_ms) / 1000);
  const struct tm *t = localtime(&eta);
  snprintf(v->eta, sizeof(v->eta), TR("ETA %02d:%02d", "Đến %02d:%02d"), t->tm_hour, t->tm_min);
}

// During a trip: Connecting… after CONNECTING_MS without a reply or as soon as Bluetooth
// drops; Disconnected (until the next good step) after LOST_MS without a reply, BT_LOST_MS
// without Bluetooth, or two State 3 in a row (prv_inbox_received).
static int prv_screen(void) {
  if (s_ended) return SCR_END;
  if (!s_trip) return SCR_START;
  const int64_t now = prv_now_ms();
  if (now - s_reply_ms >= LOST_MS || (s_bt_down_ms && now - s_bt_down_ms >= BT_LOST_MS)) s_lost = true;
  if (s_lost) return SCR_DISCONNECTED;
  return s_bt_down_ms || now - s_reply_ms >= CONNECTING_MS ? SCR_CONNECTING : SCR_NAV;
}

static void prv_nudge(void) {
  static const uint32_t nudge[] = { 30, 118, 30 };
  vibes_enqueue_custom_pattern((VibePattern){ .durations = nudge, .num_segments = ARRAY_LENGTH(nudge) });
}

// Recomputes what the screen shows; redraws only if that changed.
static void prv_update(void) {
  View v;
  memset(&v, 0, sizeof(v));  // padding too, for the memcmp below
  v.screen = prv_screen();
  v.light = s_light;
  if (v.screen == SCR_START) {
    // The line break is the designer's (Figma "Start navigation on the\nmobile app").
    v.title = s_state == ST_ROUTING ? TR("Finding route...", "Đang tìm đường...")
                                    : TR("Start navigation on the\nmobile app", "Bắt đầu chỉ đường\ntrên điện thoại");
    strncpy(v.sub, s_gps[0] ? s_gps : TR("Waiting for phone…", "Đang chờ điện thoại…"), sizeof(v.sub) - 1);
  } else if (v.screen == SCR_END) {
    v.title = s_arrived ? TR("You have arrived", "Bạn đã tới nơi") : TR("Navigation ended", "Đã kết thúc chỉ đường");
    strncpy(v.sub, s_arrived ? TR("Navigation ended", "Đã kết thúc chỉ đường")
                             : TR("Stopped on phone", "Đã dừng trên điện thoại"), sizeof(v.sub) - 1);
  } else {
    int dist, remain_m;
    int64_t remain_ms;
    prv_predict(&dist, &remain_m, &remain_ms);
    // "Nudge nudge" when the predicted distance crosses 200 m and 100 m, once each.
    if (s_nudge_100 && dist <= 100) {
      s_nudge_100 = s_nudge_200 = false;
      APP_LOG(APP_LOG_LEVEL_INFO, "nudge at %d m (100)", dist);
      prv_nudge();
    } else if (s_nudge_200 && dist <= 200) {
      s_nudge_200 = false;
      APP_LOG(APP_LOG_LEVEL_INFO, "nudge at %d m (200)", dist);
      prv_nudge();
    }
    v.maneuver = s_maneuver;
    prv_format_distance(&v, dist);
    if (v.screen == SCR_NAV) prv_format_top(&v, remain_m, remain_ms);
    else if (v.screen == SCR_CONNECTING) v.status = TR("Connecting…", "Đang kết nối…");
    else v.status = TR("Disconnected", "Kết nối bị ngắt");
    strncpy(v.band, v.screen == SCR_DISCONNECTED ? TR("Connection lost", "Đã mất kết nối") : s_instr,
            sizeof(v.band) - 1);
  }
  if (memcmp(&v, &s_view, sizeof(v)) != 0) {
    s_view = v;
    layer_mark_dirty(s_layer);
  }
}

// --- Drawing ---

static int prv_text_w(const char *text, GFont font) {
  return graphics_text_layout_get_content_size(text, font, GRect(0, 0, 400, 60), GTextOverflowModeWordWrap,
                                               GTextAlignmentLeft).w;
}

// Pebble fonts sit lower in their line than the Figma fonts: y here is the Figma line
// box top, and dy moves the Pebble text so the capitals are centred in that box.
static void prv_text(GContext *ctx, const char *text, Font f, GRect box, GTextAlignment align) {
  box.origin.y += f.dy;
  graphics_draw_text(ctx, text, f.font, box, GTextOverflowModeTrailingEllipsis, align, NULL);
}
#define DY14 (-2)   // Gothic 14: capitals at 5..13 of the 14 px line
#define DY18 (-3)   // Gothic 18 and 18 Bold: 7..17 of 18
#define DY24 (-4)   // Gothic 24 Bold: 10..23 of 24
#define DY30 (-4)   // Bitham 30 Black: 9..29 of 30
#define DY42 (-6)   // Bitham 42 Bold: 13..41 of 42 (digits 12..41)

// The arrive icon, Figma "Polygon 1" upright (42.84x46.38), symmetric about x 21.
#define ARRIVE_W 43
#define ARRIVE_H 46

// Pebble's polygon fill leaves out pixels along the edges, which eats the arrows' sharp
// tips (the arrive arrow came out 39x42), and a 1 px outline leaves gaps on black and
// white. So the points are 1 px inside the Figma shape and a 3 px outline adds it back.
static void prv_draw_arrow(GContext *ctx, GPath *path, GColor color) {
  graphics_context_set_fill_color(ctx, color);
  graphics_context_set_stroke_color(ctx, color);
  graphics_context_set_stroke_width(ctx, 3);
  gpath_draw_filled(ctx, path);
  gpath_draw_outline(ctx, path);
}

// v2 turn arrows in the 44x52 icon box, 8 px strokes with round ends like the Figma
// "Vector 1 (Stroke)". Pebble only draws odd widths, so each stroke is two 7 px lines
// one pixel apart; x, y are the left/top one of the pair.
static void prv_stroke(GContext *ctx, GPoint o, int x0, int y0, int x1, int y1) {
  const bool steep = abs(y1 - y0) > abs(x1 - x0);
  for (int i = 0; i < 2; i++) {
    const int dx = steep ? i : 0, dy = steep ? 0 : i;
    graphics_draw_line(ctx, GPoint(o.x + x0 + dx, o.y + y0 + dy), GPoint(o.x + x1 + dx, o.y + y1 + dy));
  }
}

static void prv_line(GContext *ctx, GPoint o, int x0, int y0, int x1, int y1) {
  graphics_draw_line(ctx, GPoint(o.x + x0, o.y + y0), GPoint(o.x + x1, o.y + y1));
}

// The icon for the maneuver, area.size.w wide and vertically centred in the area.
static void prv_draw_icon(GContext *ctx, GRect area, int maneuver, GColor fg) {
  if (maneuver == M_ARRIVE) {
    gpath_move_to(s_arrive_arrow, GPoint(area.origin.x + (area.size.w - ARRIVE_W) / 2,
                                         area.origin.y + (area.size.h - ARRIVE_H) / 2));
    prv_draw_arrow(ctx, s_arrive_arrow, fg);
    return;
  }
  graphics_context_set_stroke_color(ctx, fg);
  const GPoint o = GPoint(area.origin.x, area.origin.y + (area.size.h - s_layout.icon_h) / 2);
  if (!s_layout.big) {
    graphics_context_set_stroke_width(ctx, 7);
#define S(a, b, c, d) prv_stroke(ctx, o, a, b, c, d)
    switch (maneuver) {
      case M_STRAIGHT:     S(21, 48, 21, 4); S(21, 4, 7, 18); S(21, 4, 35, 18); break;
      case M_LEFT:         S(39, 48, 39, 18); S(39, 18, 4, 18); S(4, 18, 18, 4); S(4, 18, 18, 32); break;
      case M_RIGHT:        S(4, 48, 4, 18); S(4, 18, 39, 18); S(39, 18, 25, 4); S(39, 18, 25, 32); break;
      case M_SLIGHT_LEFT:  S(33, 48, 33, 28); S(33, 28, 9, 4); S(9, 4, 25, 4); S(9, 4, 9, 20); break;
      case M_SLIGHT_RIGHT: S(10, 48, 10, 28); S(10, 28, 34, 4); S(34, 4, 18, 4); S(34, 4, 34, 20); break;
      case M_UTURN:        S(38, 48, 38, 4); S(38, 4, 16, 4); S(16, 4, 16, 40); S(16, 40, 5, 29); S(16, 40, 27, 29); break;
      default: break;
    }
#undef S
    return;
  }
  // obelix and getafix: the v2 arrows scaled to the 48 px wide box (57 or 56 tall), each
  // stroke one 9 px line. Rounded so the strokes meet and the heads stay at 45°; mirrored
  // pairs are mirrored about the box centre. foot is the bottom end of the stem.
  graphics_context_set_stroke_width(ctx, 9);
  const int foot = s_layout.icon_h - 5;
#define S(a, b, c, d) prv_line(ctx, o, a, b, c, d)
  switch (maneuver) {
    case M_STRAIGHT:     S(23, foot, 23, 4); S(23, 4, 8, 19); S(23, 4, 38, 19); break;
    case M_LEFT:         S(43, foot, 43, 20); S(43, 20, 4, 20); S(4, 20, 20, 4); S(4, 20, 20, 36); break;
    case M_RIGHT:        S(4, foot, 4, 20); S(4, 20, 43, 20); S(43, 20, 27, 4); S(43, 20, 27, 36); break;
    case M_SLIGHT_LEFT:  S(37, foot, 37, 31); S(37, 31, 10, 4); S(10, 4, 27, 4); S(10, 4, 10, 21); break;
    case M_SLIGHT_RIGHT: S(10, foot, 10, 31); S(10, 31, 37, 4); S(37, 4, 20, 4); S(37, 4, 37, 21); break;
    case M_UTURN:        S(42, foot, 42, 4); S(42, 4, 18, 4); S(18, 4, 18, 44); S(18, 44, 6, 32); S(18, 44, 30, 32); break;
    default: break;
  }
#undef S
}

// Start and end screens: navigation arrow, title and subtitle, centred with 10 px padding.
static int prv_title_h(const char *title, int w) {
  return graphics_text_layout_get_content_size(title, s_fonts.title.font, GRect(0, 0, w, 200),
                                               GTextOverflowModeWordWrap, GTextAlignmentCenter).h;
}

static void prv_draw_message(GContext *ctx, GRect b, const View *v, Theme th) {
  const Fonts *F = &s_fonts;
  const int w = b.size.w - 20;
  // Keep the designer's line break unless the title takes fewer lines without it
  // (chalk: "Start navigation on / the / mobile app").
  const char *title = v->title;
  int title_h = prv_title_h(title, w);
  static char unbroken[64];
  const char *nl = strchr(title, '\n');
  if (nl && strlen(title) < sizeof(unbroken)) {
    strcpy(unbroken, title);
    unbroken[nl - title] = ' ';
    const int h = prv_title_h(unbroken, w);
    if (h < title_h) {
      title = unbroken;
      title_h = h;
    }
  }
  const int sub_h = graphics_text_layout_get_content_size(v->sub, F->sub.font, GRect(0, 0, w, 100),
                                                          GTextOverflowModeWordWrap, GTextAlignmentCenter).h + 1;
  const int arrow_h = 46;  // Figma lays out the rotated arrow in its 45.5x45.9 bounding box
  int y = (b.size.h - (arrow_h + 2 + title_h + 10 + sub_h)) / 2;
  gpath_move_to(s_nav_arrow, GPoint(b.size.w / 2, y + arrow_h / 2));
  prv_draw_arrow(ctx, s_nav_arrow, th.arrow);
  y += arrow_h + 2;
  graphics_context_set_text_color(ctx, th.title);
  prv_text(ctx, title, F->title, GRect(10, y, w, title_h + 8), GTextAlignmentCenter);
  y += title_h + 10;
  graphics_context_set_text_color(ctx, th.fg);
  prv_text(ctx, v->sub, F->sub, GRect(10, y, w, sub_h + 8), GTextAlignmentCenter);
}

// Height of the band text laid out with its first line box at y. On getafix the lines
// follow the circle, so the height depends on where the text is.
static int prv_band_h(const char *text, Font f, GRect area, int y, int screen_h) {
  return graphics_text_layout_get_content_size_with_attributes(
      text, f.font, GRect(area.origin.x, y + f.dy, area.size.w, screen_h - y - f.dy), GTextOverflowModeWordWrap,
      GTextAlignmentCenter, s_band_flow).h;
}

static void prv_draw(Layer *layer, GContext *ctx) {
  const View *v = &s_view;
  const Layout *L = &s_layout;
  const Fonts *F = &s_fonts;
  const GRect b = layer_get_bounds(layer);
  const int w = b.size.w, h = b.size.h;
  const Theme th = prv_theme(v->screen);
  graphics_context_set_fill_color(ctx, th.bg);
  graphics_fill_rect(ctx, b, 0, GCornerNone);
  if (v->screen == SCR_START || v->screen == SCR_END) {
    prv_draw_message(ctx, b, v, th);
    return;
  }

  // Top bar: remaining distance left, minutes and ETA right (two centred lines on round).
  // Connecting… (centred in the bar) and Disconnected replace them.
  graphics_context_set_text_color(ctx, th.fg);
  if (v->status) {
    const int y = v->screen == SCR_DISCONNECTED ? L->lost_top_y : (L->mid_y - F->status.h) / 2;
    prv_text(ctx, v->status, F->status, GRect(4, y, w - 8, F->status.h + 2), GTextAlignmentCenter);
  } else {
    const int mins_w = prv_text_w(v->mins, F->top.font), eta_w = prv_text_w(v->eta, F->top.font);
    int x = w - 4 - eta_w - 8 - mins_w, y = L->top1_y;
    if (L->top2_y) {
      prv_text(ctx, v->remain, F->remain, GRect(0, y, w, F->remain.h + 2), GTextAlignmentCenter);
      x = (w - (mins_w + 8 + eta_w)) / 2;
      y = L->top2_y;
    } else {
      prv_text(ctx, v->remain, F->remain, GRect(4, y, w / 2, F->remain.h + 2), GTextAlignmentLeft);
    }
    prv_text(ctx, v->mins, F->top, GRect(x, y, mins_w + 2, F->top.h + 2), GTextAlignmentLeft);
    prv_text(ctx, v->eta, F->top, GRect(x + mins_w + 8, y, eta_w + 2, F->top.h + 2), GTextAlignmentLeft);
  }

  // Middle: the distance block (64x55, right-aligned), a 20 px gap and the icon, centred
  // as a group. obelix and getafix centre the arrive arrow by its own width, the others
  // in the icon box. Figma: the number's line box starts 2.5 px into the block (v3: 3.5 px
  // above it), the unit's line is centred on a 20 px box 32.5 (v3: 38.5) px into it.
  const int mid_y = v->screen == SCR_DISCONNECTED ? L->lost_mid_y : L->mid_y, mid_h = L->band_y - mid_y;
  const int icon_w = v->maneuver == M_ARRIVE && L->big ? ARRIVE_W : L->icon_w;
#ifdef PBL_ROUND
  // Round screens are wide enough for the distance on one line ("800m", "1.2km"); the
  // group (text, 20 px gap, icon) stays centred. Chalk falls back to two lines if needed.
  char one[sizeof(v->num) + sizeof(v->unit)];
  snprintf(one, sizeof(one), "%.11s%.3s", v->num, v->unit);  // num[12], unit[4]
  const int one_w = prv_text_w(one, F->dist.font);
  if (one_w + 20 + icon_w <= w - 40) {
    const int x = (w - (one_w + 20 + icon_w)) / 2;
    prv_text(ctx, one, F->dist, GRect(x, mid_y + (mid_h - F->dist.h) / 2, one_w + 4, F->dist.h + 4),
             GTextAlignmentLeft);
    prv_draw_icon(ctx, GRect(x + one_w + 20, mid_y, icon_w, mid_h), v->maneuver, th.fg);
  } else
#endif
  {
    const int gx = (w - (64 + 20 + icon_w)) / 2;
    const int y2 = 2 * mid_y + mid_h - 55;  // block top, in half pixels
    GRect num = GRect(gx - 40, (y2 + 5) / 2, 104, F->dist.h + 4);
    int unit_y = (y2 + 55) / 2;
    if (L->big) {
      // Bitham 42 Bold sits lower in its line than the Figma's Metropolis, so the Figma's
      // line boxes put the text 6 px below the icon. Centre what is drawn instead, from the
      // digits' tops (row 12) to the unit's baseline (row 41), lines 31 px apart, like the icon.
      const int gap = 31, ink_h = gap + 41 - 12 + 1;
      num.origin.y = mid_y + (mid_h - ink_h) / 2 - F->dist.dy - 12;
      unit_y = num.origin.y + gap;
    }
    prv_text(ctx, v->num, F->dist, num, GTextAlignmentRight);
    prv_text(ctx, v->unit, F->dist, GRect(num.origin.x, unit_y, num.size.w, num.size.h), GTextAlignmentRight);
    prv_draw_icon(ctx, GRect(gx + 84, mid_y, icon_w, mid_h), v->maneuver, th.fg);
  }

  // Band: the instruction centred both ways in the text box, at most band_text_w wide (the
  // odd pixel of the side padding goes left, as in the Figma).
  if (!gcolor_equal(th.band, th.bg)) {
    graphics_context_set_fill_color(ctx, th.band);
    graphics_fill_rect(ctx, GRect(0, L->band_y, w, h - L->band_y), 0, GCornerNone);
  }
  const GRect area = GRect((w - L->band_text_w + 1) / 2, L->band_y + L->band_pad_top, L->band_text_w,
                           h - L->band_y - L->band_pad_top - L->band_pad_bottom);
  // A long Vietnamese instruction may not fit in the band font; use the smaller one then.
  Font font = F->band;
  int text_h = prv_band_h(v->band, font, area, area.origin.y, h);
  if (text_h > area.size.h) {
    font = F->band_small;
    text_h = prv_band_h(v->band, font, area, area.origin.y, h);
    if (text_h > area.size.h) text_h = area.size.h;
  }
  int y = area.origin.y + (area.size.h - text_h) / 2;
  if (s_band_flow && y > area.origin.y) {
    // getafix: the circle is narrower lower down, so lay the text out again where it lands.
    const int moved_h = prv_band_h(v->band, font, area, y, h);
    if (moved_h > text_h) {
      text_h = moved_h < area.size.h ? moved_h : area.size.h;
      y = area.origin.y + (area.size.h - text_h) / 2;
    }
  }
  graphics_context_set_text_color(ctx, th.band_text);
  // The box is a little taller than the lines: Pebble only draws a line whose glyphs fit.
  graphics_draw_text(ctx, v->band, font.font, GRect(area.origin.x, y + font.dy, area.size.w, text_h + 8),
                     GTextOverflowModeTrailingEllipsis, GTextAlignmentCenter, s_band_flow);
}

// --- Phone link ---

static void prv_send_tick(void *data);

static void prv_schedule_poll(uint32_t ms) {
  if (s_poll_timer) app_timer_cancel(s_poll_timer);
  s_poll_timer = app_timer_register(ms, prv_send_tick, NULL);
  s_poll_due_ms = prv_now_ms() + ms;
}

static bool prv_near(void) {
  if (!s_trip) return false;
  int dist;
  prv_predict(&dist, NULL, NULL);
  return dist < POLL_NEAR_M;
}

static void prv_send_tick(void *data) {
  s_poll_timer = NULL;
  if (s_ended) return;
  DictionaryIterator *out;
  AppMessageResult result = app_message_outbox_begin(&out);
  if (result == APP_MSG_OK) {
    dict_write_uint8(out, MESSAGE_KEY_Tick, 1);
    result = app_message_outbox_send();
  }
  if (result != APP_MSG_OK) APP_LOG(APP_LOG_LEVEL_INFO, "tick not sent (%d), retry", (int)result);
  // The reply's Poll replaces this; without one (or without a reply) it stands.
  prv_schedule_poll(result == APP_MSG_OK ? (prv_near() ? POLL_NEAR_MS : POLL_MS) : RETRY_MS);
}

static void prv_outbox_sent(DictionaryIterator *iter, void *context) {
  // Nothing to do: the next Tick is already scheduled.
}

static void prv_outbox_failed(DictionaryIterator *iter, AppMessageResult reason, void *context) {
  if (s_ended) return;
  APP_LOG(APP_LOG_LEVEL_INFO, "tick failed (%d), retry", (int)reason);
  prv_schedule_poll(RETRY_MS);
}

static void prv_quit(void *data) {
  window_stack_pop_all(true);  // empty window stack: the app exits
}

static void prv_show_ended(bool arrived) {
  s_ended = true;
  s_arrived = arrived;
  if (s_poll_timer) {
    app_timer_cancel(s_poll_timer);
    s_poll_timer = NULL;
  }
  // One light tap: the end screen says it all, and the system long pulse (500 ms) is too strong.
  static const uint32_t ended_vibe[] = { 120 };
  vibes_enqueue_custom_pattern((VibePattern){ .durations = ended_vibe, .num_segments = ARRAY_LENGTH(ended_vibe) });
  app_timer_register(END_SCREEN_MS, prv_quit, NULL);
}

static void prv_take_step(DictionaryIterator *iter) {
  Tuple *t;
  const int old_maneuver = s_trip ? s_maneuver : M_NONE;
  const int32_t old_step_id = s_step_id;
  char old_instr[sizeof(s_instr)];
  strncpy(old_instr, s_instr, sizeof(old_instr));

  s_step_id = (t = dict_find(iter, MESSAGE_KEY_StepId)) ? t->value->int32 : 0;
  if ((t = dict_find(iter, MESSAGE_KEY_Maneuver))) s_maneuver = t->value->int32;
  if ((t = dict_find(iter, MESSAGE_KEY_Distance))) s_distance = t->value->int32;
  if ((t = dict_find(iter, MESSAGE_KEY_Instruction))) {
    strncpy(s_instr, t->value->cstring, sizeof(s_instr) - 1);
    s_instr[sizeof(s_instr) - 1] = '\0';
  }
  if ((t = dict_find(iter, MESSAGE_KEY_RemainM))) s_remain_m = t->value->int32;
  if ((t = dict_find(iter, MESSAGE_KEY_RemainS))) s_remain_s = t->value->int32;
  s_speed_cms = (t = dict_find(iter, MESSAGE_KEY_Speed)) && t->value->int32 > 0 ? t->value->int32 : 0;
  s_age_ms = (t = dict_find(iter, MESSAGE_KEY_Age)) && t->value->int32 > 0 ? t->value->int32 : 0;
  s_rx_ms = prv_now_ms();
  s_lost = false;  // a good step ends Disconnected

  const bool first_step = !s_had_trip;
  s_had_trip = s_trip = true;
  // Two turns in a row can have the same maneuver and text ("Turn right" into
  // unnamed alleys); the step id tells them apart.
  if (s_step_id != old_step_id || s_maneuver != old_maneuver || strcmp(old_instr, s_instr) != 0) {
    // New step: buzz (not for the first one of the trip), and arm only the
    // thresholds still ahead.
    int dist;
    prv_predict(&dist, NULL, NULL);
    s_nudge_200 = dist > 200;
    s_nudge_100 = dist > 100;
    APP_LOG(APP_LOG_LEVEL_INFO, "new step %d (%d) at %d m", (int)s_step_id, s_maneuver, dist);
    if (!first_step) vibes_short_pulse();
  }
  // Close to the turn: don't wait out a 3 s poll (an older nav app sends no Poll).
  if (!dict_find(iter, MESSAGE_KEY_Poll) && prv_near() && s_poll_timer &&
      s_poll_due_ms - prv_now_ms() > POLL_NEAR_MS) {
    prv_schedule_poll(POLL_NEAR_MS);
  }
}

static void prv_inbox_received(DictionaryIterator *iter, void *context) {
  Tuple *t;
  if (s_ended) return;
  // Any message is a reply, and it came over Bluetooth.
  s_reply_ms = prv_now_ms();
  s_bt_down_ms = 0;
  if ((t = dict_find(iter, MESSAGE_KEY_Lang))) s_vi = strcmp(t->value->cstring, "vi") == 0;
  if ((t = dict_find(iter, MESSAGE_KEY_Theme))) {
    const bool light = t->value->int32 != 0;
    // Saved even when the launch guess already matched, so a fixed Light/Dark
    // setting is what the next launch starts with.
    if (!persist_exists(PERSIST_KEY_LIGHT) || persist_read_bool(PERSIST_KEY_LIGHT) != light) {
      persist_write_bool(PERSIST_KEY_LIGHT, light);
    }
    if (light != s_light) {
      s_light = light;
      window_set_background_color(s_window, prv_theme(SCR_START).bg);
    }
  }
  if ((t = dict_find(iter, MESSAGE_KEY_ThemeAuto))) {
    const bool automatic = t->value->int32 != 0;
    if (!persist_exists(PERSIST_KEY_AUTO) || persist_read_bool(PERSIST_KEY_AUTO) != automatic) {
      persist_write_bool(PERSIST_KEY_AUTO, automatic);
    }
  }
  if ((t = dict_find(iter, MESSAGE_KEY_Gps))) {
    strncpy(s_gps, t->value->cstring, sizeof(s_gps) - 1);
    s_gps[sizeof(s_gps) - 1] = '\0';
  }
  const bool no_phone = (t = dict_find(iter, MESSAGE_KEY_State)) && t->value->int32 == ST_NO_PHONE;
  if (dict_find(iter, MESSAGE_KEY_Ended)) {
    if (s_had_trip) {
      t = dict_find(iter, MESSAGE_KEY_Arrived);
      prv_show_ended(t && t->value->int32 != 0);
    } else {
      // Left over from an earlier trip; wait for a new one instead of quitting.
      s_state = ST_NO_TRIP;
    }
  } else if ((t = dict_find(iter, MESSAGE_KEY_State))) {
    s_state = t->value->int32;
    // The nav app not answering during a trip keeps the step; twice in a row is
    // Disconnected. Otherwise there is no trip (any more).
    if (s_state != ST_NO_PHONE) s_trip = false;
    else if (s_no_phone) s_lost = true;
  } else if (dict_find(iter, MESSAGE_KEY_Maneuver)) {
    prv_take_step(iter);
  }
  s_no_phone = no_phone;
  // The phone's suggested time until the next Tick; without it the Tick scheduled when
  // the last one went out stands.
  if (!s_ended && (t = dict_find(iter, MESSAGE_KEY_Poll))) {
    const int32_t ms = t->value->int32;
    prv_schedule_poll(ms < POLL_HINT_MIN_MS ? POLL_HINT_MIN_MS : ms > POLL_HINT_MAX_MS ? POLL_HINT_MAX_MS : ms);
  }
  prv_update();
}

// Bluetooth to the phone (the Pebble app): Connecting… at once when it drops.
static void prv_app_connection(bool connected) {
  APP_LOG(APP_LOG_LEVEL_INFO, "phone %s", connected ? "connected" : "disconnected");
  s_bt_down_ms = connected ? 0 : prv_now_ms();
  prv_update();
}

// Once a second: count down, switch to Connecting… or Disconnected, and redraw if anything changed.
static void prv_second(void *data) {
  s_second_timer = NULL;
  prv_update();
  if (!s_ended) s_second_timer = app_timer_register(1000, prv_second, NULL);
}

// --- Window ---

static void prv_window_load(Window *window) {
  Layer *root = window_get_root_layer(window);
  const GRect b = layer_get_bounds(root);
#ifdef PBL_ROUND
  if (b.size.w >= 260) s_layout = (Layout){ 3, 24, 45, 140, 208, 4, 16, 8, 35, 48, 56, true };  // getafix
  else s_layout = (Layout){ 9, 25, 40, 112, 112, 3, 14, 14, 40, 44, 52, false };                  // chalk
#else
  if (b.size.h < 200) s_layout = (Layout){ 3, 0, 20, 85, 140, 3, 8, 3, 20, 44, 52, false };       // asterix
  else s_layout = (Layout){ 3, 0, 24, 128, 193, 4, 8, 2, 23, 48, 57, true };                      // obelix
#endif
  const Font f14 = { fonts_get_system_font(FONT_KEY_GOTHIC_14), DY14, 14 };
  const Font f14b = { fonts_get_system_font(FONT_KEY_GOTHIC_14_BOLD), DY14, 14 };
  const Font f18 = { fonts_get_system_font(FONT_KEY_GOTHIC_18), DY18, 18 };
  const Font f18b = { fonts_get_system_font(FONT_KEY_GOTHIC_18_BOLD), DY18, 18 };
  const Font f24b = { fonts_get_system_font(FONT_KEY_GOTHIC_24_BOLD), DY24, 24 };
  if (s_layout.big) {
    const Font f42 = { fonts_get_system_font(FONT_KEY_BITHAM_42_BOLD), DY42, 42 };
    s_fonts = (Fonts){ f18b, f18, f18b, f42, f24b, f18b, f24b, f18 };
  } else {
    const Font f30 = { fonts_get_system_font(FONT_KEY_BITHAM_30_BLACK), DY30, 30 };
    s_fonts = (Fonts){ f14b, f14, f14, f30, f18b, f14b, f24b, f14 };
  }
#ifdef PBL_ROUND
  if (s_layout.big) {
    // getafix: each band line fits inside the circle, 4 px in like the band's side padding.
    s_band_flow = graphics_text_attributes_create();
    graphics_text_attributes_enable_screen_text_flow(s_band_flow, 4);
  }
#endif

  // Figma "Polygon 1" (31.2x33.8) rotated 39.6° clockwise, around its bounding box centre:
  // 33.5x35.9, 34x36 px with the outline (prv_draw_arrow).
  static GPoint arrow_points[] = { { 9, -12 }, { 1, 21 }, { -4, 5 }, { -22, 3 } };
  static const GPathInfo arrow_info = { .num_points = 4, .points = arrow_points };
  s_nav_arrow = gpath_create(&arrow_info);
  // The same polygon upright at 42.84x46.38 for the arrive icon: ARRIVE_W x ARRIVE_H px
  // with the outline.
  static GPoint arrive_points[] = { { 21, 1 }, { 41, 44 }, { 21, 32 }, { 1, 44 } };
  static const GPathInfo arrive_info = { .num_points = 4, .points = arrive_points };
  s_arrive_arrow = gpath_create(&arrive_info);

  s_layer = layer_create(b);
  layer_set_update_proc(s_layer, prv_draw);
  layer_add_child(root, s_layer);
  prv_update();
}

static void prv_window_unload(Window *window) {
  layer_destroy(s_layer);
  gpath_destroy(s_nav_arrow);
  gpath_destroy(s_arrive_arrow);
  if (s_band_flow) graphics_text_attributes_destroy(s_band_flow);
}

static void prv_init(void) {
  s_vi = strncmp(i18n_get_system_locale(), "vi", 2) == 0;
  const bool automatic = !persist_exists(PERSIST_KEY_AUTO) || persist_read_bool(PERSIST_KEY_AUTO);
  if (!automatic && persist_exists(PERSIST_KEY_LIGHT)) {
    s_light = persist_read_bool(PERSIST_KEY_LIGHT);  // fixed Light or Dark on the phone
  } else {
    const time_t now = time(NULL);
    const int hour = localtime(&now)->tm_hour;
    s_light = hour >= 6 && hour < 18;  // daytime guess until the phone answers
  }

  s_window = window_create();
  window_set_background_color(s_window, prv_theme(SCR_START).bg);
  window_set_window_handlers(s_window, (WindowHandlers) {
    .load = prv_window_load,
    .unload = prv_window_unload,
  });
  window_stack_push(s_window, true);

  app_message_register_inbox_received(prv_inbox_received);
  app_message_register_outbox_sent(prv_outbox_sent);
  app_message_register_outbox_failed(prv_outbox_failed);
  // Worst case: a step with a 90-byte Vietnamese instruction, Lang "vi" and every
  // other key as int32 (219 bytes). State/Gps and Ended messages are smaller.
  const uint32_t inbox = dict_calc_buffer_size(12, 4, 4, 4, 91, 4, 4, 4, 4, 3, 4, 4, 4);
  app_message_open(inbox, dict_calc_buffer_size(1, 1));
  connection_service_subscribe((ConnectionHandlers){ .pebble_app_connection_handler = prv_app_connection });
  s_bt_down_ms = connection_service_peek_pebble_app_connection() ? 0 : prv_now_ms();
  prv_schedule_poll(POLL_MS);
  s_second_timer = app_timer_register(1000, prv_second, NULL);
}

static void prv_deinit(void) {
  if (s_poll_timer) app_timer_cancel(s_poll_timer);
  if (s_second_timer) app_timer_cancel(s_second_timer);
  connection_service_unsubscribe();
  window_destroy(s_window);
}

int main(void) {
  prv_init();
  app_event_loop();
  prv_deinit();
}
