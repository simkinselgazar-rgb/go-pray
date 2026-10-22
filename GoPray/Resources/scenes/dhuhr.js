/* Dhuhr — clear midday sky, the green dome of Masjid an-Nabawi, the cream minaret with its
   brass finial, and a dove crossing slowly. Reference: "Zuhur Prayer Inspiration.png". */
(function () {
  'use strict';
  const GP = window.GoPray;
  const { G, mix, rgba } = GP.wc;

  const MX = 1050; // minaret axis
  const DX = 1236; // dome axis (the photo puts the minaret ~0.36 dome-widths left of the apex)
  const K_M = 1.09; // minaret scale against its photo-traced profile
  const my = (y) => 40 + (y - 40) * K_M;
  const mw = (w) => w * K_M;

  // minaret, top → bottom, [half-width, y], traced from the photo
  const onionRaw = [];
  for (let i = 0; i <= 12; i++) {
    const t = i / 12;
    onionRaw.push([Math.max(2.5, 21 * Math.pow(Math.sin(Math.PI * t), 0.85)), 148 + 86 * t]);
  }
  const sc = ([w, y]) => [mw(w), my(y)];
  const ONION = onionRaw.map(sc);
  const MINARET = onionRaw.concat([
    [9, 236], [9, 246], [26, 318], [36, 318], [36, 348], [31, 348], [31, 412], [50, 424], [53, 424], [53, 454],
    [47, 470], [44, 470], [44, 508], [45, 508], [45, 624], [50, 624], [56, 632], [56, 660], [50, 668], [48, 668], [48, 880],
  ]).map(sc);

  // the dome: height ≈ 1.25 × half-width, like the real one — a bullet, not a bowl
  const APEX = 604;
  const DOME_CURVE = G.bez([0, APEX], [64, APEX], [236, 668], [240, 880], 30);
  const DOME_PROF = DOME_CURVE.concat([[240, 890], [247, 890], [247, 904], [252, 904], [252, 1060]]);
  const DOME = G.lathe(DX, DOME_PROF);
  const DR = 252; // drum radius

  const deg = (a) => (a * Math.PI) / 180;

  function crescent(cx, cy, r) {
    const outer = G.arc(cx, cy, r, r, -0.12 * Math.PI, 1.12 * Math.PI, 22);
    const inner = G.arc(cx, cy - r * 0.32, r * 0.8, r * 0.78, 1.05 * Math.PI, -0.05 * Math.PI, 22);
    return outer.concat(inner);
  }

  function finial(P, x, yTop, yBase, balls) {
    const { T } = P;
    const lit = mix(T.accent2, T.glow, 0.5), shade = mix(T.accent2, T.deep, 0.35);
    P.fill(G.rect(x - 1.6, yTop, 3.2, yBase - yTop), T.accent2);
    balls.forEach(([y, r]) => {
      P.fill(G.ellipse(x, y, r, r * 0.9, 20), T.accent2);
      P.fill(G.arc(x, y, r, r * 0.9, -0.2, 1.4, 10).concat([[x + r * 0.15, y]]), shade, 0.55);
      P.fill(G.ellipse(x - r * 0.32, y - r * 0.28, r * 0.42, r * 0.36, 12), lit, 0.9);
    });
  }

  function paintSky(P) {
    const { T, ctx } = P;
    ctx.fillStyle = T.ground;
    ctx.fillRect(-60, -60, 1720, 1120);
    // graded wash, wet-in-wet: deep blue at the top, thinning toward the horizon
    P.wet(12, (W) => {
      W.ctx.fillStyle = W.lin(0, -40, 0, 1000, [[0, rgba(T.sky1, 0.95)], [0.42, rgba(mix(T.sky1, T.sky2, 0.45), 0.74)], [0.78, rgba(T.sky2, 0.5)], [1, rgba(T.sky3, 0.42)]]);
      W.ctx.fillRect(-60, -60, 1720, 1120);
      // heavier pigment where the brush was loaded
      [[260, 30, 460, 110], [1050, 60, 420, 120], [1520, 200, 260, 160]].forEach(([x, y, rx, ry]) =>
        W.wash(G.ellipse(x, y, rx, ry, 18), T.sky1, { opacity: 0.3, layers: 10, variance: 0.25, spread: 40 }));
    });
    // lift the paint where the words sit (a damp tissue on wet paper)
    P.wet(70, (W) => W.wash(G.ellipse(330, 540, 300, 330, 24), T.ground, { opacity: 0.6, layers: 10, variance: 0.2, spread: 40, edge: 0 }));
    // broad strokes laid on the dry sky: hard, slightly darker edges so it reads as paint
    P.wet(0.8, (W) => {
      [
        [[640, 70], [980, 40], [1380, 70], [1700, 40], [1700, 150], [1380, 170], [1000, 150], [700, 140]],
        [[1100, 250], [1350, 228], [1700, 250], [1700, 320], [1400, 330], [1150, 300]],
        [[-60, 40], [300, 20], [560, 60], [520, 110], [200, 120], [-60, 110]],
      ].forEach((pts, i) => W.wash(pts, T.sky1, { opacity: [0.2, 0.14, 0.16][i], layers: 9, variance: 0.12, spread: 16, edge: 1.8, smooth: 3 }));
    });
  }

  function paintArch(P) {
    const { T } = P;
    const body = G.lathe(MX, MINARET);

    // minaret: cream stone, lit from the left
    P.wash(body, T.stone1, { opacity: 0.97, layers: 10, variance: 0.03, spread: 1, edge: 0.35, smooth: 1 });
    P.clip(body, () => {
      const right = MINARET.map(([w, y]) => [MX + w + 6, y]).concat(MINARET.slice().reverse().map(([w, y]) => [MX - w * 0.1, y]));
      P.wash(right, T.stone2, { opacity: 0.7, layers: 12, variance: 0.1, spread: 7 });
      const edge = MINARET.map(([w, y]) => [MX + w + 6, y]).concat(MINARET.slice().reverse().map(([w, y]) => [MX + w * 0.6, y]));
      P.wash(edge, T.stone3, { opacity: 0.42, layers: 10, variance: 0.1, spread: 5 });
      // shadow under the crown and both balconies
      [[348, 364], [470, 494], [668, 694]].forEach(([y0, y1]) =>
        P.wash(G.rect(MX - 70, my(y0), 140, my(y1) - my(y0)), T.stone3, { opacity: 0.42, layers: 8, variance: 0.08, spread: 4 }));
      // the tall niches
      [-30, 0, 30].forEach((dx, i) => {
        const x0 = MX + mw(dx - 9), x1 = MX + mw(dx + 9);
        const niche = G.pointed(x0, x1, my(536), my(514), 8, 0.2).concat([[x1, my(612)], [x0, my(612)]]);
        P.wash(niche, i === 2 ? T.stone3 : mix(T.stone2, T.stone3, 0.55), { opacity: 0.78, layers: 6, variance: 0.04, spread: 1.2, smooth: 1 });
      });
      // carved rosettes round both balconies
      [[439, 53], [646, 56]].forEach(([y, hw]) => {
        for (let a = -66; a <= 66; a += 22) {
          const s = Math.sin(deg(a)), c = Math.cos(deg(a));
          const x = MX + mw(hw) * s;
          P.fill(G.rect(x - 4.4 * c, my(y) - 4.8, 8.8 * c, 9.6), mix(T.stone3, T.deep, 0.15), 0.55);
          P.dot(x, my(y), 1.7 * c, T.stone1, 0.85);
        }
      });
    });
    // the crown of small leaves
    for (let a = -80; a <= 80; a += 13) {
      const s = Math.sin(deg(a)), c = Math.cos(deg(a));
      const x = MX + mw(36) * s;
      P.fill([[x - 4.4 * c, my(320)], [x, my(305)], [x + 4.4 * c, my(320)]], a > 20 ? T.stone2 : T.stone1, 0.95);
    }
    // brass finial with its crescent
    finial(P, MX, my(62), my(150), [[my(76), 4.8], [my(94), 7.4], [my(116), 10], [my(137), 6.4]]);
    P.fill(crescent(MX, my(50), 13), T.accent2);
    P.fill(crescent(MX - 2, my(49), 9.5), mix(T.accent2, T.glow, 0.45), 0.6);

    // the green dome
    P.wash(DOME, T.accent1, { opacity: 0.97, layers: 12, variance: 0.03, spread: 1.2, edge: 0.5, smooth: 1 });
    P.clip(DOME, () => {
      // light from the upper left; the right flank and the drum fall into shade (modelled wet-in-wet)
      P.wet(16, (W) => {
        W.wash([[DX - 190, 660], [DX - 30, 615], [DX + 20, 740], [DX - 110, 860], [DX - 240, 840]], mix(T.accent1, T.glow, 0.45),
          { opacity: 0.55, layers: 12, variance: 0.18, spread: 26 });
        W.wash([[DX + 110, 640], [DX + 280, 660], [DX + 280, 1060], [DX + 150, 1060], [DX + 170, 820]], mix(T.accent1, T.deep, 0.55),
          { opacity: 0.6, layers: 12, variance: 0.18, spread: 24 });
      });
      P.wash(G.rect(DX - 280, 904, 560, 200), mix(T.accent1, T.deep, 0.35), { opacity: 0.45, layers: 10, variance: 0.1, spread: 8 });
      P.wash(G.rect(DX - 280, 876, 560, 14), mix(T.accent1, T.deep, 0.6), { opacity: 0.55, layers: 8, variance: 0.1, spread: 3 });
      // the seams between the ribs, a little darker
      for (let a = -78; a <= 78; a += 12) {
        const s = Math.sin(deg(a));
        const rib = DOME_CURVE.map(([w, y]) => [DX + w * s + 2.2, y]).concat(DOME_CURVE.slice().reverse().map(([w, y]) => [DX + w * s - 2.2, y]));
        P.fill(rib, mix(T.accent1, T.deep, 0.5), 0.2);
      }
      // a row of little blind arches round the drum
      for (let a = -84; a <= 84; a += 9) {
        const s = Math.sin(deg(a)), c = Math.cos(deg(a));
        const x = DX + DR * s, w = 7.5 * c;
        P.fill(G.arc(x, 928, w, 8, Math.PI, 2 * Math.PI, 8).concat([[x + w, 960], [x - w, 960]]), T.deep, 0.45);
      }
    });
    // finial on the dome
    const base = [[6, APEX - 36], [10, APEX - 28], [17, APEX - 16], [23, APEX + 2]];
    P.fill(G.lathe(DX, base), T.accent2);
    P.fill(G.lathe(DX - 5, base.map(([w, y]) => [w * 0.4, y])), mix(T.accent2, T.glow, 0.5), 0.85);
    finial(P, DX, APEX - 120, APEX - 34, [[APEX - 54, 8.5], [APEX - 74, 7], [APEX - 92, 5.5]]);
    P.fill(crescent(DX, APEX - 112, 7.5), T.accent2);
  }

  function ink(K) {
    const hide = [DOME];
    const L = (pts, o) => K.line(pts, Object.assign({ behind: hide, w: 1.05, o: 0.7 }, o));
    // minaret contour
    L(MINARET.map(([w, y]) => [MX - w, y]));
    L(MINARET.map(([w, y]) => [MX + w, y]));
    // bands and ledges bow a little: we look up at them
    [[318, 36], [348, 36], [412, 31], [424, 53], [454, 53], [470, 47], [508, 45], [624, 50], [632, 56], [660, 56], [668, 50]].forEach(([y, hw]) =>
      L(G.band(MX, my(y), mw(hw), 3), { w: 0.85, o: 0.58 }));
    L(G.band(MX, my(246), mw(9), 1), { w: 0.7, o: 0.5 });
    for (let a = -60; a <= 60; a += 20) {
      const x = MX + mw(31) * Math.sin(deg(a));
      L([[x, my(354)], [x, my(406)]], { w: 0.6, o: 0.38 });
    }
    const crown = [];
    for (let a = -80; a <= 80; a += 13) {
      const s = Math.sin(deg(a)), c = Math.cos(deg(a));
      const x = MX + mw(36) * s;
      crown.push([x - 4.4 * c, my(320)], [x, my(305)]);
    }
    L(crown, { w: 0.7, o: 0.5 });
    [-30, 0, 30].forEach((dx) => {
      const x0 = MX + mw(dx - 9), x1 = MX + mw(dx + 9);
      L([[x0, my(612)]].concat(G.pointed(x0, x1, my(536), my(514), 8, 0.2), [[x1, my(612)]]), { w: 0.75, o: 0.55 });
    });
    L(ONION.map(([w, y]) => [MX - w, y]).concat(ONION.slice().reverse().map(([w, y]) => [MX + w, y])), { w: 0.8, o: 0.55 });

    // dome contour, seams, bands
    const half = DOME_CURVE.length;
    const outline = G.lathe(DX, DOME_CURVE);
    K.line(outline.slice(0, half), { w: 1.2, o: 0.72 });
    K.line(outline.slice(half), { w: 1.2, o: 0.72 });
    for (let a = -78; a <= 78; a += 12) {
      const s = Math.sin(deg(a));
      K.line(DOME_CURVE.filter((_, i) => i > 2).map(([w, y]) => [DX + w * s, y]), { w: 0.55, o: 0.34 });
    }
    [[890, 247, 4], [904, 252, 4], [966, 252, 5]].forEach(([y, hw, bow]) => K.line(G.band(DX, y, hw, bow, 24), { w: 0.8, o: 0.5 }));
    for (let a = -84; a <= 84; a += 9) {
      const s = Math.sin(deg(a)), c = Math.cos(deg(a));
      const x = DX + DR * s, w = 7.5 * c;
      K.line([[x - w, 960]].concat(G.arc(x, 928, w, 8, Math.PI, 2 * Math.PI, 8), [[x + w, 960]]), { w: 0.5, o: 0.38, jitter: 0.12 });
    }
    K.line(G.lathe(DX, [[6, APEX - 36], [10, APEX - 28], [17, APEX - 16], [23, APEX + 2]]), { w: 0.6, o: 0.5, closed: true });
  }

  // the dove: one slow crossing, then a long pause; it flaps in bursts and glides.
  // Three key wing poses (down, glide, up) blended like an animator's drawings.
  // points: front root, leading edge, wrist, tip, tip (doubled = pointed), trailing edge ×2, rear root
  const WING_UP = [[-11, -7], [-17, -24], [-13, -42], [1, -60], [1, -60], [8, -42], [14, -24], [13, -5]];
  const WING_MID = [[-11, -7], [-2, -15], [12, -22], [34, -24], [34, -24], [24, -16], [18, -9], [13, -5]];
  const WING_DOWN = [[-11, -5], [-14, 8], [-10, 22], [0, 36], [0, 36], [6, 22], [12, 8], [13, -3]];
  function pose(s) {
    const [a, b, t] = s >= 0 ? [WING_MID, WING_UP, s] : [WING_MID, WING_DOWN, -s];
    return a.map(([x, y], i) => [x + (b[i][0] - x) * t, y + (b[i][1] - y) * t]);
  }
  function smoothPath(ctx, pts) {
    // closed quadratic spline through the midpoints: soft, brush-like contour
    const n = pts.length;
    const mid = (i) => [(pts[i][0] + pts[(i + 1) % n][0]) / 2, (pts[i][1] + pts[(i + 1) % n][1]) / 2];
    ctx.beginPath();
    const m0 = mid(n - 1);
    ctx.moveTo(m0[0], m0[1]);
    for (let i = 0; i < n; i++) { const m = mid(i); ctx.quadraticCurveTo(pts[i][0], pts[i][1], m[0], m[1]); }
    ctx.closePath();
  }

  function live(env) {
    const { T } = env;
    const R = env.rng(17);
    const body = mix(T.ink, T.sky2, 0.4);
    const farWing = mix(T.ink, T.sky2, 0.55);
    const underwing = mix(T.ground, T.sky2, 0.15);
    const tipGrey = mix(T.ink, T.sky2, 0.5);
    const line = rgba(T.ink, 0.5);
    const FLIGHT = 20;
    let born = -1, seed = R();

    function wing(ctx, s, near) {
      const p = pose(s);
      smoothPath(ctx, p);
      if (near) {
        const g = ctx.createLinearGradient(0, -6, p[3][0], p[3][1]);
        g.addColorStop(0, underwing);
        g.addColorStop(0.6, underwing);
        g.addColorStop(1, tipGrey);
        ctx.fillStyle = g;
        ctx.fill();
        ctx.strokeStyle = line;
        ctx.lineWidth = 0.6;
        ctx.stroke();
        // two feather lines toward the tip
        ctx.beginPath();
        [0.55, 0.75].forEach((f) => {
          ctx.moveTo(p[6][0] + (p[1][0] - p[6][0]) * 0.35, p[6][1] + (p[1][1] - p[6][1]) * 0.35);
          ctx.lineTo(p[3][0] * f + p[6][0] * (1 - f), p[3][1] * f + p[6][1] * (1 - f));
        });
        ctx.strokeStyle = rgba(T.ink, 0.22);
        ctx.stroke();
      } else {
        ctx.fillStyle = farWing;
        ctx.fill();
      }
    }

    function bodyPath(ctx) {
      ctx.beginPath();
      ctx.moveTo(-25, -6);
      ctx.quadraticCurveTo(-23, -12.5, -16.5, -12);
      ctx.quadraticCurveTo(-11, -11.5, -8, -8);
      ctx.quadraticCurveTo(6, -8, 22, -6);
      ctx.lineTo(31, -7.5);
      ctx.quadraticCurveTo(34, -3, 32, 2);
      ctx.lineTo(21, 2);
      ctx.quadraticCurveTo(8, 10, -6, 9);
      ctx.quadraticCurveTo(-16, 8, -19, 1);
      ctx.quadraticCurveTo(-21, -3, -25, -6);
      ctx.closePath();
    }

    return {
      draw(ctx, t) {
        if (born < 0) born = t + 2.5;
        const u = (t - born) / FLIGHT;
        if (u > 1) { born = t + 18 + R() * 16; seed = R(); return; }
        if (u < 0) return;
        const x = 1700 - u * 1980;
        const y = 330 - 200 * u + 26 * Math.sin(u * Math.PI * 2 + seed * 3);
        const cyc = (t - born) % 3.4;
        const ph = (t - born) * Math.PI * 2 * 2.1;
        // flap for a while, then settle into a raised glide
        const k = cyc < 1.8 ? 1 : Math.max(0, 1 - (cyc - 1.8) * 3);
        const s = k * Math.sin(ph) + (1 - k) * 0.12;
        ctx.save();
        ctx.translate(x, y - 1.6 * k * Math.sin(ph));
        ctx.rotate(-0.08 + 0.07 * Math.cos(u * Math.PI * 2 + seed * 3));
        ctx.scale(1.45, 1.45);
        ctx.globalAlpha = Math.min(1, u * 14, (1 - u) * 14);
        ctx.save();
        ctx.translate(9, -3);
        ctx.scale(0.9, 0.9);
        wing(ctx, Math.max(-1, s - 0.18), false);
        ctx.restore();
        bodyPath(ctx);
        ctx.fillStyle = body;
        ctx.fill();
        ctx.strokeStyle = line;
        ctx.lineWidth = 0.6;
        ctx.stroke();
        // tail band and eye
        ctx.fillStyle = rgba(T.ink, 0.35);
        ctx.beginPath();
        ctx.moveTo(28, -7.1); ctx.lineTo(31, -7.5); ctx.quadraticCurveTo(34, -3, 32, 2); ctx.lineTo(29, 2);
        ctx.closePath();
        ctx.fill();
        ctx.beginPath();
        ctx.arc(-18.5, -8, 1.1, 0, Math.PI * 2);
        ctx.fill();
        wing(ctx, s, true);
        ctx.restore();
      },
    };
  }

  GP.scenes.dhuhr = {
    seed: 2024,
    focal: [DX, 760],
    layers: [
      { id: 'sky', paint: paintSky, grain: { mottle: 0.3, tooth: 0.16 } },
      { id: 'arch', paint: paintArch, grain: { mottle: 0.26, tooth: 0.12 } },
    ],
    ink,
    live,
  };
})();
