/* Go Pray — app-only bridge between shield.html and Swift (Architecture Plan C.6).
   The page can ask; only Swift decides. This file never touches the timer logic in ui.js.
   JS -> Swift: ready, prayed, silence, emergency, gone (handler "gopray", payload {type}).
   Swift -> JS: GoPrayBridge.show(ctx), .athanStopped(), .dismiss(kind). No key shortcuts, no chrome.
   v2: a quiet footer "Emergency exit · N of 5 left this year". Hold 3 s (a thin bar fills), then a confirm card, then
   one `emergency` message. The hold and the card stop a reflex; the gate alone decides whether it counts. */
(function () {
  'use strict';
  const GP = window.GoPray;
  const ORDER = ['fajr', 'dhuhr', 'asr', 'maghrib', 'isha'];
  const LAYOUTS = ['full', 'notice', 'art', 'portrait'];
  const MAX_MS = 30 * 60 * 1000;
  const HOLD_MS = 3000;
  const MAX_EXITS = 5;

  function post(type) {
    try { window.webkit.messageHandlers.gopray.postMessage({ type: type }); } catch (e) { /* not in the app */ }
  }
  const clampMs = (v) => (typeof v === 'number' && isFinite(v) ? Math.min(MAX_MS, Math.max(0, Math.round(v))) : 0);

  const shield = document.getElementById('shield');
  const sceneEl = document.getElementById('scene');
  const stage = new GP.Stage(sceneEl);
  GP.stage = stage;

  // iPhone portrait. The approved scenes are 1600 x 1000 with the subject on the right, and watercolor.js is
  // not edited, so the phone "camera" lives here: per prayer a scale and the virtual point that should sit in
  // the lower half. The painted frame is bottom-aligned; the empty top of the screen is the prayer's own ground
  // colour and the top edge of the paint is feathered into it (a wet edge), so the sky above the subject stays
  // calm for the name. Only active with layout=portrait; every other layout takes the untouched code path.
  const CAMERAS = {            // s: pixels per virtual unit at a 393 pt wide screen; fx: virtual x centred on screen
    fajr: { s: 0.54, fx: 1050 },
    dhuhr: { s: 0.44, fx: 1190 },
    asr: { s: 0.44, fx: 900 },
    maghrib: { s: 0.44, fx: 1090 },
    isha: { s: 0.42, fx: 1090 },
  };
  let portrait = null;         // { prayer } while a portrait scene is painted
  const origView = stage.view;
  const origShow = stage.show;
  function portraitView(self) {
    const w = self.host.clientWidth, h = self.host.clientHeight;
    const cam = CAMERAS[portrait.prayer];
    // scale follows the screen width so an iPad or a small phone keeps the same composition
    const s = cam.s * (w / 393);
    let ox = w / 2 - cam.fx * s;
    ox = Math.min(0, Math.max(w - GP.wc.VW * s, ox));   // never show past the painted edge
    return { w, h, s, ox, oy: h - GP.wc.VH * s, pr: Math.min(window.devicePixelRatio || 1, 2) };
  }
  stage.view = function () { return portrait ? portraitView(this) : origView.call(this); };
  stage.show = function (id, opts) {
    origShow.call(this, id, opts);
    if (!portrait) return;
    const v = portraitView(this);
    const ink = this.host.querySelector('.scene-ink');
    if (ink) {   // the pen layer is sized by its viewBox; give it the same window as the canvases
      ink.setAttribute('viewBox', [-v.ox / v.s, -v.oy / v.s, v.w / v.s, v.h / v.s].join(' '));
      ink.setAttribute('preserveAspectRatio', 'none');
    }
    const fade = Math.round(Math.min(v.oy, v.h * 0.3));
    const stops = [];   // a smoothstep ramp, so the edge of the paint has no visible start line
    for (let i = 0; i <= 8; i++) {
      const t = i / 8, a = t * t * (3 - 2 * t);
      stops.push('rgba(0,0,0,' + a.toFixed(3) + ') ' + Math.round(v.oy + fade * t) + 'px');
    }
    const mask = 'linear-gradient(to bottom, ' + stops.join(', ') + ')';
    this.host.querySelectorAll(':scope > canvas, :scope > svg').forEach((el) => {
      el.style.webkitMaskImage = mask;
      el.style.maskImage = mask;
    });
  };

  let ui = null;
  let cur = null;        // { prayer, layout, reduce } of what is painted now
  let token = 0;         // drops a stale async render when a newer show() arrives
  let revealTimer = 0;
  let quietFromSwift = false;
  let ringObserver = null;
  let exitEl = null;      // the footer + the confirm card, rebuilt with every show()
  let exitPending = false;  // `emergency` was sent; a show() before the dismiss means the gate said no
  let exitNote = '';
  let exitNoteTimer = 0;
  const NAME_OF = (p) => { const n = GP.NAMES && GP.NAMES[p]; return n ? n[0] : 'This prayer'; };

  function dropExit() {
    if (exitEl) { exitEl.remove(); exitEl = null; }
    const card = shield.querySelector('.exit-card');
    if (card) card.remove();
    shield.classList.remove('is-confirming');
  }

  // Press and hold 3 s on the footer (pointer only: no key shortcut, by design). Release early cancels. Reduce Motion does not stop the bar: it is information, not decoration.
  function buildExit(prayer, left, layout) {
    dropExit();
    if (left <= 0 && !exitNote) return;
    const root = document.createElement('div');
    root.className = 'exit';
    const label = 'Hold for emergency exit \u00b7 ' + left + ' of ' + MAX_EXITS + ' left this year';
    if (left > 0) {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'exit-btn';
      const fill = document.createElement('span');
      fill.className = 'exit-fill';
      fill.setAttribute('aria-hidden', 'true');
      const text = document.createElement('span');
      text.className = 'exit-label';
      btn.appendChild(fill);
      btn.appendChild(text);
      text.textContent = label;
      let timer = 0;
      const stop = () => {
        if (!timer) return;
        clearTimeout(timer); timer = 0;
        btn.classList.remove('is-holding');
        text.textContent = label;
        // Released before the hold finished: say why nothing happened.
        exitNote = 'Keep holding for 3 seconds.';
        const n = document.querySelector('.exit-note'); if (n) n.textContent = exitNote;
        clearTimeout(exitNoteTimer);
        exitNoteTimer = setTimeout(() => { exitNote = ''; const m = document.querySelector('.exit-note'); if (m) m.textContent = ''; }, 4000);
      };
      const begin = () => {
        if (timer || exitPending) return;
        btn.classList.add('is-holding');
        text.textContent = 'Keep holding\u2026';
        timer = setTimeout(() => { timer = 0; btn.classList.remove('is-holding'); text.textContent = label; openCard(prayer, left, root); }, HOLD_MS);
      };
      btn.addEventListener('pointerdown', (e) => {
        if (e.button !== 0) return;
        e.preventDefault();
        // Keep the hold alive if a trackpad drifts off the small button.
        try { btn.setPointerCapture(e.pointerId); } catch (_) { /* synthetic or already released */ }
        begin();
      });
      ['pointerup', 'pointercancel', 'lostpointercapture', 'blur'].forEach((n) => btn.addEventListener(n, stop));
      root.appendChild(btn);
    }
    const note = document.createElement('p');
    note.className = 'exit-note';
    note.setAttribute('role', 'status');
    note.textContent = exitNote;
    root.appendChild(note);
    shield.appendChild(root);
    exitEl = root;
  }

  function openCard(prayer, left, root) {
    if (shield.querySelector('.exit-card')) return;
    const card = document.createElement('div');
    card.className = 'exit-card';
    card.setAttribute('role', 'alertdialog');
    card.setAttribute('aria-modal', 'true');
    card.setAttribute('aria-labelledby', 'exit-title');
    const rest = left <= 1 ? 'This is your last one this year.' : "You'll have " + (left - 1) + ' of ' + MAX_EXITS + ' left this year.';
    const make = (tag, cls, text) => {
      const el = document.createElement(tag);
      if (cls) el.className = cls;
      if (text) el.textContent = text;
      return el;
    };
    const title = make('h2', '', 'Use an emergency exit?');
    title.id = 'exit-title';
    const bodyEl = make('p', 'exit-body',
      'This ends the block now. ' + NAME_OF(prayer) + ' will count as missed, not prayed. ' + rest);
    const actions = make('div', 'exit-actions');
    const no = make('button', 'exit-no', 'Not now');
    const yes = make('button', 'exit-yes', 'Use it');
    no.type = 'button'; yes.type = 'button';
    actions.appendChild(no); actions.appendChild(yes);
    card.appendChild(title); card.appendChild(bodyEl); card.appendChild(actions);
    no.addEventListener('click', () => { card.remove(); shield.classList.remove('is-confirming'); });
    yes.addEventListener('click', () => {
      if (exitPending) return;
      exitPending = true;
      yes.disabled = true; no.disabled = true;
      post('emergency');
    });
    shield.appendChild(card);
    shield.classList.add('is-confirming');
    no.focus({ preventScroll: true });
  }

  function dropUI() {
    clearTimeout(revealTimer);
    if (ringObserver) { ringObserver.disconnect(); ringObserver = null; }
    if (ui) { ui.destroy(); ui = null; }
    dropExit();
  }

  // ui.js draws the ring over `durationMs` from its own start. After a relaunch or resync that would
  // restart the ring at 0, so the ring's offset is re-pinned to the true progress each time ui.js
  // writes it (ui.js itself is untouched).
  const RING_C = 2 * Math.PI * 47;
  function pinRing(totalMs, remainingMs, reduce) {
    const fill = shield.querySelector('.ring-fill');
    if (!fill || totalMs <= remainingMs + 500) return;   // nothing to correct
    const showAt = Date.now();
    let mine = '';
    const apply = () => {
      if (fill.getAttribute('stroke-dashoffset') === mine) return;
      const elapsed = (totalMs - remainingMs) + (Date.now() - showAt);
      const p = Math.min(1, elapsed / totalMs);
      const ahead = reduce ? p : Math.min(1, (elapsed + 1000) / totalMs);
      mine = String(RING_C * (1 - ahead));
      fill.setAttribute('stroke-dashoffset', mine);
    };
    ringObserver = new MutationObserver(apply);
    ringObserver.observe(fill, { attributes: true, attributeFilter: ['stroke-dashoffset'] });
    apply();
  }

  async function show(ctx) {
    if (!ctx || typeof ctx !== 'object') return;
    const prayer = ORDER.includes(ctx.prayer) ? ctx.prayer : 'dhuhr';
    const layout = LAYOUTS.includes(ctx.layout) ? ctx.layout : 'full';
    const reduce = ctx.reduceMotion === true;
    const remainingMs = clampMs(ctx.remainingMs);
    const athanMs = clampMs(ctx.athanRemainingMs);
    const lockMs = clampMs(ctx.lockMs);
    const exitsLeft = typeof ctx.emergencyExitsLeft === 'number' && isFinite(ctx.emergencyExitsLeft)
      ? Math.min(MAX_EXITS, Math.max(0, Math.round(ctx.emergencyExitsLeft))) : 0;
    if (exitPending) {
      // A show() after we asked means the gate refused (or could not write the use): say so, once.
      exitPending = false;
      exitNote = "Couldn't use the exit. Try again in a moment.";
      clearTimeout(exitNoteTimer);
      exitNoteTimer = setTimeout(() => { exitNote = ''; const n = document.querySelector('.exit-note'); if (n) n.textContent = ''; }, 6000);
    }
    const name = typeof ctx.hiddenAppName === 'string' ? ctx.hiddenAppName.slice(0, 60) : '';
    const mine = ++token;
    const same = !!cur && cur.prayer === prayer && cur.layout === layout && cur.reduce === reduce;

    document.documentElement.classList.toggle('reduce', reduce);
    document.documentElement.classList.remove('layout-full', 'layout-notice', 'layout-art', 'layout-portrait');
    document.documentElement.classList.add('layout-' + layout);
    dropUI();

    if (!same) {
      shield.classList.remove('is-gone');
      shield.dataset.prayer = prayer;
      sceneEl.className = 'scene';
      await document.fonts.ready;
      if (mine !== token) return;
    }
    cur = { prayer: prayer, layout: layout, reduce: reduce };
    portrait = layout === 'portrait' ? { prayer: prayer } : null;

    if (layout !== 'art' && layout !== 'portrait') {
      ui = GP.BlockUI(shield, {
        prayer: prayer,
        durationMs: Math.max(1, remainingMs),   // 0 would make the ring NaN
        athanMs: athanMs,
        reduce: reduce,
        onDone() { post('gone'); },
      });
      pinRing(lockMs, remainingMs, reduce);
      buildExit(prayer, exitsLeft, layout);
      if (layout === 'notice') {
        const copy = shield.querySelector('.copy');
        if (copy) {
          copy.textContent = name
            ? name + ' is resting until you pray. Your agents keep running.'
            : 'Your coding apps are resting until you pray.';
        }
      }
    }
    if (!same) {
      stage.show(prayer, {
        reduce: reduce,
        durationMs: Math.max(1, remainingMs),
        onBloomed() { if (ui) ui.reveal(); },
      });
      if (ui && !reduce) revealTimer = setTimeout(() => { if (ui) ui.reveal(); }, 1700);
    } else if (ui) {
      ui.reveal();   // a re-sync: the scene is already painted, do not bloom again
    }
  }

  // Swift asked to close (the gate confirmed). If the page already started its own
  // "May Allah accept it." fade (the person clicked), it is not started twice.
  function dismiss(kind) {
    const block = shield.querySelector('.block');
    const accept = shield.querySelector('.accept');
    const reduce = document.documentElement.classList.contains('reduce');
    if (block && block.classList.contains('is-leaving')) return;
    if (kind === 'emergency') {
      // The honest end: a plain fade, no "May Allah accept it." (the prayer counts as missed).
      exitPending = false;
      dropExit();
      if (block) block.classList.add('is-leaving');
      setTimeout(() => shield.classList.add('is-gone'), 0);
      setTimeout(() => post('gone'), reduce ? 700 : 900);
      return;
    }
    if (block) block.classList.add('is-leaving');
    if (accept) accept.classList.add('is-on');
    setTimeout(() => shield.classList.add('is-gone'), reduce ? 1000 : 250);
    setTimeout(() => post('gone'), reduce ? 1200 : 1300);
  }

  function athanStopped() {
    const s = shield.querySelector('.silence');
    if (!s || s.classList.contains('is-quiet')) return;
    quietFromSwift = true;   // Swift already knows; do not echo a `silence` back
    try { s.click(); } finally { quietFromSwift = false; }
  }

  // CSP violations are counted so a test (and a log) can tell the scenes still render under the policy.
  const violations = [];
  document.addEventListener('securitypolicyviolation', (e) => violations.push(e.violatedDirective + ' ' + e.blockedURI));

  // These return nothing (evaluateJavaScript cannot carry a Promise back); a failed show is reported by name.
  window.GoPrayBridge = Object.freeze({
    show(ctx) { show(ctx).catch((e) => console.error('show failed', e)); },
    dismiss(kind) { dismiss(kind === 'emergency' ? 'emergency' : 'confirmed'); },
    athanStopped() { athanStopped(); },
    violations() { return violations.length; },
  });

  // What the page asks Swift for (the footer button posts `emergency` itself, after the hold and the card).
  document.addEventListener('click', (e) => {
    const t = e.target && e.target.closest ? e.target.closest('button') : null;
    if (!t || t.disabled) return;
    if (t.classList.contains('prayed')) post('prayed');
    else if (t.classList.contains('silence') && !quietFromSwift) post('silence');
  });

  // Nothing to select, drag, drop or right-click.
  ['contextmenu', 'dragstart', 'dragover', 'drop', 'selectstart'].forEach((n) =>
    document.addEventListener(n, (e) => e.preventDefault()));

  // A resize repaints the scene as a still (as in the preview page); the block UI is left alone.
  let rt = 0;
  addEventListener('resize', () => {
    clearTimeout(rt);
    rt = setTimeout(() => { if (cur) stage.show(cur.prayer, { reduce: true, durationMs: 600000 }); }, 250);
  });

  // Standalone (stills, tests): ?prayer=fajr&layout=art&reduce=1&ms=600000 paints without Swift.
  const q = new URLSearchParams(location.search);
  if (q.has('prayer')) {
    show({
      prayer: q.get('prayer'),
      layout: q.get('layout') || 'art',
      reduceMotion: q.get('reduce') === '1',
      remainingMs: Number(q.get('ms') || 600000),
      athanRemainingMs: 0,
    });
  }
  document.fonts.ready.then(() => post('ready'));
})();
