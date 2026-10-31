// Go Pray Tizen: the pure logic (no DOM, no Tizen). Loaded by index.html and by test/params.test.mjs.
// Mirrors tv/roku/source/main.brs (ParamsOf, Decide, Record, Beat) and AthanScene.brs (KnownVoices, ParseVoice).
(function (root) {
  'use strict';

  var PRAYERS = ['fajr', 'dhuhr', 'asr', 'maghrib', 'isha'];
  var DEFAULT_VOICE = { group: 'sunni', stem: 'Adhan-Makkah' };
  var KNOWN_VOICES = {
    sunni: ['Abdul-Basit', 'Abdul-Ghaffar', 'Abdul-Hakam', 'Adhan-Alaqsa', 'Adhan-Egypt', 'Adhan-Halab', 'Adhan-Madinah', 'Adhan-Makkah', 'Al-Hussaini', 'Bakir-Bash', 'Hafez', 'Hafiz-Murad', 'Minshawi', 'Naghshbandi', 'Saber', 'Sharif-Doman'],
    shia: ['Aghati', 'Ghalwash', 'Kazem-Zadeh', 'Moazzen-Zadeh', 'Mohammad-Zadeh', 'Rezaeian', 'Rowhani-Nejad', 'Salimi', 'Sharif', 'Sobhdel', 'Tasvieh-Chi', 'Tookhi']
  };
  var LIVE_WINDOW = 12;   // seconds: a heartbeat this fresh means the same Athan is still on (Roku: 12)
  var TAIL = 30;          // seconds of still after the Athan ends

  function has(list, s) { return list.indexOf(s) !== -1; }
  function isPrayer(p) { return typeof p === 'string' && has(PRAYERS, p); }

  // "sunni.Minshawi" -> { group, stem }; anything unknown -> the default voice.
  function parseVoice(v) {
    if (typeof v === 'string') {
      var dot = v.indexOf('.');
      if (dot > 0) {
        var group = v.slice(0, dot).toLowerCase();
        var stem = v.slice(dot + 1);
        if (Object.prototype.hasOwnProperty.call(KNOWN_VOICES, group) && has(KNOWN_VOICES[group], stem)) {
          return { group: group, stem: stem };
        }
      }
    }
    return { group: DEFAULT_VOICE.group, stem: DEFAULT_VOICE.stem };
  }

  function voiceId(v) { return v.group + '.' + v.stem; }

  // Built only from the fixed tables, never from raw input.
  function audioFile(prayer, voice) {
    if (prayer === 'fajr') return 'audio/fajr.mp3';
    return 'audio/' + voice.group + '.' + voice.stem + '.mp3';
  }
  var FALLBACK_AUDIO = 'audio/sunni.Adhan-Makkah.mp3';

  function labelFor(prayer, voice) {
    if (prayer === 'fajr') return 'Athan · Sheikh Hamed';
    return 'Athan · ' + voice.stem.replace(/-/g, ' ');
  }

  function dec(s) { try { return decodeURIComponent(s.replace(/\+/g, ' ')); } catch (e) { return ''; } }

  // "prayer=asr&voice=sunni.Minshawi&test=1" (a leading "?" is fine) -> { prayer, voice, test } or null when no valid prayer.
  // Only the three known keys are read; everything else is dropped.
  function parseQuery(s) {
    if (typeof s !== 'string' || s.length === 0 || s.length > 2000) return null;
    if (s.charAt(0) === '?') s = s.slice(1);
    var out = { prayer: '', voice: '', test: false };
    var parts = s.split('&');
    for (var i = 0; i < parts.length; i++) {
      var eq = parts[i].indexOf('=');
      if (eq < 1) continue;
      var k = dec(parts[i].slice(0, eq));
      var val = dec(parts[i].slice(eq + 1));
      if (k === 'prayer') out.prayer = val.toLowerCase();
      else if (k === 'voice') out.voice = val;
      else if (k === 'test') out.test = (val === '1');
    }
    if (!isPrayer(out.prayer)) return null;
    return out;
  }

  // Strings to look at: AppControl data is [{key, value:[str,...]}], but be liberal about the shape (UNKNOWN until step 5).
  // A value may itself be a JSON string holding the query, so look one or two levels into JSON too.
  function collectStrings(x, out, depth, jd) {
    if (out.length > 200 || depth > 8) return;
    if (typeof x === 'string') {
      out.push(x);
      if (jd < 3 && (x.charAt(0) === '{' || x.charAt(0) === '[')) {
        try { collectStrings(JSON.parse(x), out, depth + 1, jd + 1); } catch (e) { /* not JSON */ }
      }
    } else if (Array.isArray(x)) {
      for (var i = 0; i < x.length; i++) collectStrings(x[i], out, depth + 1, jd);
    } else if (x && typeof x === 'object') {
      for (var k in x) if (Object.prototype.hasOwnProperty.call(x, k)) collectStrings(x[k], out, depth + 1, jd);
    }
  }

  // sources: any mix of AppControl data and strings (location.search). First one that parses with a valid prayer wins.
  function findParams(sources) {
    var strs = [];
    collectStrings(sources, strs, 0, 0);
    for (var i = 0; i < strs.length; i++) {
      var p = parseQuery(strs[i]);
      if (p) return p;
    }
    return null;
  }

  // Hour bands for a launch without usable params (REST launch, or WSS dead on this TV).
  function bandPrayer(d) {
    var m = d.getHours() * 60 + d.getMinutes();
    if (m >= 180 && m < 600) return 'fajr';        // 03:00-09:59
    if (m >= 600 && m < 900) return 'dhuhr';       // 10:00-14:59
    if (m >= 900 && m < 1050) return 'asr';        // 15:00-17:29
    if (m >= 1050 && m < 1155) return 'maghrib';   // 17:30-19:14
    return 'isha';                                 // 19:15-02:59
  }

  function pad2(n) { return (n < 10 ? '0' : '') + n; }
  function dayKey(d, prayer) {
    return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate()) + '/' + prayer;
  }

  function num(store, k) {
    var v = parseInt(store.getItem('gopray.' + k), 10);
    return isNaN(v) ? 0 : v;
  }
  function put(store, k, v) { store.setItem('gopray.' + k, String(v)); }
  function get(store, k) { return store.getItem('gopray.' + k); }

  // Decides what a launch does. params = parseQuery result or null. date = the TV's local clock.
  // Returns { action: 'play'|'exit', prayer, voice:{group,stem}, test, rec, resume, elapsed, tailLeft, fallback, debug }.
  function decide(store, params, date) {
    var t = Math.floor(date.getTime() / 1000);
    var fallback = !params;
    var prayer, voiceStr, test;
    if (fallback) {
      prayer = bandPrayer(date);
      voiceStr = store.getItem('gopray.voice') || '';   // the last voice the app ever received
      test = false;
    } else {
      prayer = params.prayer;
      voiceStr = params.voice;
      test = params.test;
    }
    var voice = parseVoice(voiceStr);
    var d = { action: 'play', prayer: prayer, voice: voice, test: test, rec: !test, resume: false, elapsed: 0, tailLeft: 0, fallback: fallback, debug: fallback || test };
    if (test) return d;   // test=1 always plays and is never recorded

    var key = dayKey(date, prayer);
    if (get(store, 'last') === key) {
      var phase = get(store, 'phase');
      var alive = num(store, 'alive');
      if ((phase === 'playing' || phase === 'tail') && (t - alive) <= LIVE_WINDOW) {
        // the same Athan is on right now: carry on with it, never start a second one
        d.voice = parseVoice(get(store, 'voice') || '');
        d.resume = true;
        d.elapsed = Math.max(0, t - num(store, 'start'));
        if (phase === 'tail') d.tailLeft = Math.max(1, num(store, 'tailEnd') - t);
        put(store, 'alive', t);
        return d;
      }
      d.action = 'exit';
      return d;
    }
    put(store, 'last', key);
    put(store, 'voice', voiceId(voice));
    put(store, 'phase', 'playing');
    put(store, 'alive', t);
    put(store, 'start', t);
    return d;
  }

  // st = { resumed, started } for this run. Call on the audio's phase changes.
  function record(store, phase, st, date) {
    var t = Math.floor(date.getTime() / 1000);
    if (phase === 'playing') {
      if (!st.resumed && !st.started) put(store, 'start', t);
      st.started = true;
      put(store, 'phase', 'playing');
    } else if (phase === 'tail') {
      if (get(store, 'phase') !== 'tail') put(store, 'tailEnd', t + TAIL);
      put(store, 'phase', 'tail');
    }
    put(store, 'alive', t);
  }

  function beat(store, date) {
    var ph = get(store, 'phase');
    if (ph !== null && ph !== 'ended') put(store, 'alive', Math.floor(date.getTime() / 1000));
  }

  function finish(store) {
    if (get(store, 'phase') !== null) put(store, 'phase', 'ended');
  }

  var api = {
    PRAYERS: PRAYERS, KNOWN_VOICES: KNOWN_VOICES, DEFAULT_VOICE: DEFAULT_VOICE, FALLBACK_AUDIO: FALLBACK_AUDIO, TAIL: TAIL,
    parseVoice: parseVoice, voiceId: voiceId, audioFile: audioFile, labelFor: labelFor,
    parseQuery: parseQuery, findParams: findParams, bandPrayer: bandPrayer, dayKey: dayKey,
    decide: decide, record: record, beat: beat, finish: finish
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.GoPrayLogic = api;
})(typeof self !== 'undefined' ? self : this);
