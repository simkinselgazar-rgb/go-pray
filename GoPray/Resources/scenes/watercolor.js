/* Go Pray — watercolor engine + scene stage.
   Classic script (no modules) so it runs from file:// and inside a WKWebView with no build step.

   How a scene is made:
   - Static art is painted ONCE into offscreen canvases with layered translucent washes
     (deformed polygons, Tyler Hobbs style), wet edges, then pigment granulation + paper tooth.
   - Ink linework is SVG (pathLength=1) so it can draw in with stroke-dashoffset; a
     feTurbulence + feDisplacementMap filter gives it a hand-drawn wobble.
   - Only small things move: a "live" canvas capped at 30fps, or CSS opacity/transform
     on pre-rendered layers (compositor only). Nothing re-rasterises a filter per frame
     after the bloom. */
(function () {
  'use strict';
  const GP = (window.GoPray = window.GoPray || { scenes: {} });
  const VW = 1600, VH = 1000; // every scene is drawn in this virtual space, then "cover"-fitted

  // ---------- random ----------
  function rng(seed) {
    let a = seed >>> 0;
    const r = function () {
      a = (a + 0x6d2b79f5) >>> 0;
      let t = a;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
    r.gauss = () => {
      let u = 0, v = 0;
      while (!u) u = r();
      while (!v) v = r();
      return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
    };
    r.range = (lo, hi) => lo + (hi - lo) * r();
    return r;
  }

  // value noise (for the bloom front and mottling)
  function hash2(x, y, s) {
    let h = (x * 374761393 + y * 668265263 + s * 2147483647) | 0;
    h = Math.imul(h ^ (h >>> 13), 1274126177);
    return ((h ^ (h >>> 16)) >>> 0) / 4294967296;
  }
  function vnoise(x, y, s) {
    const xi = Math.floor(x), yi = Math.floor(y), xf = x - xi, yf = y - yi;
    const u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf);
    const a = hash2(xi, yi, s), b = hash2(xi + 1, yi, s), c = hash2(xi, yi + 1, s), d = hash2(xi + 1, yi + 1, s);
    return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v;
  }
  function fbm(x, y, s, oct = 4) {
    let f = 0, amp = 0.5, fr = 1, norm = 0;
    for (let i = 0; i < oct; i++) { f += amp * vnoise(x * fr, y * fr, s + i * 17); norm += amp; amp *= 0.5; fr *= 2.03; }
    return f / norm;
  }

  // ---------- colour (derives tints from tokens; never introduces new hues) ----------
  function parse(c) {
    c = String(c).trim();
    if (c[0] === '#') {
      let h = c.slice(1);
      if (h.length === 3) h = h.split('').map((x) => x + x).join('');
      const n = parseInt(h.slice(0, 6), 16);
      return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
    }
    const m = c.match(/[\d.]+/g);
    return m ? m.slice(0, 3).map(Number) : [0, 0, 0];
  }
  const rgba = (c, a) => { const [r, g, b] = parse(c); return `rgba(${r},${g},${b},${a})`; };
  const mix = (c1, c2, t) => { const a = parse(c1), b = parse(c2); return 'rgb(' + a.map((v, i) => Math.round(v + (b[i] - v) * t)).join(',') + ')'; };
  function lum(c) {
    const s = parse(c).map((v) => { v /= 255; return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
    return 0.2126 * s[0] + 0.7152 * s[1] + 0.0722 * s[2];
  }
  const contrast = (a, b) => { const x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); };

  const TOKEN_NAMES = ['ground', 'sky-1', 'sky-2', 'sky-3', 'stone-1', 'stone-2', 'stone-3', 'deep', 'accent-1', 'accent-2', 'glow', 'ink', 'text', 'ring'];
  function tokens(el) {
    const cs = getComputedStyle(el), T = {};
    TOKEN_NAMES.forEach((n) => { T[n.replace('-', '')] = cs.getPropertyValue('--' + n).trim(); });
    return T;
  }

  // ---------- geometry ----------
  const G = {
    arc(cx, cy, rx, ry, a0, a1, n = 24) {
      const p = [];
      for (let i = 0; i <= n; i++) { const a = a0 + ((a1 - a0) * i) / n; p.push([cx + rx * Math.cos(a), cy + ry * Math.sin(a)]); }
      return p;
    },
    ellipse(cx, cy, rx, ry, n = 48) { return G.arc(cx, cy, rx, ry, 0, Math.PI * 2, n).slice(0, -1); },
    rect(x, y, w, h) { return [[x, y], [x + w, y], [x + w, y + h], [x, y + h]]; },
    bez(p0, p1, p2, p3, n = 20) {
      const p = [];
      for (let i = 0; i <= n; i++) {
        const t = i / n, u = 1 - t;
        p.push([
          u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
          u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1],
        ]);
      }
      return p;
    },
    // a solid of revolution from a profile [[halfWidth, y], ...] listed top → bottom
    lathe(cx, prof) {
      const r = prof.map(([w, y]) => [cx + w, y]);
      const l = prof.slice().reverse().map(([w, y]) => [cx - w, y]);
      return r.concat(l);
    },
    // ogival (pointed) arch line from left spring to right spring
    pointed(x0, x1, ySpring, yApex, n = 18, sharp = 0.35) {
      const xm = (x0 + x1) / 2, h = ySpring - yApex;
      const left = G.bez([x0, ySpring], [x0, ySpring - h * 0.62], [xm - (xm - x0) * sharp, yApex + h * 0.08], [xm, yApex], n);
      const right = G.bez([xm, yApex], [xm + (x1 - xm) * sharp, yApex + h * 0.08], [x1, ySpring - h * 0.62], [x1, ySpring], n);
      return left.concat(right.slice(1));
    },
    // cusped (multifoil) version of any arch line: lobes bite inward toward (cx, cy)
    cusped(line, lobes, depth, cx, cy) {
      return line.map(([x, y], i) => {
        const t = i / (line.length - 1);
        const f = (t * lobes) % 1;
        const off = depth * (1 - Math.sin(Math.PI * f));
        const dx = cx - x, dy = cy - y, d = Math.hypot(dx, dy) || 1;
        return [x + (dx / d) * off, y + (dy / d) * off];
      });
    },
    // a horizontal ring on a cylinder seen from below: the front bows upward
    band(cx, y, hw, bow = 0, n = 16) {
      const p = [];
      for (let i = 0; i <= n; i++) { const a = -Math.PI / 2 + (Math.PI * i) / n; p.push([cx + hw * Math.sin(a), y - bow * Math.cos(a)]); }
      return p;
    },
    star8(cx, cy, r, r2 = r * 0.72) {
      const p = [];
      for (let i = 0; i < 16; i++) { const a = (Math.PI * i) / 8 - Math.PI / 2; const rr = i % 2 ? r2 : r; p.push([cx + rr * Math.cos(a), cy + rr * Math.sin(a)]); }
      return p;
    },
    centroid(pts) { let x = 0, y = 0; pts.forEach((p) => { x += p[0]; y += p[1]; }); return [x / pts.length, y / pts.length]; },
  };

  // Hobbs deformation: recursive midpoint displacement; sigma is relative to the edge
  // length but capped by an absolute spread so architecture stays architecture.
  function deform(pts, depth, variance, spread, R) {
    let p = pts.map((q) => ({ x: q[0] !== undefined ? q[0] : q.x, y: q[1] !== undefined ? q[1] : q.y, v: q.v || R.range(0.6, 1.4) }));
    for (let d = 0; d < depth; d++) {
      const out = [];
      for (let i = 0; i < p.length; i++) {
        const a = p[i], b = p[(i + 1) % p.length];
        out.push(a);
        const len = Math.hypot(b.x - a.x, b.y - a.y);
        const t = Math.min(0.8, Math.max(0.2, 0.5 + R.gauss() * 0.1));
        const sig = Math.min(len * variance, spread) * ((a.v + b.v) / 2);
        out.push({ x: a.x + (b.x - a.x) * t + R.gauss() * sig, y: a.y + (b.y - a.y) * t + R.gauss() * sig, v: ((a.v + b.v) / 2) * R.range(0.7, 1.15) });
      }
      p = out;
    }
    return p;
  }

  // Chaikin corner cutting: turns the deformed polygon's spikes into soft, wet edges
  function chaikin(p, n = 1) {
    for (let k = 0; k < n; k++) {
      const out = [];
      for (let i = 0; i < p.length; i++) {
        const a = p[i], b = p[(i + 1) % p.length];
        out.push({ x: a.x * 0.75 + b.x * 0.25, y: a.y * 0.75 + b.y * 0.25, v: a.v });
        out.push({ x: a.x * 0.25 + b.x * 0.75, y: a.y * 0.25 + b.y * 0.75, v: b.v });
      }
      p = out;
    }
    return p;
  }

  function trace(ctx, p, closed = true) {
    ctx.beginPath();
    const x0 = p[0].x !== undefined ? p[0].x : p[0][0], y0 = p[0].y !== undefined ? p[0].y : p[0][1];
    ctx.moveTo(x0, y0);
    for (let i = 1; i < p.length; i++) ctx.lineTo(p[i].x !== undefined ? p[i].x : p[i][0], p[i].y !== undefined ? p[i].y : p[i][1]);
    if (closed) ctx.closePath();
  }

  // ---------- painter (bound to one canvas, virtual coordinates) ----------
  function Painter(canvas, T, seed, view) {
    const ctx = canvas.getContext('2d');
    const k = view.s * view.pr;
    ctx.setTransform(k, 0, 0, k, view.ox * view.pr, view.oy * view.pr);
    const R = rng(seed);
    const px = 1 / k; // one device pixel, in virtual units

    const P = {
      ctx, T, R, G, rgba, mix, px, VW, VH, fbm,
      // one watercolor wash: many translucent, slightly different layers of one deformed shape
      wash(pts, color, o = {}) {
        const layers = o.layers || 14;
        const a = 1 - Math.pow(1 - (o.opacity === undefined ? 0.85 : o.opacity), 1 / layers);
        const v = o.variance === undefined ? 0.16 : o.variance;
        const sp = o.spread === undefined ? 3 : o.spread;
        const base = deform(pts, o.depth === undefined ? 3 : o.depth, v, sp, R);
        ctx.save();
        ctx.globalCompositeOperation = o.blend || 'source-over';
        ctx.fillStyle = color;
        ctx.strokeStyle = o.edgeColor || color;
        ctx.lineWidth = (o.edgeW || 1.3) * px;
        ctx.lineJoin = 'round';
        const edge = o.edge === undefined ? 0.6 : o.edge;
        for (let i = 0; i < layers; i++) {
          const p = chaikin(deform(base, o.layerDepth === undefined ? 2 : o.layerDepth, v * 0.6, sp * 0.45, R), o.smooth === undefined ? 2 : o.smooth);
          trace(ctx, p);
          ctx.globalAlpha = a;
          ctx.fill();
          if (edge) { ctx.globalAlpha = a * edge; ctx.stroke(); }
        }
        ctx.restore();
      },
      // a flat, controlled fill (for crisp small parts that a wash would smear)
      fill(pts, color, alpha = 1, blend) {
        ctx.save();
        if (blend) ctx.globalCompositeOperation = blend;
        ctx.globalAlpha = alpha;
        ctx.fillStyle = color;
        trace(ctx, pts);
        ctx.fill();
        ctx.restore();
      },
      glow(x, y, r, color, a = 1, blend = 'screen', ry) {
        ctx.save();
        ctx.globalCompositeOperation = blend;
        ctx.globalAlpha = a;
        ctx.translate(x, y);
        if (ry) ctx.scale(1, ry / r);
        const g = ctx.createRadialGradient(0, 0, 0, 0, 0, r);
        g.addColorStop(0, color);
        g.addColorStop(0.35, rgba(color, 0.45));
        g.addColorStop(1, rgba(color, 0));
        ctx.fillStyle = g;
        ctx.fillRect(-r, -r, r * 2, r * 2);
        ctx.restore();
      },
      lin(x0, y0, x1, y1, stops) {
        const g = ctx.createLinearGradient(x0, y0, x1, y1);
        stops.forEach(([t, c]) => g.addColorStop(t, c));
        return g;
      },
      clip(pts, fn) {
        ctx.save();
        trace(ctx, pts);
        ctx.clip();
        fn();
        ctx.restore();
      },
      // wet-in-wet: paint into a scratch canvas, then lay it down blurred (edges bleed).
      // Runs once at paint time, never per frame.
      wet(blur, fn, o = {}) {
        // pad the scratch canvas so the blur has paint to pull from past the frame edge
        const pad = Math.ceil(blur * k * 2.5);
        const tmp = document.createElement('canvas');
        tmp.width = canvas.width + pad * 2; tmp.height = canvas.height + pad * 2;
        const sub = Painter(tmp, T, Math.floor(R() * 1e9), { s: view.s, pr: view.pr, ox: view.ox + pad / view.pr, oy: view.oy + pad / view.pr });
        fn(sub);
        ctx.save();
        ctx.setTransform(1, 0, 0, 1, 0, 0);
        ctx.globalAlpha = o.alpha === undefined ? 1 : o.alpha;
        if (o.blend) ctx.globalCompositeOperation = o.blend;
        if ('filter' in ctx) ctx.filter = `blur(${(blur * k).toFixed(1)}px)`;
        ctx.drawImage(tmp, -pad, -pad);
        ctx.restore();
      },
      // flecks of pigment / tiny lights
      dot(x, y, r, color, a = 1, blend) {
        ctx.save();
        if (blend) ctx.globalCompositeOperation = blend;
        ctx.globalAlpha = a;
        ctx.fillStyle = color;
        ctx.beginPath();
        ctx.arc(x, y, r, 0, Math.PI * 2);
        ctx.fill();
        ctx.restore();
      },
    };
    return P;
  }

  // ---------- granulation + paper tooth (baked once per layer) ----------
  function noiseCanvas(w, h, seed, mean, spread) {
    const c = document.createElement('canvas');
    c.width = w; c.height = h;
    const x = c.getContext('2d'), img = x.createImageData(w, h), R = rng(seed);
    for (let i = 0; i < img.data.length; i += 4) {
      const v = Math.max(0, Math.min(255, mean + (R() - 0.5) * 2 * spread));
      img.data[i] = img.data[i + 1] = img.data[i + 2] = v;
      img.data[i + 3] = 255;
    }
    x.putImageData(img, 0, 0);
    return c;
  }
  function grain(canvas, seed, o = {}) {
    const w = canvas.width, h = canvas.height;
    const tmp = document.createElement('canvas');
    tmp.width = w; tmp.height = h;
    const t = tmp.getContext('2d');
    t.drawImage(canvas, 0, 0);
    t.imageSmoothingEnabled = true;
    t.imageSmoothingQuality = 'high';
    // mottling: pigment settles unevenly (two soft octaves)
    const big = noiseCanvas(Math.ceil(w / 140), Math.ceil(h / 140), seed, 128, 110);
    const mid = noiseCanvas(Math.ceil(w / 26), Math.ceil(h / 26), seed + 1, 128, 90);
    t.globalCompositeOperation = 'soft-light';
    t.globalAlpha = o.mottle === undefined ? 0.32 : o.mottle;
    t.drawImage(big, 0, 0, w, h);
    t.globalAlpha = (o.mottle === undefined ? 0.32 : o.mottle) * 0.6;
    t.drawImage(mid, 0, 0, w, h);
    // granulation + paper tooth: per-pixel speckle
    const fine = noiseCanvas(256, 256, seed + 2, 128, 70);
    t.globalAlpha = o.tooth === undefined ? 0.14 : o.tooth;
    t.fillStyle = t.createPattern(fine, 'repeat');
    t.fillRect(0, 0, w, h);
    // keep the layer's own alpha (transparent layers stay transparent)
    t.globalAlpha = 1;
    t.globalCompositeOperation = 'destination-in';
    t.drawImage(canvas, 0, 0);
    const c = canvas.getContext('2d');
    c.save();
    c.setTransform(1, 0, 0, 1, 0, 0);
    c.clearRect(0, 0, w, h);
    c.drawImage(tmp, 0, 0);
    c.restore();
  }

  // ---------- ink (SVG) ----------
  function Ink(R, focal) {
    const parts = [];
    const f = (n) => n.toFixed(1);
    function jitter(pts, j) {
      if (!j) return pts;
      return pts.map(([x, y], i) => (i === 0 || i === pts.length - 1 ? [x, y] : [x + R.gauss() * j, y + R.gauss() * j]));
    }
    function inside(x, y, poly) {
      let c = false;
      for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
        const xi = poly[i][0], yi = poly[i][1], xj = poly[j][0], yj = poly[j][1];
        if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) c = !c;
      }
      return c;
    }
    function densify(pts, step) {
      const out = [pts[0]];
      for (let i = 1; i < pts.length; i++) {
        const [x0, y0] = pts[i - 1], [x1, y1] = pts[i];
        const n = Math.max(1, Math.ceil(Math.hypot(x1 - x0, y1 - y0) / step));
        for (let k = 1; k <= n; k++) out.push([x0 + ((x1 - x0) * k) / n, y0 + ((y1 - y0) * k) / n]);
      }
      return out;
    }
    const K = {
      // a hand-drawn line; draws in by distance from the scene's focal point.
      // o.behind: polygons that hide this line (it is split where it passes behind them)
      line(pts, o = {}) {
        if (o.behind) {
          let src = densify(o.closed ? pts.concat([pts[0]]) : pts, 3);
          let run = [];
          const flush = () => { if (run.length > 1) K.line(run, Object.assign({}, o, { behind: null, closed: false })); run = []; };
          src.forEach((q) => { if (o.behind.some((poly) => inside(q[0], q[1], poly))) flush(); else run.push(q); });
          flush();
          return;
        }
        const p = jitter(pts, o.jitter === undefined ? 0.35 : o.jitter);
        let d = 'M' + f(p[0][0]) + ' ' + f(p[0][1]);
        for (let i = 1; i < p.length; i++) d += 'L' + f(p[i][0]) + ' ' + f(p[i][1]);
        if (o.closed) d += 'Z';
        const c = G.centroid(pts);
        const dist = Math.min(1, Math.hypot(c[0] - focal[0], c[1] - focal[1]) / 1400);
        const attrs = [`d="${d}"`, 'pathLength="1"', `style="--d:${dist.toFixed(3)}"`, `stroke-width="${o.w || 1.1}"`];
        if (o.o !== undefined) attrs.push(`stroke-opacity="${o.o}"`);
        if (o.color) attrs.push(`stroke="${o.color}"`);
        parts.push(`<path ${attrs.join(' ')}/>`);
      },
      toString() { return parts.join(''); },
      inside,
    };
    return K;
  }

  // ---------- the bloom: wet paint spreading from the focal point ----------
  function revealMap(w, h, focal, seed) {
    const m = new Float32Array(w * h);
    const fx = focal[0] * w, fy = focal[1] * h;
    const maxD = Math.hypot(Math.max(fx, w - fx), Math.max(fy, h - fy));
    let lo = Infinity, hi = -Infinity;
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const d = Math.hypot(x - fx, (y - fy) * 1.2) / maxD;
        const n = fbm(x / 9, y / 9, seed, 4);
        const v = d * 0.7 + n * 0.42;
        m[y * w + x] = v;
        if (v < lo) lo = v;
        if (v > hi) hi = v;
      }
    }
    for (let i = 0; i < m.length; i++) m[i] = (m[i] - lo) / (hi - lo);
    return m;
  }

  // ---------- stage ----------
  const EASE_BLOOM = (t) => 1 - Math.pow(1 - t, 2.4); // spreads fast, then soaks in slowly
  const BLOOM_MS = 2500;

  function Stage(host) {
    this.host = host;
    this.run = 0;
  }

  Stage.prototype.view = function () {
    const w = this.host.clientWidth, h = this.host.clientHeight;
    const s = Math.max(w / VW, h / VH);
    return { w, h, s, ox: (w - VW * s) / 2, oy: (h - VH * s) / 2, pr: Math.min(window.devicePixelRatio || 1, 2) };
  };

  Stage.prototype.stop = function () {
    this.run++;
    if (this.loop) this.loop.stop();
    this.loop = null;
  };

  // opts: { reduce, durationMs, onBloomed }
  Stage.prototype.show = function (id, opts) {
    this.stop();
    const run = this.run;
    const scene = GP.scenes[id];
    const host = this.host;
    host.innerHTML = '';
    host.dataset.state = 'painting';
    const v = this.view();
    const T = tokens(host);
    host.style.setProperty('--block-ms', opts.durationMs + 'ms');
    const t0 = performance.now();

    // static layers
    const made = scene.layers.map((L, i) => {
      const c = document.createElement('canvas');
      c.className = 'scene-layer layer-' + L.id;
      c.width = Math.round(v.w * v.pr);
      c.height = Math.round(v.h * v.pr);
      const src = document.createElement('canvas');
      src.width = c.width; src.height = c.height;
      const P = Painter(src, T, scene.seed + i * 101, v);
      L.paint(P);
      if (L.grain !== false) grain(src, scene.seed + i, L.grain || {});
      if (L.origin) c.style.transformOrigin = `${v.ox + L.origin[0] * v.s}px ${v.oy + L.origin[1] * v.s}px`;
      host.appendChild(c);
      return { L, c, src };
    });

    // ink
    const svgNS = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(svgNS, 'svg');
    svg.setAttribute('class', 'scene-ink');
    svg.setAttribute('viewBox', `0 0 ${VW} ${VH}`);
    svg.setAttribute('preserveAspectRatio', 'xMidYMid slice');
    svg.setAttribute('aria-hidden', 'true');
    const K = Ink(rng(scene.seed + 7), scene.focal);
    scene.ink(K, T, G);
    svg.innerHTML =
      '<defs><filter id="ink-wobble" x="-5%" y="-5%" width="110%" height="110%">' +
      '<feTurbulence type="fractalNoise" baseFrequency="0.045" numOctaves="2" seed="4"/>' +
      '<feDisplacementMap in="SourceGraphic" scale="2.4" xChannelSelector="R" yChannelSelector="G"/></filter></defs>' +
      `<g filter="url(#ink-wobble)" stroke="${T.ink}" fill="none" stroke-linecap="round" stroke-linejoin="round">${K}</g>`;
    host.appendChild(svg);

    // live layer
    const live = document.createElement('canvas');
    live.className = 'scene-live';
    live.width = Math.round(v.w * v.pr);
    live.height = Math.round(v.h * v.pr);
    host.appendChild(live);
    const lctx = live.getContext('2d');
    const liveScene = scene.live ? scene.live({ T, G, rgba, mix, rng, fbm, durationMs: opts.durationMs, px: 1 / (v.s * v.pr) }) : null;
    const drawLive = (t, dt) => {
      lctx.setTransform(1, 0, 0, 1, 0, 0);
      lctx.clearRect(0, 0, live.width, live.height);
      lctx.setTransform(v.s * v.pr, 0, 0, v.s * v.pr, v.ox * v.pr, v.oy * v.pr);
      liveScene.draw(lctx, t, dt);
    };

    this.paintMs = performance.now() - t0;

    const finish = () => {
      made.forEach((m) => {
        const x = m.c.getContext('2d');
        x.clearRect(0, 0, m.c.width, m.c.height);
        x.drawImage(m.src, 0, 0);
        m.src = null;
      });
      host.dataset.state = opts.reduce ? 'still' : 'lived';
      if (liveScene) {
        if (opts.reduce) drawLive(0, 0); // frozen: one still frame
        else {
          this.loop = Loop(drawLive);
          this.loop.start();
        }
      }
      if (opts.onBloomed) opts.onBloomed();
    };

    if (opts.reduce) {
      host.dataset.state = 'still';
      requestAnimationFrame(() => { if (run === this.run) finish(); });
      return;
    }

    // bloom
    const mw = Math.max(32, Math.round(v.w / 10)), mh = Math.max(20, Math.round(v.h / 10));
    const fx = (v.ox + scene.focal[0] * v.s) / v.w, fy = (v.oy + scene.focal[1] * v.s) / v.h;
    const map = revealMap(mw, mh, [fx, fy], scene.seed);
    const mask = document.createElement('canvas');
    mask.width = mw; mask.height = mh;
    const mx = mask.getContext('2d');
    const img = mx.createImageData(mw, mh);
    for (let i = 0; i < img.data.length; i += 4) img.data[i] = img.data[i + 1] = img.data[i + 2] = 255;
    host.dataset.state = 'blooming';
    const start = performance.now();
    const frame = (now) => {
      if (run !== this.run) return;
      const t = Math.min(1, (now - start) / BLOOM_MS);
      const p = EASE_BLOOM(t) * 1.22;
      for (let i = 0, j = 3; i < map.length; i++, j += 4) {
        const a = (p - map[i]) / 0.22;
        img.data[j] = a <= 0 ? 0 : a >= 1 ? 255 : (a * a * (3 - 2 * a) * 255) | 0;
      }
      mx.putImageData(img, 0, 0);
      made.forEach((m) => {
        if (m.L.bloom === false) return;
        const x = m.c.getContext('2d');
        x.globalCompositeOperation = 'source-over';
        x.clearRect(0, 0, m.c.width, m.c.height);
        x.drawImage(m.src, 0, 0);
        x.globalCompositeOperation = 'destination-in';
        x.imageSmoothingQuality = 'high';
        x.drawImage(mask, 0, 0, m.c.width, m.c.height);
        x.globalCompositeOperation = 'source-over';
      });
      if (t > 0.18 && !host.classList.contains('is-inked')) host.classList.add('is-inked');
      if (t < 1) requestAnimationFrame(frame);
      else finish();
    };
    // let the ground colour paint first (it is the skeleton), then bloom
    requestAnimationFrame(() => {
      made.forEach((m) => {
        if (m.L.bloom === false) m.c.getContext('2d').drawImage(m.src, 0, 0);
      });
      requestAnimationFrame(frame);
    });
  };

  // 30fps cap; stops while the page is hidden
  function Loop(draw) {
    let raf = 0, last = 0, on = false, hidden = document.hidden;
    const step = (now) => {
      raf = requestAnimationFrame(step);
      if (now - last < 1000 / 30 - 1) return;
      const dt = last ? Math.min(0.1, (now - last) / 1000) : 1 / 30;
      last = now;
      const t0 = performance.now();
      draw(now / 1000, dt);
      L.frameMs = L.frameMs * 0.95 + (performance.now() - t0) * 0.05;
    };
    const vis = () => {
      hidden = document.hidden;
      if (hidden) { cancelAnimationFrame(raf); raf = 0; }
      else if (on && !raf) { last = 0; raf = requestAnimationFrame(step); }
    };
    const L = {
      frameMs: 0,
      start() { on = true; document.addEventListener('visibilitychange', vis); if (!hidden) raf = requestAnimationFrame(step); },
      stop() { on = false; cancelAnimationFrame(raf); raf = 0; document.removeEventListener('visibilitychange', vis); },
    };
    return L;
  }

  GP.wc = { rng, fbm, vnoise, parse, rgba, mix, lum, contrast, tokens, G, deform, VW, VH };
  GP.Stage = Stage;
})();
