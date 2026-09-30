// Runs inside the Pebble phone app. Each Tick from the watch fetches the
// current step from the navigation app's local server on this phone (PROTOCOL.md).
var STEP_URL = 'http://127.0.0.1:8765/step';
var REQUEST_TIMEOUT_MS = 2500;
var GPS_PROBE_MS = 15000;  // start-screen GPS line: at most this often
var INSTRUCTION_MAX_BYTES = 90;  // the watch's inbox is sized for this

// State values for the watch (PROTOCOL.md §2).
var STATE_NO_TRIP = 1;
var STATE_ROUTING = 2;
var STATE_NO_PHONE = 3;

// Language of the watch texts. The nav app sends the phone's language ("lang")
// with every reply; that wins. navigator.language can't be used: the Pebble iOS
// app is English-only, so on a Vietnamese phone it reports "en_VN". Until the
// nav app answers, use the watch's own language (set by its language pack).
var navLang = null;
// Watch theme from the nav app: 1 light, 0 dark (null until it answers).
var navTheme = null;
var navThemeAuto = null;  // 1 when the phone's Watch Display setting is Automatic

function fallbackLang() {
  var code = '';
  try {
    var info = Pebble.getActiveWatchInfo && Pebble.getActiveWatchInfo();
    code = (info && info.language) || '';
  } catch (e) {}
  return String(code).toLowerCase().indexOf('vi') === 0 ? 'vi' : 'en';
}

function lang() {
  return navLang || fallbackLang();
}
var STRINGS = {
  gpsOld: ['GPS {s}s old', 'GPS cũ {s}s'],
  gpsIn: ['GPS in {s}s', 'GPS sau {s}s'],
  gpsNone: ['GPS no answer', 'GPS không phản hồi'],
  gpsError: ['GPS error ', 'Lỗi GPS ']
};

function T(key, values) {
  var text = STRINGS[key][lang() === 'vi' ? 1 : 0];
  for (var k in values || {}) text = text.replace('{' + k + '}', values[k]);
  return text;
}

// Once the nav app has told us the phone's language, every message carries it so
// the watch's own texts match. Before that the watch keeps its own language.
function send(dict) {
  if (navLang) dict.Lang = navLang;
  if (navTheme !== null) dict.Theme = navTheme;
  if (navThemeAuto !== null) dict.ThemeAuto = navThemeAuto;
  Pebble.sendAppMessage(dict);
}

// Set once a real step arrived this trip. A failed fetch after that keeps the
// step on the watch (it shows Disconnected after a while) and skips the GPS probe.
var hadStep = false;

// The start screen shows how the Pebble app's own GPS behaves: whether it answers
// and how fresh the fix is. Only while there is no trip; the nav app does its own GPS.
var gpsLine = '';
var gpsProbeAt = 0;
var gpsProbeOff = null;  // true in the emulator, see inEmulator()

// The emulator's JS runtime (pypkjs) hangs for good on a location request, like it
// does on a refused connection; the real Pebble iOS app answers.
function inEmulator() {
  try {
    var info = Pebble.getActiveWatchInfo && Pebble.getActiveWatchInfo();
    return /^qemu/.test((info && info.model) || '');
  } catch (e) {
    return false;
  }
}

function probeGps() {
  if (gpsProbeOff === null) gpsProbeOff = inEmulator();
  var askedAt = Date.now();
  if (gpsProbeOff || (gpsProbeAt && askedAt - gpsProbeAt < GPS_PROBE_MS)) return;
  gpsProbeAt = askedAt;
  var reported = false;
  function reportOnce(text) {
    if (reported) return;
    reported = true;
    gpsLine = text;
  }
  // Some runtimes never call back when location is unavailable.
  setTimeout(function () { reportOnce(T('gpsNone')); }, REQUEST_TIMEOUT_MS + 500);
  navigator.geolocation.getCurrentPosition(
    function (pos) {
      // The Pebble iOS app gives no timestamp; then report how long the answer took.
      var gps = typeof pos.timestamp === 'number'
        ? T('gpsOld', { s: Math.max(0, Math.round((Date.now() - pos.timestamp) / 1000)) })
        : T('gpsIn', { s: ((Date.now() - askedAt) / 1000).toFixed(1) });
      reportOnce(gps + ', ±' + Math.round(pos.coords.accuracy) + 'm');
    },
    function (err) {
      reportOnce(T('gpsError') + err.code);
    },
    { enableHighAccuracy: true, maximumAge: 0, timeout: REQUEST_TIMEOUT_MS }
  );
}

function sendState(state) {
  if (!hadStep) probeGps();
  var dict = { State: state };
  if (gpsLine) dict.Gps = gpsLine;
  send(dict);
}

// The nav app already cuts the instruction to 90 UTF-8 bytes on a character
// boundary; cut again so a longer one can't overflow the watch's inbox.
function clipUtf8(text, maxBytes) {
  var bytes = 0;
  for (var i = 0; i < text.length; i++) {
    var c = text.charCodeAt(i);
    var n = c < 0x80 ? 1 : c < 0x800 ? 2 : (c >= 0xd800 && c < 0xdc00) ? 4 : 3;
    if (bytes + n > maxBytes) return text.substring(0, i);
    bytes += n;
    if (n === 4) i++;  // the low surrogate
  }
  return text;
}

// The Pebble iOS runtime keeps every XMLHttpRequest in a static map and never
// removes it; drop ours when done so a long trip doesn't slowly fill memory.
function release(xhr) {
  xhr.onload = xhr.onerror = xhr.ontimeout = null;
  try {
    if (XMLHttpRequest._instances) XMLHttpRequest._instances.delete(xhr._instanceID);
  } catch (e) {}
}

function handleStep(s, receivedAt) {
  if (s.lang === 'vi' || s.lang === 'en') navLang = s.lang;
  if (s.theme === 'light' || s.theme === 'dark') navTheme = s.theme === 'light' ? 1 : 0;
  if (typeof s.themeAuto === 'boolean') navThemeAuto = s.themeAuto ? 1 : 0;
  if (s.ended) {
    hadStep = false;
    // The nav app keeps answering "ended" until the next trip, so a watchapp opened
    // now shows its start screen: give it the GPS line too.
    probeGps();
    var ended = { Ended: 1, Arrived: s.arrived ? 1 : 0 };
    if (gpsLine) ended.Gps = gpsLine;
    send(ended);
  } else if (s.routing) {
    hadStep = false;
    sendState(STATE_ROUTING);
  } else if (!s.active) {
    hadStep = false;
    sendState(STATE_NO_TRIP);
  } else {
    hadStep = true;
    var fixTime = Number(s.fixTime);
    send({
      StepId: s.stepId | 0,
      Maneuver: s.maneuver | 0,
      Distance: Math.round(s.distance),
      Instruction: clipUtf8(String(s.instruction || ''), INSTRUCTION_MAX_BYTES),
      RemainM: Math.round(s.remainM),
      RemainS: Math.round(s.remainS),
      Speed: Math.max(0, Math.round((Number(s.speed) || 0) * 100)),
      // How old the fix was when we got it; the watch adds its own time since receipt.
      Age: fixTime > 0 ? Math.min(Math.max(0, receivedAt - fixTime), 3600000) : 0
    });
  }
}

function fetchStep() {
  var xhr = new XMLHttpRequest();
  var finished = false;
  function fail() {
    if (finished) return;
    finished = true;
    sendState(STATE_NO_PHONE);
  }
  // Our own timeout as well as xhr.timeout: not every JS runtime reports a refused connection.
  var watchdog = setTimeout(function () {
    try { xhr.abort(); } catch (e) {}
    fail();
    setTimeout(function () { release(xhr); }, 1000);  // let a late response find its instance
  }, REQUEST_TIMEOUT_MS);

  xhr.open('GET', STEP_URL + '?t=' + Date.now(), true);
  xhr.timeout = REQUEST_TIMEOUT_MS;
  xhr.onload = function () {
    if (finished) return;
    finished = true;
    var receivedAt = Date.now();
    clearTimeout(watchdog);
    release(xhr);
    var step = null;
    if (xhr.status === 200) {
      try {
        step = JSON.parse(xhr.responseText);
      } catch (e) {}
    }
    if (step) {
      handleStep(step, receivedAt);
    } else {
      sendState(STATE_NO_PHONE);  // error status or bad data: the nav app isn't answering properly
    }
  };
  xhr.onerror = xhr.ontimeout = function () {
    clearTimeout(watchdog);
    release(xhr);
    fail();
  };
  xhr.send();
}

Pebble.addEventListener('ready', fetchStep);
Pebble.addEventListener('appmessage', function (e) {
  if (e.payload.Tick) fetchStep();
});
