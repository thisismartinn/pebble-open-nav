// Runs inside the Pebble phone app. Each Tick from the watch fetches the
// current step from the navigation app's local server on this phone.
var STEP_URL = 'http://127.0.0.1:8765/step';
var REQUEST_TIMEOUT_MS = 2500;

// Probe mode (no nav app running): measures how the Pebble app behaves in the
// background, i.e. whether every watch tick still gets answered and GPS stays fresh.
var probe = { ticks: 0, lastTickAt: 0, maxGapSec: 0 };

function sendStatus(text) {
  Pebble.sendAppMessage({ Status: text });
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
    Pebble.sendAppMessage({
      Maneuver: 0,
      Distance: -1,
      Remaining: 'No nav app: probe',
      Instruction: 'Tick ' + probe.ticks + ', max gap ' + probe.maxGapSec + ' s\n' + gpsText,
      Eta: 'Phone ' + two(d.getHours()) + ':' + two(d.getMinutes()) + ':' + two(d.getSeconds())
    });
  }

  var reported = false;
  function reportOnce(text) {
    if (reported) return;
    reported = true;
    report(text);
  }
  // Some runtimes never call back when location is unavailable.
  setTimeout(function () { reportOnce('GPS no answer'); }, REQUEST_TIMEOUT_MS + 500);
  navigator.geolocation.getCurrentPosition(
    function (pos) {
      var age = Math.max(0, Math.round((Date.now() - pos.timestamp) / 1000));
      reportOnce('GPS ' + age + ' s old, ±' + Math.round(pos.coords.accuracy) + ' m');
    },
    function (err) {
      reportOnce('GPS error ' + err.code);
    },
    { enableHighAccuracy: true, maximumAge: 0, timeout: REQUEST_TIMEOUT_MS }
  );
}

function handleStep(s) {
  if (s.ended) {
    Pebble.sendAppMessage({ Ended: 1, Instruction: s.reason || '' });
  } else if (!s.active) {
    sendStatus('No trip started');
  } else {
    Pebble.sendAppMessage({
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
    sendProbe();
  }
  // Our own timeout as well as xhr.timeout: not every JS runtime reports a refused connection.
  var watchdog = setTimeout(function () {
    try { xhr.abort(); } catch (e) {}
    fail();
  }, REQUEST_TIMEOUT_MS);

  xhr.open('GET', STEP_URL + '?t=' + Date.now(), true);
  xhr.timeout = REQUEST_TIMEOUT_MS;
  xhr.onload = function () {
    if (finished) return;
    finished = true;
    clearTimeout(watchdog);
    if (xhr.status !== 200) {
      sendStatus('Nav app error ' + xhr.status);
      return;
    }
    try {
      handleStep(JSON.parse(xhr.responseText));
    } catch (e) {
      sendStatus('Bad data from nav app');
    }
  };
  xhr.onerror = xhr.ontimeout = function () {
    clearTimeout(watchdog);
    fail();
  };
  xhr.send();
}

Pebble.addEventListener('ready', fetchStep);
Pebble.addEventListener('appmessage', function (e) {
  if (e.payload.Tick) fetchStep();
});
