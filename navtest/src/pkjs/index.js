// Runs inside the Pebble phone app. Each Tick from the watch fetches the
// current step from the navigation app's local server on this phone.
var STEP_URL = 'http://127.0.0.1:8765/step';
var REQUEST_TIMEOUT_MS = 2500;

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
  navAppError: ['Nav app error ', 'Lỗi ứng dụng '],
  badData: ['Bad data from nav app', 'Dữ liệu không hợp lệ'],
  routing: ['Routing...', 'Đang tìm đường...'],
  noTrip: ['No trip started', 'Chưa bắt đầu chuyến đi'],
  notAnswering: ['Disconnected', 'Mất kết nối'],
  probe: ['Probe mode', 'Chế độ kiểm tra'],
  tick: ['Tick {n}, max gap {g} s', 'Lượt {n}, gián đoạn tối đa {g} giây'],
  gpsOld: ['GPS {s} s old', 'GPS cũ {s} giây'],
  gpsIn: ['GPS in {s} s', 'GPS sau {s} giây'],
  gpsNone: ['GPS no answer', 'GPS không phản hồi'],
  gpsError: ['GPS error ', 'Lỗi GPS '],
  phone: ['Phone ', 'Điện thoại ']
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

// Probe mode (no nav app running): measures how the Pebble app behaves in the
// background, i.e. whether every watch tick still gets answered and GPS stays fresh.
var probe = { ticks: 0, lastTickAt: 0, maxGapSec: 0 };

// Set once a real step arrived this trip. A failed fetch after that keeps the
// step on the watch and only flags the problem, instead of switching to probe mode.
var hadStep = false;

function sendStatus(text) {
  send({ Status: text });
}

// The Pebble iOS runtime keeps every XMLHttpRequest in a static map and never
// removes it; drop ours when done so a long trip doesn't slowly fill memory.
function release(xhr) {
  xhr.onload = xhr.onerror = xhr.ontimeout = null;
  try {
    if (XMLHttpRequest._instances) XMLHttpRequest._instances.delete(xhr._instanceID);
  } catch (e) {}
}

function two(n) {
  return (n < 10 ? '0' : '') + n;
}

function sendProbe() {
  var now = Date.now();
  probe.ticks++;
  if (probe.lastTickAt) {
    probe.maxGapSec = Math.max(probe.maxGapSec, Math.round((now - probe.lastTickAt) / 1000));
  }
  probe.lastTickAt = now;

  function report(gpsText) {
    var d = new Date();
    send({
      Maneuver: 0,
      Distance: -1,
      Remaining: T('probe'),
      Instruction: T('tick', { n: probe.ticks, g: probe.maxGapSec }) + '\n' + gpsText,
      Eta: T('phone') + two(d.getHours()) + ':' + two(d.getMinutes()) + ':' + two(d.getSeconds())
    });
  }

  var reported = false;
  function reportOnce(text) {
    if (reported) return;
    reported = true;
    report(text);
  }
  // Some runtimes never call back when location is unavailable.
  setTimeout(function () { reportOnce(T('gpsNone')); }, REQUEST_TIMEOUT_MS + 500);
  var askedAt = Date.now();
  navigator.geolocation.getCurrentPosition(
    function (pos) {
      // The Pebble iOS app gives no timestamp; then report how long the answer took.
      var gps = typeof pos.timestamp === 'number'
        ? T('gpsOld', { s: Math.max(0, Math.round((Date.now() - pos.timestamp) / 1000)) })
        : T('gpsIn', { s: ((Date.now() - askedAt) / 1000).toFixed(1) });
      reportOnce(gps + ', ±' + Math.round(pos.coords.accuracy) + ' m');
    },
    function (err) {
      reportOnce(T('gpsError') + err.code);
    },
    { enableHighAccuracy: true, maximumAge: 0, timeout: REQUEST_TIMEOUT_MS }
  );
}

function handleStep(s) {
  if (s.lang === 'vi' || s.lang === 'en') navLang = s.lang;
  if (s.theme === 'light' || s.theme === 'dark') navTheme = s.theme === 'light' ? 1 : 0;
  if (typeof s.themeAuto === 'boolean') navThemeAuto = s.themeAuto ? 1 : 0;
  if (s.ended) {
    hadStep = false;
    send({ Ended: 1, Instruction: s.reason || '' });
  } else if (s.routing) {
    sendStatus(T('routing'));
  } else if (!s.active) {
    sendStatus(T('noTrip'));
  } else {
    hadStep = true;
    send({
      Maneuver: s.maneuver,
      Distance: s.distance,
      Instruction: s.instruction,
      Remaining: s.remaining,
      Eta: s.eta
    });
  }
}

function fetchStep() {
  var xhr = new XMLHttpRequest();
  var finished = false;
  function fail() {
    if (finished) return;
    finished = true;
    if (hadStep) {
      sendStatus(T('notAnswering'));
    } else {
      sendProbe();
    }
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
    clearTimeout(watchdog);
    release(xhr);
    if (xhr.status !== 200) {
      sendStatus(T('navAppError') + xhr.status);
      return;
    }
    try {
      handleStep(JSON.parse(xhr.responseText));
    } catch (e) {
      sendStatus(T('badData'));
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
