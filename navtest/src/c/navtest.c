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
static char s_top[48] = "Waiting for phone…";
static char s_dist[16] = "";
static char s_instr[96] = "";
static char s_eta[48] = "";
static bool s_warned_near = false;
static time_t s_last_reply = 0;
static bool s_had_trip = false;  // seen a real step this session, so an "ended" is ours
static bool s_ended = false;

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
  graphics_context_set_stroke_color(ctx, GColorWhite);
  graphics_context_set_fill_color(ctx, GColorWhite);
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
  else snprintf(s_dist, sizeof(s_dist), "%d.%d km", m / 1000, (m % 1000) / 100);
}

static void prv_refresh(void) {
  text_layer_set_text(s_top_layer, s_top);
  text_layer_set_text(s_dist_layer, s_dist);
  text_layer_set_text(s_instr_layer, s_instr);
  text_layer_set_text(s_eta_layer, s_eta);
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
      snprintf(s_top, sizeof(s_top), "No reply for %d s", silent);
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
  strncpy(s_instr, "Navigation Ended", sizeof(s_instr) - 1);
  strncpy(s_eta, reason, sizeof(s_eta) - 1);
  text_layer_set_font(s_instr_layer, fonts_get_system_font(FONT_KEY_GOTHIC_24_BOLD));
  text_layer_set_text_color(s_instr_layer, GColorWhite);
  prv_refresh();
  vibes_long_pulse();
  app_timer_register(QUIT_AFTER_END_MS, prv_quit, NULL);
}

static void prv_inbox_received(DictionaryIterator *iter, void *context) {
  Tuple *t;
  if (s_ended) return;
  s_last_reply = time(NULL);
  if (dict_find(iter, MESSAGE_KEY_Ended)) {
    if (s_had_trip) {
      t = dict_find(iter, MESSAGE_KEY_Instruction);
      prv_show_ended(t ? t->value->cstring : "");
    } else {
      // Left over from an earlier trip; wait for a new one instead of quitting.
      strncpy(s_top, "No trip started", sizeof(s_top) - 1);
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

  if (s_maneuver != M_NONE) s_had_trip = true;
  strncpy(s_top, s_remaining, sizeof(s_top) - 1);
  prv_format_distance(s_distance);

  // Buzz once on a new step, twice when the turn is close.
  if (s_maneuver != old_maneuver || strcmp(old_instr, s_instr) != 0) {
    s_warned_near = false;
    if (old_maneuver != M_NONE) vibes_short_pulse();
  } else if (!s_warned_near && s_distance >= 0 && s_distance <= NEAR_TURN_M) {
    s_warned_near = true;
    vibes_double_pulse();
  }
  prv_refresh();
}

static void prv_outbox_failed(DictionaryIterator *iter, AppMessageResult reason, void *context) {
  if (s_ended) return;
  snprintf(s_top, sizeof(s_top), "No phone (%d)", (int)reason);
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

  s_top_layer = prv_text(root, GRect(inset, y_top, cw, 24), FONT_KEY_GOTHIC_18_BOLD,
                         PBL_IF_COLOR_ELSE(GColorChromeYellow, GColorWhite));
  s_arrow_layer = layer_create(GRect(0, y_arrow, w, s_arrow_size + 2));
  layer_set_update_proc(s_arrow_layer, prv_arrow_update);
  layer_add_child(root, s_arrow_layer);
  s_dist_layer = prv_text(root, GRect(inset, y_dist, cw, 36),
                          small ? FONT_KEY_GOTHIC_28_BOLD : FONT_KEY_BITHAM_30_BLACK, GColorWhite);
  s_instr_layer = prv_text(root, GRect(inset, y_instr, cw, 46), FONT_KEY_GOTHIC_18_BOLD,
                           PBL_IF_COLOR_ELSE(GColorChromeYellow, GColorWhite));
  s_eta_layer = prv_text(root, GRect(inset, y_eta, cw, 22), FONT_KEY_GOTHIC_18,
                         PBL_IF_COLOR_ELSE(GColorPictonBlue, GColorWhite));
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
  s_window = window_create();
  window_set_background_color(s_window, GColorBlack);
  window_set_window_handlers(s_window, (WindowHandlers) {
    .load = prv_window_load,
    .unload = prv_window_unload,
  });
  window_stack_push(s_window, true);

  app_message_register_inbox_received(prv_inbox_received);
  app_message_register_outbox_failed(prv_outbox_failed);
  app_message_open(256, 64);
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
