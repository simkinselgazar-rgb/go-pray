/* Go Pray — block screen UI: name, ring, "I prayed", Silence, "May Allah accept it."
   The timer is wall clock from block start (a closed lid still counts). */
(function () {
  'use strict';
  const GP = (window.GoPray = window.GoPray || { scenes: {} });

  const NAMES = {
    fajr: ['Fajr', 'الفجر'],
    dhuhr: ['Dhuhr', 'الظهر'],
    asr: ['Asr', 'العصر'],
    maghrib: ['Maghrib', 'المغرب'],
    isha: ['Isha', 'العشاء'],
  };
  const R = 47; // ring radius in a 100x100 box
  const C = 2 * Math.PI * R;

  const LOCK = '<svg class="lock" viewBox="0 0 16 16" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"><rect x="3.5" y="7" width="9" height="6.5" rx="1.6"/><path d="M5.5 7V5.2a2.5 2.5 0 0 1 5 0V7"/></svg>';
  const SPEAKER_SLASH = '<svg viewBox="0 0 16 16" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"><path d="M2.5 6.2h2.2L8 3.5v9L4.7 9.8H2.5z"/><path d="M10.5 6l3 4M13.5 6l-3 4"/></svg>';

  function fmt(ms) {
    const s = Math.max(0, Math.ceil(ms / 1000));
    return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0');
  }

  // opts: { prayer, durationMs, athanMs, reduce, onDone }
  function BlockUI(shield, opts) {
    const [latin, arabic] = NAMES[opts.prayer];
    const block = document.createElement('section');
    block.className = 'block';
    block.setAttribute('aria-label', latin + ' prayer');
    block.innerHTML =
      `<h1 class="name"><span class="name-latin">${latin}</span><span class="name-ar" lang="ar" dir="rtl">${arabic}</span></h1>` +
      '<span class="rule" aria-hidden="true"></span>' +
      '<p class="copy">Time to pray. Your work will be right here.</p>' +
      '<div class="ring" role="timer" aria-live="off">' +
      `<svg viewBox="0 0 100 100" aria-hidden="true"><circle class="ring-track" cx="50" cy="50" r="${R}" fill="none" stroke-width="0.9"/>` +
      `<circle class="ring-fill" cx="50" cy="50" r="${R}" fill="none" stroke-width="1.6" stroke-linecap="round" stroke-dasharray="${C}" stroke-dashoffset="${C}"/></svg>` +
      '<span class="ring-time"></span></div>' +
      `<button class="btn prayed" type="button" disabled><span class="soak" aria-hidden="true"></span><span class="label">${LOCK}I prayed</span></button>` +
      `<button class="btn silence" type="button">${SPEAKER_SLASH}<span>Athan playing · Silence</span></button>`;
    const accept = document.createElement('p');
    accept.className = 'accept';
    accept.textContent = 'May Allah accept it.';
    shield.appendChild(block);
    shield.appendChild(accept);

    const fill = block.querySelector('.ring-fill');
    const time = block.querySelector('.ring-time');
    const ring = block.querySelector('.ring');
    const prayed = block.querySelector('.prayed');
    const silence = block.querySelector('.silence');
    const start = Date.now();
    let timer = 0, athanTimer = 0, done = false;

    function tick() {
      const elapsed = Date.now() - start;
      const left = opts.durationMs - elapsed;
      const p = Math.min(1, elapsed / opts.durationMs);
      // ease the ring one second ahead so the CSS transition lands on the true value
      const ahead = opts.reduce ? p : Math.min(1, (elapsed + 1000) / opts.durationMs);
      fill.setAttribute('stroke-dashoffset', String(C * (1 - ahead)));
      time.textContent = fmt(left);
      ring.setAttribute('aria-label', left > 0 ? `${fmt(left)} until you can confirm` : 'You can confirm now');
      if (left <= 0 && !done) {
        done = true;
        prayed.disabled = false;
        prayed.classList.add('is-ready');
        clearInterval(timer);
      }
    }

    function quiet() {
      silence.classList.add('is-quiet');
      silence.setAttribute('aria-hidden', 'true');
      silence.tabIndex = -1;
      clearTimeout(athanTimer);
    }
    silence.addEventListener('click', quiet);
    athanTimer = setTimeout(quiet, opts.athanMs);

    prayed.addEventListener('click', () => {
      if (!done) return;
      block.classList.add('is-leaving');
      accept.classList.add('is-on');
      // "May Allah accept it." holds for about a second while the shield fades
      setTimeout(() => shield.classList.add('is-gone'), opts.reduce ? 1000 : 250);
      setTimeout(() => opts.onDone && opts.onDone(), opts.reduce ? 1200 : 1300);
    });

    tick();
    // align ticks to the wall-clock second so the numerals never skip
    const align = 1000 - ((Date.now() - start) % 1000);
    const first = setTimeout(() => { tick(); timer = setInterval(tick, 1000); }, align);

    return {
      reveal() { block.classList.add('is-in'); },
      destroy() { clearTimeout(first); clearInterval(timer); clearTimeout(athanTimer); block.remove(); accept.remove(); },
    };
  }

  GP.BlockUI = BlockUI;
  GP.NAMES = NAMES;
})();
