#include <pebble.h>

// Polls the phone for the current navigation step. The watch drives the
// polling so that each request wakes the (possibly suspended) Pebble iOS app.
#define POLL_MS 3000
#define NEAR_TURN_M 50
#define STALE_S 10  // warn when the phone hasn't answered for this long
#define QUIT_AFTER_END_MS 4000

enum {
  M_NONE = 0, M_STRAIGHT, M_LEFT, M_RIGHT, M_SLIGHT_LEFT, M_SLIGHT_RIGHT, M_UTURN, M_ARRIVE, M_ENDED
};

static Window *s_window;
static Layer *s_arrow_layer;
static TextLayer *s_top_layer, *s_dist_layer, *s_instr_layer, *s_eta_layer;
static AppTimer *s_poll_timer;
static int s_arrow_size = 60;  // arrow box in px; smaller on short screens

static int s_maneuver = M_NONE;
static int s_distance = -1;
static char s_remaining[24] = "";
static char s_top[48] = "";
static char s_dist[16] = "";
static char s_instr[96] = "";
static char s_eta[48] = "";
static bool s_warned_near = false;
static time_t s_last_reply = 0;
static bool s_had_trip = false;  // seen a real step this session, so an "ended" is ours
static bool s_ended = false;

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
  GColor bg, fg, top, instr, eta;
} Theme;

static Theme prv_theme(void) {
#ifdef PBL_COLOR
  if (s_light) {
    return (Theme){ GColorWhite, GColorBlack, GColorWindsorTan, GColorBlack, GColorCobaltBlue };
  }
  return (Theme){ GColorBlack, GColorWhite, GColorChromeYellow, GColorChromeYellow, GColorPictonBlue };
#else
  if (s_light) return (Theme){ GColorWhite, GColorBlack, GColorBlack, GColorBlack, GColorBlack };
  return (Theme){ GColorBlack, GColorWhite, GColorWhite, GColorWhite, GColorWhite };
#endif
}

static void prv_line(GContext *ctx, int x0, int y0, int x1, int y1) {
  graphics_draw_line(ctx, GPoint(x0, y0), GPoint(x1, y1));
}

// Arrow head at (x, y); arrows are designed in a 60x60 box and scaled to s_arrow_size.
static void prv_head(GContext *ctx, int x, int y, int dx, int dy) {
  // dx,dy: unit direction of travel (-1, 0, 1)
  const int s = 12 * s_arrow_size / 60;
  if (dx == 0) {
    prv_line(ctx, x, y, x - s, y - dy * s);
    prv_line(ctx, x, y, x + s, y - dy * s);
  } else if (dy == 0) {
    prv_line(ctx, x, y, x - dx * s, y - s);
    prv_line(ctx, x, y, x - dx * s, y + s);
  } else {
    prv_line(ctx, x, y, x - dx * s, y);
    prv_line(ctx, x, y, x, y - dy * s);
  }
}

static void prv_arrow_update(Layer *layer, GContext *ctx) {
  GRect b = layer_get_bounds(layer);
  const int sz = s_arrow_size;
  int ox = (b.size.w - sz) / 2, oy = (b.size.h - sz) / 2;
  const GColor fg = prv_theme().fg;
  graphics_context_set_stroke_color(ctx, fg);
  graphics_context_set_fill_color(ctx, fg);
  graphics_context_set_stroke_width(ctx, sz >= 60 ? 7 : 5);
#define P(v) ((v) * sz / 60)
#define L(a, b, c, d) prv_line(ctx, ox + P(a), oy + P(b), ox + P(c), oy + P(d))
#define H(a, b, dx, dy) prv_head(ctx, ox + P(a), oy + P(b), dx, dy)
  switch (s_maneuver) {
    case M_STRAIGHT:     L(30, 56, 30, 6); H(30, 6, 0, -1); break;
    case M_RIGHT:        L(18, 56, 18, 26); L(18, 26, 54, 26); H(54, 26, 1, 0); break;
    case M_LEFT:         L(42, 56, 42, 26); L(42, 26, 6, 26); H(6, 26, -1, 0); break;
    case M_SLIGHT_RIGHT: L(24, 56, 24, 32); L(24, 32, 50, 8); H(50, 8, 1, -1); break;
    case M_SLIGHT_LEFT:  L(36, 56, 36, 32); L(36, 32, 10, 8); H(10, 8, -1, -1); break;
    case M_UTURN:        L(44, 56, 44, 12); L(44, 12, 16, 12); L(16, 12, 16, 44); H(16, 44, 0, 1); break;
    case M_ARRIVE:       graphics_fill_circle(ctx, GPoint(ox + P(30), oy + P(30)), P(18)); break;
    case M_ENDED:        L(8, 32, 24, 48); L(24, 48, 54, 12); break;  // check mark
    default: break;
  }
#undef P
#undef L
#undef H
}

static void prv_format_distance(int m) {
  if (m < 0) s_dist[0] = '\0';
  else if (m < 1000) snprintf(s_dist, sizeof(s_dist), "%d m", (m < 100) ? (m / 5) * 5 : (m / 10) * 10);
  else snprintf(s_dist, sizeof(s_dist), TR("%d.%d km", "%d,%d km"), m / 1000, (m % 1000) / 100);
}

static void prv_refresh(void) {
  text_layer_set_text(s_top_layer, s_top);
  text_layer_set_text(s_dist_layer, s_dist);
  text_layer_set_text(s_instr_layer, s_instr);
  text_layer_set_text(s_eta_layer, s_eta);
  layer_mark_dirty(s_arrow_layer);
}

static void prv_apply_theme(void) {
  const Theme t = prv_theme();
  window_set_background_color(s_window, t.bg);
  text_layer_set_text_color(s_top_layer, t.top);
  text_layer_set_text_color(s_dist_layer, t.fg);
  text_layer_set_text_color(s_instr_layer, s_ended ? t.fg : t.instr);
  text_layer_set_text_color(s_eta_layer, t.eta);
  layer_mark_dirty(s_arrow_layer);
}

static void prv_send_tick(void *data);

static void prv_schedule_poll(void) {
  if (s_poll_timer) app_timer_cancel(s_poll_timer);
  s_poll_timer = app_timer_register(POLL_MS, prv_send_tick, NULL);
}

static void prv_send_tick(void *data) {
  s_poll_timer = NULL;
  if (s_ended) return;
  if (s_last_reply) {
    int silent = (int)(time(NULL) - s_last_reply);
    if (silent >= STALE_S) {
      snprintf(s_top, sizeof(s_top), TR("No reply for %d s", "Không phản hồi %d giây"), silent);
      prv_refresh();
    }
  }
  DictionaryIterator *out;
  if (app_message_outbox_begin(&out) == APP_MSG_OK) {
    dict_write_uint8(out, MESSAGE_KEY_Tick, 1);
    app_message_outbox_send();
  }
  prv_schedule_poll();
}

static void prv_quit(void *data) {
  window_stack_pop_all(true);  // empty window stack: the app exits
}

static void prv_show_ended(const char *reason) {
  s_ended = true;
  if (s_poll_timer) {
    app_timer_cancel(s_poll_timer);
    s_poll_timer = NULL;
  }
  s_maneuver = M_ENDED;
  s_top[0] = '\0';
  s_dist[0] = '\0';
  strncpy(s_instr, TR("Navigation Ended", "Đã kết thúc chỉ đường"), sizeof(s_instr) - 1);
  strncpy(s_eta, reason, sizeof(s_eta) - 1);
  text_layer_set_font(s_instr_layer, fonts_get_system_font(FONT_KEY_GOTHIC_24_BOLD));
  text_layer_set_text_color(s_instr_layer, prv_theme().fg);
  prv_refresh();
  // One light tap: the end screen says it all, and the system long pulse (500 ms) is too strong.
  static const uint32_t ended_vibe[] = { 120 };
  vibes_enqueue_custom_pattern((VibePattern){ .durations = ended_vibe, .num_segments = ARRAY_LENGTH(ended_vibe) });
  app_timer_register(QUIT_AFTER_END_MS, prv_quit, NULL);
}

static void prv_inbox_received(DictionaryIterator *iter, void *context) {
  Tuple *t;
  if (s_ended) return;
  s_last_reply = time(NULL);
  if ((t = dict_find(iter, MESSAGE_KEY_Lang))) s_vi = strcmp(t->value->cstring, "vi") == 0;
  if ((t = dict_find(iter, MESSAGE_KEY_Theme))) {
    const bool light = t->value->int32 != 0;
    if (light != s_light) {
      s_light = light;
      persist_write_bool(PERSIST_KEY_LIGHT, light);
      prv_apply_theme();
    }
  }
  if ((t = dict_find(iter, MESSAGE_KEY_ThemeAuto))) {
    const bool automatic = t->value->int32 != 0;
    if (!persist_exists(PERSIST_KEY_AUTO) || persist_read_bool(PERSIST_KEY_AUTO) != automatic) {
      persist_write_bool(PERSIST_KEY_AUTO, automatic);
    }
  }
  if (dict_find(iter, MESSAGE_KEY_Ended)) {
    if (s_had_trip) {
      t = dict_find(iter, MESSAGE_KEY_Instruction);
      prv_show_ended(t ? t->value->cstring : "");
    } else {
      // Left over from an earlier trip; wait for a new one instead of quitting.
      strncpy(s_top, TR("No trip started", "Chưa bắt đầu chuyến đi"), sizeof(s_top) - 1);
      prv_refresh();
    }
    return;
  }
  if ((t = dict_find(iter, MESSAGE_KEY_Status))) {
    // Error from the phone side: keep the last step, show the problem on top.
    strncpy(s_top, t->value->cstring, sizeof(s_top) - 1);
    prv_refresh();
    return;
  }
  char old_instr[sizeof(s_instr)];
  strncpy(old_instr, s_instr, sizeof(old_instr));
  int old_maneuver = s_maneuver;

  if ((t = dict_find(iter, MESSAGE_KEY_Maneuver))) s_maneuver = t->value->int32;
  if ((t = dict_find(iter, MESSAGE_KEY_Distance))) s_distance = t->value->int32;
  if ((t = dict_find(iter, MESSAGE_KEY_Instruction))) strncpy(s_instr, t->value->cstring, sizeof(s_instr) - 1);
  if ((t = dict_find(iter, MESSAGE_KEY_Remaining))) strncpy(s_remaining, t->value->cstring, sizeof(s_remaining) - 1);
  if ((t = dict_find(iter, MESSAGE_KEY_Eta))) strncpy(s_eta, t->value->cstring, sizeof(s_eta) - 1);

  const bool first_step = !s_had_trip;
  if (s_maneuver != M_NONE) s_had_trip = true;
  strncpy(s_top, s_remaining, sizeof(s_top) - 1);
  prv_format_distance(s_distance);

  // Buzz once on a new step (not the first one of the trip), twice when the turn is close.
  if (s_maneuver != old_maneuver || strcmp(old_instr, s_instr) != 0) {
    s_warned_near = false;
    if (!first_step && s_maneuver != M_NONE) vibes_short_pulse();
  } else if (!s_warned_near && s_distance >= 0 && s_distance <= NEAR_TURN_M) {
    s_warned_near = true;
    vibes_double_pulse();
  }
  prv_refresh();
}

static void prv_outbox_failed(DictionaryIterator *iter, AppMessageResult reason, void *context) {
  if (s_ended) return;
  snprintf(s_top, sizeof(s_top), TR("No phone (%d)", "Mất kết nối điện thoại (%d)"), (int)reason);
  prv_refresh();
}

static TextLayer *prv_text(Layer *root, GRect frame, const char *font, GColor color) {
  TextLayer *tl = text_layer_create(frame);
  text_layer_set_background_color(tl, GColorClear);
  text_layer_set_text_color(tl, color);
  text_layer_set_font(tl, fonts_get_system_font(font));
  text_layer_set_text_alignment(tl, GTextAlignmentCenter);
  text_layer_set_overflow_mode(tl, GTextOverflowModeWordWrap);
  layer_add_child(root, text_layer_get_layer(tl));
  return tl;
}

static void prv_window_load(Window *window) {
  Layer *root = window_get_root_layer(window);
  GRect b = layer_get_bounds(root);
  int w = b.size.w, h = b.size.h;
  int inset = PBL_IF_ROUND_ELSE(w / 10, 4);
  int cw = w - 2 * inset;

  // Short screens (Pebble 2 / 2 Duo, 168 px) get a tighter stack and a smaller arrow.
  const bool small = h < 200;
  s_arrow_size = small ? 44 : 60;
  const int y_top = small ? 0 : h * 6 / 100;
  const int y_arrow = small ? 22 : h * 17 / 100;
  const int y_dist = small ? 66 : h * 44 / 100;
  const int y_instr = small ? 98 : h * 62 / 100;
  const int y_eta = small ? 144 : h * 84 / 100;

  const Theme theme = prv_theme();
  s_top_layer = prv_text(root, GRect(inset, y_top, cw, 24), FONT_KEY_GOTHIC_18_BOLD, theme.top);
  s_arrow_layer = layer_create(GRect(0, y_arrow, w, s_arrow_size + 2));
  layer_set_update_proc(s_arrow_layer, prv_arrow_update);
  layer_add_child(root, s_arrow_layer);
  s_dist_layer = prv_text(root, GRect(inset, y_dist, cw, 36),
                          small ? FONT_KEY_GOTHIC_28_BOLD : FONT_KEY_BITHAM_30_BLACK, theme.fg);
  s_instr_layer = prv_text(root, GRect(inset, y_instr, cw, 46), FONT_KEY_GOTHIC_18_BOLD, theme.instr);
  s_eta_layer = prv_text(root, GRect(inset, y_eta, cw, 22), FONT_KEY_GOTHIC_18, theme.eta);
  prv_refresh();
}

static void prv_window_unload(Window *window) {
  layer_destroy(s_arrow_layer);
  text_layer_destroy(s_top_layer);
  text_layer_destroy(s_dist_layer);
  text_layer_destroy(s_instr_layer);
  text_layer_destroy(s_eta_layer);
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
  strncpy(s_top, TR("Waiting for phone…", "Đang chờ điện thoại…"), sizeof(s_top) - 1);

  s_window = window_create();
  window_set_background_color(s_window, prv_theme().bg);
  window_set_window_handlers(s_window, (WindowHandlers) {
    .load = prv_window_load,
    .unload = prv_window_unload,
  });
  window_stack_push(s_window, true);

  app_message_register_inbox_received(prv_inbox_received);
  app_message_register_outbox_failed(prv_outbox_failed);
  app_message_open(384, 64);  // a full Vietnamese step with lang/theme is ~210 bytes
  s_last_reply = time(NULL);  // so "No reply" also shows if the phone never answers
  prv_schedule_poll();
}

static void prv_deinit(void) {
  if (s_poll_timer) app_timer_cancel(s_poll_timer);
  window_destroy(s_window);
}

int main(void) {
  prv_init();
  app_event_loop();
  prv_deinit();
}
