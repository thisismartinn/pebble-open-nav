#include <pebble.h>

// Polls the phone for the current navigation step (PROTOCOL.md). The watch drives
// the polling so that each request wakes the (possibly suspended) Pebble iOS app.
#define POLL_MS 3000
#define POLL_NEAR_MS 1000     // poll faster when the turn is close
#define POLL_NEAR_M 300
#define RETRY_MS 500          // after an outbox failure or APP_MSG_BUSY
#define PREDICT_MAX_MS 20000  // stop counting down this long after the fix...
#define PREDICT_MAX_M 250     // ...or this far from it
#define DISCONNECTED_MS 10000 // no good step for this long during a trip
#define END_SCREEN_MS 10000

enum {
  M_NONE = 0, M_STRAIGHT, M_LEFT, M_RIGHT, M_SLIGHT_LEFT, M_SLIGHT_RIGHT, M_UTURN, M_ARRIVE
};
enum { SCR_START, SCR_NAV, SCR_DISCONNECTED, SCR_END };
// State values from the JS; ST_WAITING until the JS first answers.
enum { ST_WAITING = 0, ST_NO_TRIP = 1, ST_ROUTING = 2, ST_NO_PHONE = 3 };

static Window *s_window;
static Layer *s_layer;
static GPath *s_nav_arrow;
static AppTimer *s_poll_timer, *s_second_timer;
static int64_t s_poll_due_ms;
static GFont s_font14, s_font14b, s_font18b, s_font24b, s_font30;

// The current step, as received. Distance and remaining are at the GPS fix, which
// was s_age_ms old when the JS got it; s_rx_ms is when the watch got it.
static int32_t s_step_id;       // from the nav app; a change means a new step (0: not sent)
static int s_maneuver = M_NONE;
static int s_distance, s_remain_m, s_remain_s, s_speed_cms, s_age_ms;
static int64_t s_rx_ms;
static char s_instr[96] = "";
static char s_gps[48] = "";
static int s_state = ST_WAITING;
static bool s_trip = false;      // showing a step (or Disconnected with the last one)
static bool s_had_trip = false;  // seen a real step this session, so an "ended" is ours
static bool s_ended = false, s_arrived = false;
static bool s_nudge_200, s_nudge_100;  // armed "nudge nudge" thresholds of this step

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

typedef struct {
  GColor bg, fg, band, band_text, arrow;
} Theme;

// Colours from design/WATCH_LAYOUT.md. On black and white the band is the background.
static Theme prv_theme(bool disconnected) {
#ifdef PBL_COLOR
  if (s_light) {
    return (Theme){ GColorWhite, GColorBlack, disconnected ? GColorDarkCandyAppleRed : GColorIslamicGreen,
                    GColorWhite, GColorIslamicGreen };
  }
  return (Theme){ GColorBlack, GColorWhite, GColorBlack,
                  disconnected ? GColorDarkCandyAppleRed : GColorLightGray, GColorIslamicGreen };
#else
  if (s_light) return (Theme){ GColorWhite, GColorBlack, GColorWhite, GColorBlack, GColorBlack };
  return (Theme){ GColorBlack, GColorWhite, GColorBlack, GColorWhite, GColorWhite };
#endif
}

// Screen areas (Figma: asterix for short rectangular screens, obelix for tall ones,
// getafix for round ones; chalk gets getafix scaled to 180 px).
typedef struct {
  int16_t top1_y, top2_y;  // top bar text lines; top2_y 0: one line
  int16_t mid_y, mid_h;    // distance and icon
  int16_t band_y;          // instruction band, to the bottom of the screen
  int16_t band_text_w, band_pad_bottom;
} Layout;
static Layout s_layout;

// Everything on screen. The layer is only redrawn when this changes.
typedef struct {
  uint8_t screen, maneuver;
  bool light;
  const char *title;
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

static int prv_screen(void) {
  if (s_ended) return SCR_END;
  if (!s_trip) return SCR_START;
  return prv_now_ms() - s_rx_ms >= DISCONNECTED_MS ? SCR_DISCONNECTED : SCR_NAV;
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
    if (v.screen == SCR_NAV) {
      prv_format_top(&v, remain_m, remain_ms);
      strncpy(v.band, s_instr, sizeof(v.band) - 1);
    } else {
      strncpy(v.band, TR("Disconnected", "Mất kết nối"), sizeof(v.band) - 1);
    }
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
static void prv_text(GContext *ctx, const char *text, GFont font, int dy, GRect box, GTextAlignment align) {
  box.origin.y += dy;
  graphics_draw_text(ctx, text, font, box, GTextOverflowModeTrailingEllipsis, align, NULL);
}
#define DY14 (-2)   // Gothic 14: capitals at 5..13 of the 14 px line
#define DY18 (-3)   // Gothic 18 Bold: 7..17 of 18
#define DY24 (-4)   // Gothic 24 Bold: 10..23 of 24
#define DY30 (-4)   // Bitham 30 Black: 9..29 of 30

// Turn arrows in the 44x52 icon box, 8 px strokes with round ends like the Figma
// "Vector 1 (Stroke)". Pebble only draws odd widths, so each stroke is two 7 px lines
// one pixel apart; x, y are the left/top one of the pair.
static void prv_stroke(GContext *ctx, GPoint o, int x0, int y0, int x1, int y1) {
  const bool steep = abs(y1 - y0) > abs(x1 - x0);
  for (int i = 0; i < 2; i++) {
    const int dx = steep ? i : 0, dy = steep ? 0 : i;
    graphics_draw_line(ctx, GPoint(o.x + x0 + dx, o.y + y0 + dy), GPoint(o.x + x1 + dx, o.y + y1 + dy));
  }
}

static void prv_draw_icon(GContext *ctx, GPoint o, int maneuver, GColor fg) {
  graphics_context_set_stroke_color(ctx, fg);
  graphics_context_set_fill_color(ctx, fg);
  graphics_context_set_stroke_width(ctx, 7);
#define S(a, b, c, d) prv_stroke(ctx, o, a, b, c, d)
  switch (maneuver) {
    case M_STRAIGHT:     S(21, 48, 21, 4); S(21, 4, 7, 18); S(21, 4, 35, 18); break;
    case M_LEFT:         S(39, 48, 39, 18); S(39, 18, 4, 18); S(4, 18, 18, 4); S(4, 18, 18, 32); break;
    case M_RIGHT:        S(4, 48, 4, 18); S(4, 18, 39, 18); S(39, 18, 25, 4); S(39, 18, 25, 32); break;
    case M_SLIGHT_LEFT:  S(33, 48, 33, 28); S(33, 28, 9, 4); S(9, 4, 25, 4); S(9, 4, 9, 20); break;
    case M_SLIGHT_RIGHT: S(10, 48, 10, 28); S(10, 28, 34, 4); S(34, 4, 18, 4); S(34, 4, 34, 20); break;
    case M_UTURN:        S(38, 48, 38, 4); S(38, 4, 16, 4); S(16, 4, 16, 40); S(16, 40, 5, 29); S(16, 40, 27, 29); break;
    case M_ARRIVE: {
      // Bullseye: a 46 px ring 6 px thick and a 30 px dot (Figma "Union").
      const GRect ring = GRect(o.x - 1, o.y + 3, 46, 46);
      graphics_fill_radial(ctx, ring, GOvalScaleModeFitCircle, 6, 0, TRIG_MAX_ANGLE);
      graphics_fill_radial(ctx, grect_inset(ring, GEdgeInsets(8)), GOvalScaleModeFitCircle, 15, 0, TRIG_MAX_ANGLE);
      break;
    }
    default: break;
  }
#undef S
}

// Start and end screens: navigation arrow, title and subtitle, centred with 10 px padding.
static int prv_title_h(const char *title, int w) {
  return graphics_text_layout_get_content_size(title, s_font24b, GRect(0, 0, w, 200), GTextOverflowModeWordWrap,
                                               GTextAlignmentCenter).h;
}

static void prv_draw_message(GContext *ctx, GRect b, const View *v, Theme th) {
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
  const int sub_h = graphics_text_layout_get_content_size(v->sub, s_font14, GRect(0, 0, w, 100),
                                                          GTextOverflowModeWordWrap, GTextAlignmentCenter).h + 1;
  const int arrow_h = 46;  // Figma lays out the rotated arrow in its 45.5x45.9 bounding box
  int y = (b.size.h - (arrow_h + 2 + title_h + 10 + sub_h)) / 2;
  gpath_move_to(s_nav_arrow, GPoint(b.size.w / 2, y + arrow_h / 2));
  graphics_context_set_fill_color(ctx, th.arrow);
  gpath_draw_filled(ctx, s_nav_arrow);
  y += arrow_h + 2;
  graphics_context_set_text_color(ctx, th.fg);
  prv_text(ctx, title, s_font24b, DY24, GRect(10, y, w, title_h + 8), GTextAlignmentCenter);
  y += title_h + 10;
  prv_text(ctx, v->sub, s_font14, DY14, GRect(10, y, w, sub_h + 8), GTextAlignmentCenter);
}

static void prv_draw(Layer *layer, GContext *ctx) {
  const View *v = &s_view;
  const Layout *L = &s_layout;
  const GRect b = layer_get_bounds(layer);
  const int w = b.size.w, h = b.size.h;
  const bool disconnected = v->screen == SCR_DISCONNECTED;
  const Theme th = prv_theme(disconnected);
  graphics_context_set_fill_color(ctx, th.bg);
  graphics_fill_rect(ctx, b, 0, GCornerNone);
  if (v->screen == SCR_START || v->screen == SCR_END) {
    prv_draw_message(ctx, b, v, th);
    return;
  }

  // Top bar: remaining distance left, minutes and ETA right (two centred lines on round).
  graphics_context_set_text_color(ctx, th.fg);
  if (disconnected) {
    const int y = L->top2_y ? (L->top2_y + 18) / 2 - 8 : L->top1_y;  // round: centred in the two-line bar
    prv_text(ctx, v->band, s_font14, DY14, GRect(4, y + 1, w - 8, 16), GTextAlignmentCenter);
  } else {
    const int mins_w = prv_text_w(v->mins, s_font14), eta_w = prv_text_w(v->eta, s_font14);
    int x = w - 4 - eta_w - 8 - mins_w, y = L->top1_y;
    if (L->top2_y) {
      prv_text(ctx, v->remain, s_font14b, DY14, GRect(0, y + 1, w, 16), GTextAlignmentCenter);
      x = (w - (mins_w + 8 + eta_w)) / 2;
      y = L->top2_y;
    } else {
      prv_text(ctx, v->remain, s_font14b, DY14, GRect(4, y + 1, w / 2, 16), GTextAlignmentLeft);
    }
    prv_text(ctx, v->mins, s_font14, DY14, GRect(x, y + 1, mins_w + 2, 16), GTextAlignmentLeft);
    prv_text(ctx, v->eta, s_font14, DY14, GRect(x + mins_w + 8, y + 1, eta_w + 2, 16), GTextAlignmentLeft);
  }

  // Middle: the distance block (64x55, right-aligned), a 20 px gap and the icon (44x52),
  // centred as a group. Figma: the number's line box starts 2.5 px into the block, the
  // unit's 30 px line is centred on a 20 px box 32.5 px into it.
  const int icon_y = L->mid_y + (L->mid_h - 52) / 2;
#ifdef PBL_ROUND
  // Round screens are wide enough for the distance on one line ("800m", "1.2km"); the
  // group (text, 20 px gap, icon) stays centred. Chalk falls back to two lines if needed.
  char one[16];
  snprintf(one, sizeof(one), "%s%s", v->num, v->unit);
  const int one_w = prv_text_w(one, s_font30);
  if (one_w + 20 + 44 <= w - 40) {
    const int x = (w - (one_w + 20 + 44)) / 2;
    prv_text(ctx, one, s_font30, DY30, GRect(x, L->mid_y + (L->mid_h - 30) / 2, one_w + 4, 34),
             GTextAlignmentLeft);
    prv_draw_icon(ctx, GPoint(x + one_w + 20, icon_y), v->maneuver, th.fg);
  } else
#endif
  {
    const int gx = (w - 128) / 2;
    const int y2 = 2 * L->mid_y + L->mid_h - 55;  // block top, in half pixels
    prv_text(ctx, v->num, s_font30, DY30, GRect(gx - 20, (y2 + 5) / 2, 84, 34), GTextAlignmentRight);
    prv_text(ctx, v->unit, s_font30, DY30, GRect(gx - 20, (y2 + 55) / 2, 84, 34), GTextAlignmentRight);
    prv_draw_icon(ctx, GPoint(gx + 84, icon_y), v->maneuver, th.fg);
  }

  // Band: the instruction centred, at most band_text_w wide (padding 3 top, 8 bottom).
  if (!gcolor_equal(th.band, th.bg)) {
    graphics_context_set_fill_color(ctx, th.band);
    graphics_fill_rect(ctx, GRect(0, L->band_y, w, h - L->band_y), 0, GCornerNone);
  }
  const GRect area = GRect((w - L->band_text_w) / 2, L->band_y + 3, L->band_text_w,
                           h - L->band_y - 3 - L->band_pad_bottom);
  // A long Vietnamese instruction may not fit at 18 px on a small screen; use 14 px then.
  GFont font = s_font18b;
  int dy = DY18;
  int text_h = graphics_text_layout_get_content_size(v->band, font, GRect(0, 0, area.size.w, 400),
                                                     GTextOverflowModeWordWrap, GTextAlignmentCenter).h;
  if (text_h > area.size.h) {
    font = s_font14b;
    dy = DY14;
    text_h = graphics_text_layout_get_content_size(v->band, font, GRect(0, 0, area.size.w, 400),
                                                   GTextOverflowModeWordWrap, GTextAlignmentCenter).h;
    if (text_h > area.size.h) text_h = area.size.h;
  }
  graphics_context_set_text_color(ctx, th.band_text);
  // The box is a little taller than the lines: Pebble only draws a line whose glyphs fit.
  prv_text(ctx, v->band, font, dy,
           GRect(area.origin.x, area.origin.y + (area.size.h - text_h) / 2, area.size.w, text_h + 8),
           GTextAlignmentCenter);
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
  // Close to the turn: don't wait out a 3 s poll.
  if (prv_near() && s_poll_timer && s_poll_due_ms - prv_now_ms() > POLL_NEAR_MS) prv_schedule_poll(POLL_NEAR_MS);
}

static void prv_inbox_received(DictionaryIterator *iter, void *context) {
  Tuple *t;
  if (s_ended) return;
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
      window_set_background_color(s_window, prv_theme(false).bg);
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
    // The nav app not answering during a trip keeps the step; Disconnected follows
    // after DISCONNECTED_MS. Otherwise there is no trip (any more).
    if (s_state != ST_NO_PHONE) s_trip = false;
  } else if (dict_find(iter, MESSAGE_KEY_Maneuver)) {
    prv_take_step(iter);
  }
  prv_update();
}

// Once a second: count down, switch to Disconnected, and redraw if anything changed.
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
  // getafix; the band text sits higher than Figma's centre (bottom padding 40, not 8)
  // because the circle narrows towards the bottom (designer's request).
  if (b.size.w >= 260) s_layout = (Layout){ 2, 22, 40, 90, 130, 140, 40 };
  else s_layout = (Layout){ 8, 24, 40, 72, 112, 112, 14 };                 // chalk: getafix scaled
#else
  if (b.size.h < 200) s_layout = (Layout){ 2, 0, 20, 65, 85, 140, 8 };  // asterix
  else s_layout = (Layout){ 2, 0, 20, 108, 128, 140, 8 };                // obelix
#endif
  s_font14 = fonts_get_system_font(FONT_KEY_GOTHIC_14);
  s_font14b = fonts_get_system_font(FONT_KEY_GOTHIC_14_BOLD);
  s_font18b = fonts_get_system_font(FONT_KEY_GOTHIC_18_BOLD);
  s_font24b = fonts_get_system_font(FONT_KEY_GOTHIC_24_BOLD);
  s_font30 = fonts_get_system_font(FONT_KEY_BITHAM_30_BLACK);

  // Figma "Polygon 1" (31.2x33.8) rotated 39.6° clockwise, around its bounding box centre.
  static GPoint arrow_points[] = { { 11, -13 }, { 1, 23 }, { -5, 6 }, { -23, 3 } };
  static const GPathInfo arrow_info = { .num_points = 4, .points = arrow_points };
  s_nav_arrow = gpath_create(&arrow_info);

  s_layer = layer_create(b);
  layer_set_update_proc(s_layer, prv_draw);
  layer_add_child(root, s_layer);
  prv_update();
}

static void prv_window_unload(Window *window) {
  layer_destroy(s_layer);
  gpath_destroy(s_nav_arrow);
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
  window_set_background_color(s_window, prv_theme(false).bg);
  window_set_window_handlers(s_window, (WindowHandlers) {
    .load = prv_window_load,
    .unload = prv_window_unload,
  });
  window_stack_push(s_window, true);

  app_message_register_inbox_received(prv_inbox_received);
  app_message_register_outbox_sent(prv_outbox_sent);
  app_message_register_outbox_failed(prv_outbox_failed);
  // Worst case: a step with a 90-byte Vietnamese instruction, Lang "vi" and every
  // other key as int32 (208 bytes). State/Gps and Ended messages are smaller.
  const uint32_t inbox = dict_calc_buffer_size(11, 4, 4, 4, 91, 4, 4, 4, 4, 3, 4, 4);
  app_message_open(inbox, dict_calc_buffer_size(1, 1));
  prv_schedule_poll(POLL_MS);
  s_second_timer = app_timer_register(1000, prv_second, NULL);
}

static void prv_deinit(void) {
  if (s_poll_timer) app_timer_cancel(s_poll_timer);
  if (s_second_timer) app_timer_cancel(s_second_timer);
  window_destroy(s_window);
}

int main(void) {
  prv_init();
  app_event_loop();
  prv_deinit();
}
