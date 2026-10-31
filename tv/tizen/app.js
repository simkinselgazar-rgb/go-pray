// Go Pray Tizen: params -> decide (de-dupe) -> still + label -> one Athan -> 30 s tail -> exit. Back exits.
// Behaviour mirrors tv/roku (main.brs, AthanScene.brs). Pure logic is in logic.js. No network, no HTML building:
// nothing from the launch payload is ever used as HTML, a URL or a path (file names come from the fixed voice table).
(function () {
  'use strict';
  var LG = window.GoPrayLogic;
  var store;
  try { store = window.localStorage; store.getItem('gopray.last'); } catch (e) { store = memStore(); }

  function memStore() {
    var m = {};
    return { getItem: function (k) { return Object.prototype.hasOwnProperty.call(m, k) ? m[k] : null; }, setItem: function (k, v) { m[k] = String(v); } };
  }

  var bg = document.getElementById('bg');
  var labelEl = document.getElementById('label');
  var debugEl = document.getElementById('debug');
  var aud = document.getElementById('aud');

  var tailTimer = null, startTimer = null, beatTimer = null;
  var heard = false, fallbackFile = '', seekTo = 0, seeked = false, ended = false;
  var st = { resumed: false, started: false };
  var d = null;

  function now() { return new Date(); }

  function exitApp() {
    if (ended) return;
    ended = true;
    clearTimeout(tailTimer); clearTimeout(startTimer); clearInterval(beatTimer);
    try { if (d && d.rec) LG.finish(store); } catch (e) { /* storage unavailable */ }
    try { aud.pause(); } catch (e) { /* ignore */ }
    try { window.tizen.application.getCurrentApplication().exit(); } catch (e) { try { window.close(); } catch (e2) { /* browser */ } }
  }

  function phase(p) {
    if (!d || !d.rec) return;
    try { LG.record(store, p, st, now()); } catch (e) { /* storage unavailable */ }
  }

  function startTail(seconds) {
    phase('tail');
    clearTimeout(tailTimer);
    tailTimer = setTimeout(exitApp, seconds * 1000);
  }

  // Everything the launch could have carried: AppControl data (any key) and location.search.
  function launchSources() {
    var src = [], raw = '';
    try {
      var data = window.tizen.application.getCurrentApplication().getRequestedAppControl().appControl.data;
      src.push(data);
      raw = JSON.stringify(data);
    } catch (e) { raw = 'no appcontrol'; }
    if (window.location.search) src.push(window.location.search);
    return { src: src, raw: raw };
  }

  function startPlay(file) {
    clearTimeout(startTimer);
    heard = false; seeked = false;
    startTimer = setTimeout(function () { if (!heard) fallBack('no audio in 8 s'); }, 8000);
    aud.src = file;
    aud.load();
    var p = aud.play();
    if (p && p.catch) p.catch(function () { /* the 8 s timer handles a blocked autoplay */ });
  }

  // The file did not come up: the default voice plays instead (once), else a short tail and exit.
  function fallBack(why) {
    if (heard || ended) return;
    if (fallbackFile) {
      var f = fallbackFile;
      fallbackFile = '';
      seekTo = 0;
      if (d.debug) debugEl.textContent = 'fallback: ' + why;
      startPlay(f);
    } else {
      startTail(10);
    }
  }

  aud.addEventListener('loadedmetadata', function () {
    if (seekTo > 0 && !seeked) {
      seeked = true;
      try { aud.currentTime = seekTo; } catch (e) { /* ignore */ }
    }
  });
  aud.addEventListener('playing', function () {
    heard = true;
    clearTimeout(startTimer);
    phase('playing');
  });
  aud.addEventListener('ended', function () {
    if (heard) startTail(LG.TAIL);
    else fallBack('ended without playing');
  });
  aud.addEventListener('error', function () {
    if (!heard) fallBack('error');
    else startTail(10);
  });

  window.addEventListener('keydown', function (e) {
    if (e.keyCode === 10009 || e.key === 'Escape') exitApp();   // 10009 = Return/Back on Samsung remotes
  });

  var ls = launchSources();
  var params = LG.findParams(ls.src);
  d = LG.decide(store, params, now());
  if (d.action === 'exit') { exitApp(); return; }

  st.resumed = d.resume;
  bg.src = 'images/still-' + d.prayer + '.jpg';
  labelEl.className = d.prayer;
  labelEl.textContent = LG.labelFor(d.prayer, d.voice);
  if (d.debug) debugEl.textContent = ls.raw.slice(0, 200);

  if (d.rec) beatTimer = setInterval(function () { try { LG.beat(store, now()); } catch (e) { /* ignore */ } }, 5000);

  if (d.tailLeft > 0) {
    // the Athan already ended on this TV: just the still until the tail runs out
    startTail(d.tailLeft);
  } else {
    var file = LG.audioFile(d.prayer, d.voice);
    seekTo = (d.prayer === 'fajr' ? 9.0 : 0) + d.elapsed;
    fallbackFile = (file === LG.FALLBACK_AUDIO) ? '' : LG.FALLBACK_AUDIO;
    startPlay(file);
  }
})();
