/* Go Pray — app-only bridge between shield.html and Swift (Architecture Plan C.6).
   The page can ask; only Swift decides. This file never touches the timer logic in ui.js.
   JS -> Swift: ready, prayed, silence, gone (handler "gopray", payload {type}).
   Swift -> JS: GoPrayBridge.show(ctx), .athanStopped(), .dismiss(). No key handlers, no chrome. */
(function () {
  'use strict';
  const GP = window.GoPray;
  const ORDER = ['fajr', 'dhuhr', 'asr', 'maghrib', 'isha'];
  const LAYOUTS = ['full', 'notice', 'art'];
  const MAX_MS = 30 * 60 * 1000;

  function post(type) {
    try { window.webkit.messageHandlers.gopray.postMessage({ type: type }); } catch (e) { /* not in the app */ }
  }
  const clampMs = (v) => (typeof v === 'number' && isFinite(v) ? Math.min(MAX_MS, Math.max(0, Math.round(v))) : 0);

  const shield = document.getElementById('shield');
  const sceneEl = document.getElementById('scene');
  const stage = new GP.Stage(sceneEl);
  GP.stage = stage;

  let ui = null;
  let cur = null;        // { prayer, layout, reduce } of what is painted now
  let token = 0;         // drops a stale async render when a newer show() arrives
  let revealTimer = 0;
  let quietFromSwift = false;
  let ringObserver = null;

  function dropUI() {
    clearTimeout(revealTimer);
    if (ringObserver) { ringObserver.disconnect(); ringObserver = null; }
    if (ui) { ui.destroy(); ui = null; }
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
    const name = typeof ctx.hiddenAppName === 'string' ? ctx.hiddenAppName.slice(0, 60) : '';
    const mine = ++token;
    const same = !!cur && cur.prayer === prayer && cur.layout === layout && cur.reduce === reduce;

    document.documentElement.classList.toggle('reduce', reduce);
    document.documentElement.classList.remove('layout-full', 'layout-notice', 'layout-art');
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

    if (layout !== 'art') {
      ui = GP.BlockUI(shield, {
        prayer: prayer,
        durationMs: Math.max(1, remainingMs),   // 0 would make the ring NaN
        athanMs: athanMs,
        reduce: reduce,
        onDone() { post('gone'); },
      });
      pinRing(lockMs, remainingMs, reduce);
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
  function dismiss() {
    const block = shield.querySelector('.block');
    const accept = shield.querySelector('.accept');
    const reduce = document.documentElement.classList.contains('reduce');
    if (block && block.classList.contains('is-leaving')) return;
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
    dismiss() { dismiss(); },
    athanStopped() { athanStopped(); },
    violations() { return violations.length; },
  });

  // The only two things the page asks Swift for.
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
