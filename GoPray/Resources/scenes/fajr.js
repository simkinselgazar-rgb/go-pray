/* Fajr — before dawn. A dark room, a deep multifoil arched window, and the first light
   growing slowly through it across the block; dust drifts in the shaft.
   Reference: "Fajir Prayer Inspiration.jpg" (near-black + warm amber shaft). */
(function () {
  'use strict';
  const GP = window.GoPray;
  const { G, mix, rgba } = GP.wc;

  const CX = 1150, SILL = 700, SPRING = 400, APEX = 150, HW = 100;

  // the window opening: straight jambs and a cusped pointed head (seven small lobes)
  function windowShape(hw, sill, apex, spring) {
    const head = G.cusped(G.pointed(CX - hw, CX + hw, spring, apex, 60, 0.3), 7, hw * 0.13, CX, spring + 60);
    return [[CX - hw, sill]].concat(head, [[CX + hw, sill]]);
  }
  const APERTURE = windowShape(HW, SILL, APEX, SPRING);
  const RECESS = [[CX - HW - 46, SILL + 16]].concat(G.pointed(CX - HW - 46, CX + HW + 46, SPRING + 10, APEX - 44, 40, 0.32), [[CX + HW + 46, SILL + 16]]);

  // the same window, thrown onto the floor toward us and to the left
  const FLOOR_Y = 736;
  const PATCH = APERTURE.map(([x, y]) => {
    const d = (SILL - y) / (SILL - APEX);
    return [x - 300 * d - (x - CX) * 0.25 * d, FLOOR_Y + 250 * Math.pow(d, 0.9)];
  });

  function hull(pts) {
    const p = pts.slice().sort((a, b) => a[0] - b[0] || a[1] - b[1]);
    const cr = (o, a, b) => (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
    const lo = [], up = [];
    p.forEach((q) => { while (lo.length > 1 && cr(lo[lo.length - 2], lo[lo.length - 1], q) <= 0) lo.pop(); lo.push(q); });
    p.slice().reverse().forEach((q) => { while (up.length > 1 && cr(up[up.length - 2], up[up.length - 1], q) <= 0) up.pop(); up.push(q); });
    return lo.slice(0, -1).concat(up.slice(0, -1));
  }
  const SHAFT = hull(APERTURE.filter((_, i) => i % 2 === 0).concat(PATCH.filter((_, i) => i % 2 === 0)));

  const PILLAR = [[1430, -40], [1560, -40], [1560, FLOOR_Y + 8], [1430, FLOOR_Y + 8]];

  function paintRoom(P) {
    const { T, ctx } = P;
    ctx.fillStyle = T.deep;
    ctx.fillRect(-60, -60, 1720, 1120);
    // plaster: uneven umber, warming only near the window (no hard seams: all wet-in-wet)
    P.wet(40, (W) => {
      W.wash(G.ellipse(CX - 40, 420, 520, 520, 28), T.stone3, { opacity: 0.62, layers: 12, variance: 0.2, spread: 60 });
      W.wash(G.ellipse(CX - 20, 430, 300, 360, 24), T.stone2, { opacity: 0.42, layers: 12, variance: 0.22, spread: 50 });
      W.wash(G.ellipse(260, 300, 420, 360, 24), T.stone3, { opacity: 0.22, layers: 10, variance: 0.25, spread: 60 });
    });
    // the deep window recess: sides catch the light, the soffit stays dark
    P.wash(RECESS, T.stone2, { opacity: 0.95, layers: 10, variance: 0.03, spread: 2, smooth: 1 });
    P.clip(RECESS, () => {
      P.wet(8, (W) => {
        W.wash([[CX - HW - 60, 300], [CX - HW + 4, 340], [CX - HW + 4, 730], [CX - HW - 60, 740]], T.accent1, { opacity: 0.75, layers: 10, variance: 0.12, spread: 14 });
        W.wash([[CX + HW - 4, 340], [CX + HW + 60, 300], [CX + HW + 60, 740], [CX + HW - 4, 730]], T.stone3, { opacity: 0.75, layers: 10, variance: 0.12, spread: 14 });
        W.wash([[CX - 200, 60], [CX + 200, 60], [CX + 140, 330], [CX - 140, 330]], T.stone3, { opacity: 0.6, layers: 10, variance: 0.2, spread: 20 });
      });
    });
    // what the window shows before the light comes: dim haze
    P.wash(APERTURE, mix(T.sky3, T.deep, 0.4), { opacity: 1, layers: 8, variance: 0.02, spread: 1, smooth: 1 });
    // the pillar, its left face catching a rim of light
    P.wash(PILLAR, mix(T.deep, T.stone3, 0.6), { opacity: 1, layers: 8, variance: 0.02, spread: 2 });
    P.wet(6, (W) => W.wash([[1430, -40], [1452, -40], [1452, FLOOR_Y], [1430, FLOOR_Y]], T.stone2, { opacity: 0.6, layers: 8, variance: 0.1, spread: 3 }));
    // floor: darker toward us, a little warm bounce near the wall
    P.wet(20, (W) => {
      W.wash([[-60, FLOOR_Y], [1720, FLOOR_Y], [1720, 1100], [-60, 1100]], T.deep, { opacity: 1, layers: 6, variance: 0.02, spread: 2 });
      W.wash([[760, FLOOR_Y], [1460, FLOOR_Y], [1380, 840], [700, 860]], T.stone3, { opacity: 0.75, layers: 10, variance: 0.2, spread: 24 });
    });
    P.wash([[-60, FLOOR_Y - 3], [1720, FLOOR_Y - 3], [1720, FLOOR_Y + 4], [-60, FLOOR_Y + 4]], T.deep, { opacity: 0.7, layers: 6, variance: 0.05, spread: 2 });
    // the room falls away into darkness at the edges
    const v = ctx.createRadialGradient(CX - 120, 470, 220, CX - 120, 470, 1150);
    v.addColorStop(0, rgba(T.deep, 0));
    v.addColorStop(1, rgba(T.deep, 0.75));
    ctx.fillStyle = v;
    ctx.fillRect(-60, -60, 1720, 1120);
  }

  // everything that brightens with the dawn (screen-blended, opacity grows across the block)
  function paintLight(P) {
    const { T } = P;
    // the bright window: hottest high up, warmer low down
    P.wash(APERTURE, P.lin(0, 194, 0, SILL, [[0, T.sky1], [0.45, T.sky2], [1, mix(T.sky2, T.sky3, 0.6)]]),
      { opacity: 1, layers: 8, variance: 0.02, spread: 0.8, smooth: 1 });
    // the town in the haze outside: a minaret and low roofs, only just there
    P.clip(APERTURE, () => {
      P.wet(3, (W) => {
        const m = G.lathe(1172, [[1.5, 330], [5, 352], [9, 384], [9, 404], [15, 408], [15, 418], [11, 422], [11, 520], [16, 524], [16, 536], [13, 540], [13, 720]]);
        W.wash(m, T.sky3, { opacity: 0.55, layers: 8, variance: 0.04, spread: 2 });
        W.wash([[1050, 590], [1090, 590], [1094, 572], [1124, 572], [1128, 600], [1250, 604], [1250, 720], [1050, 720]], T.sky3, { opacity: 0.45, layers: 8, variance: 0.05, spread: 3 });
      });
    });
    // the halo on the wall and the lit jamb
    P.glow(CX, 380, 460, T.accent1, 0.7);
    P.glow(CX, 240, 200, T.glow, 0.45);
    P.clip(APERTURE, () => P.glow(CX, 230, 190, T.sky1, 0.9));
    P.glow(CX - HW - 30, 520, 70, T.glow, 0.35, 'screen', 230);
    // the shaft: a soft volume from the opening down to the floor
    P.wet(26, (W) => {
      W.wash(SHAFT, W.lin(CX, 260, 840, 1000, [[0, rgba(T.glow, 0.85)], [0.55, rgba(T.accent1, 0.6)], [1, rgba(T.accent1, 0.3)]]),
        { opacity: 0.85, layers: 10, variance: 0.06, spread: 10, edge: 0 });
    });
    // a few brighter rays inside the shaft
    P.wet(9, (W) => {
      [0.15, 0.38, 0.55, 0.8].forEach((f, i) => {
        const a = APERTURE[Math.floor(f * (APERTURE.length - 1))], b = PATCH[Math.floor(f * (PATCH.length - 1))];
        const w0 = 9 + i * 3, w1 = 22 + i * 5;
        W.wash([[a[0] - w0, a[1]], [a[0] + w0, a[1]], [b[0] + w1, b[1]], [b[0] - w1, b[1]]], W.lin(a[0], a[1], b[0], b[1], [[0, rgba(T.sky1, 0.5)], [1, rgba(T.glow, 0.05)]]),
          { opacity: 0.6, layers: 6, variance: 0.03, spread: 4, edge: 0 });
      });
    });
    // the window's shape lying on the floor
    P.wet(5, (W) => W.wash(PATCH, W.lin(CX, FLOOR_Y, 760, 1000, [[0, T.glow], [1, T.accent2]]), { opacity: 0.9, layers: 10, variance: 0.03, spread: 4 }));
    P.glow(CX - 170, 870, 320, T.accent1, 0.45, 'screen', 120);
  }

  function ink(K) {
    K.line(APERTURE, { w: 1.3, o: 0.85, jitter: 0.08 });
    K.line(RECESS, { w: 1, o: 0.55, jitter: 0.1 });
    K.line([[1430, 0], [1430, FLOOR_Y]], { w: 0.9, o: 0.45 });
    K.line([[-40, FLOOR_Y], [1430, FLOOR_Y]], { w: 0.8, o: 0.4, jitter: 0.6 });
    K.line([[RECESS[0][0] - 8, SILL + 16], [RECESS[RECESS.length - 1][0] + 8, SILL + 16]], { w: 1, o: 0.5 });
  }

  // dust: drifts through the shaft, bright only where the light catches it
  function live(env) {
    const { T, rng } = env;
    const R = rng(5);
    const inside = (x, y) => {
      let c = false;
      for (let i = 0, j = SHAFT.length - 1; i < SHAFT.length; j = i++) {
        const [xi, yi] = SHAFT[i], [xj, yj] = SHAFT[j];
        if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) c = !c;
      }
      return c;
    };
    const xs = SHAFT.map((p) => p[0]), ys = SHAFT.map((p) => p[1]);
    const box = [Math.min(...xs) - 40, Math.min(...ys), Math.max(...xs) + 40, Math.max(...ys)];
    const motes = [];
    while (motes.length < 90) {
      const x = R.range(box[0], box[2]), y = R.range(box[1], box[3]);
      if (!inside(x, y) && R() > 0.15) continue;
      motes.push({ x, y, vx: R.range(-3, 3), vy: R.range(-5, 1.5), r: R.range(0.7, 2.2), ph: R() * 6.28, sp: R.range(0.3, 0.9) });
    }
    // one soft sprite, drawn many times
    const spr = document.createElement('canvas');
    spr.width = spr.height = 32;
    const sx = spr.getContext('2d');
    const g = sx.createRadialGradient(16, 16, 0, 16, 16, 16);
    g.addColorStop(0, rgba(T.sky1, 1));
    g.addColorStop(0.3, rgba(T.glow, 0.6));
    g.addColorStop(1, rgba(T.glow, 0));
    sx.fillStyle = g;
    sx.fillRect(0, 0, 32, 32);
    let start = -1;
    return {
      draw(ctx, t, dt) {
        if (start < 0) start = t;
        const dawn = Math.min(1, 0.38 + 0.62 * ((t - start) * 1000) / env.durationMs);
        ctx.globalCompositeOperation = 'lighter';
        motes.forEach((m) => {
          m.x += (m.vx + 4 * Math.sin(t * m.sp + m.ph)) * dt;
          m.y += (m.vy + 3 * Math.cos(t * m.sp * 0.7 + m.ph)) * dt;
          if (m.y < box[1] - 20) m.y = box[3];
          if (m.y > box[3] + 20) m.y = box[1];
          if (m.x < box[0] - 20) m.x = box[2];
          if (m.x > box[2] + 20) m.x = box[0];
          const lit = inside(m.x, m.y) ? 1 : 0.12;
          const tw = 0.55 + 0.45 * Math.sin(t * 1.3 * m.sp + m.ph * 3);
          ctx.globalAlpha = Math.max(0, lit * tw * dawn * 0.9);
          const s = m.r * 4;
          ctx.drawImage(spr, m.x - s / 2, m.y - s / 2, s, s);
        });
        ctx.globalAlpha = 1;
        ctx.globalCompositeOperation = 'source-over';
      },
    };
  }

  GP.scenes.fajr = {
    seed: 515,
    focal: [CX, 420],
    layers: [
      { id: 'room', paint: paintRoom, grain: { mottle: 0.4, tooth: 0.2 } },
      { id: 'light', paint: paintLight, grain: { mottle: 0.25, tooth: 0.12 } },
    ],
    ink,
    live,
  };
})();
