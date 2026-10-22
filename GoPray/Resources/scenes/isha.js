/* Isha — Masjid al-Haram at night, seen from above. The Kaaba at the centre; tawaf as
   hundreds of small lights circling it COUNTER-CLOCKWISE (as seen from above), slow and
   continuous; the arcade and minarets lit; the clock tower faint behind.
   Reference: "Isha Prayer Inspiration.jpg" (the main reference, per Ahmed). */
(function () {
  'use strict';
  const GP = window.GoPray;
  const { G, mix, rgba } = GP.wc;

  const CX = 1080, CY = 566; // Kaaba centre on the mataf floor
  const K = 0.42; // ellipse squash: the mataf circle seen from high up
  const RM = 300; // mataf radius (plan units)
  const ell = (r, a) => [CX + r * Math.cos(a), CY - r * K * Math.sin(a)]; // a grows → counter-clockwise on screen

  // the Kaaba: front face, top face, right face (we look down from the south-west)
  const KB = { x0: 1054, x1: 1106, y0: 534, y1: 584, dx: 13, dy: -12 };
  const FRONT = [[KB.x0, KB.y0], [KB.x1, KB.y0], [KB.x1, KB.y1], [KB.x0, KB.y1]];
  const TOPF = [[KB.x0, KB.y0], [KB.x1, KB.y0], [KB.x1 + KB.dx, KB.y0 + KB.dy], [KB.x0 + KB.dx, KB.y0 + KB.dy]];
  const SIDE = [[KB.x1, KB.y0], [KB.x1 + KB.dx, KB.y0 + KB.dy], [KB.x1 + KB.dx, KB.y1 + KB.dy], [KB.x1, KB.y1]];
  const BAND_Y = 546;

  function minaret(x, base, top, hw) {
    const h = base - top;
    return [
      [1, top - 30], [hw * 0.35, top - 6], [hw * 0.55, top + h * 0.02], [hw * 0.55, top + h * 0.08],
      [hw * 1.15, top + h * 0.1], [hw * 1.15, top + h * 0.13], [hw * 0.8, top + h * 0.14], [hw * 0.8, top + h * 0.34],
      [hw * 1.25, top + h * 0.36], [hw * 1.25, top + h * 0.4], [hw * 0.95, top + h * 0.41], [hw * 0.95, top + h * 0.66],
      [hw * 1.3, top + h * 0.68], [hw * 1.3, top + h * 0.72], [hw, top + h * 0.73], [hw, base],
    ];
  }
  const MINARETS = [
    // far pairs behind the arcade, and two near ones rising from the bottom of the frame
    { x: 868, base: 418, top: 262, hw: 7 }, { x: 936, base: 412, top: 252, hw: 7 },
    { x: 1226, base: 412, top: 252, hw: 7 }, { x: 1294, base: 418, top: 262, hw: 7 },
    { x: 660, base: 1060, top: 270, hw: 15 }, { x: 1526, base: 1060, top: 256, hw: 16 },
  ];
  const GALLERIES = [0.1, 0.36, 0.68];

  function paintNight(P) {
    const { T, ctx } = P;
    ctx.fillStyle = T.sky1;
    ctx.fillRect(-60, -60, 1720, 1120);
    // hills and the far city, barely there
    P.wet(24, (W) => {
      W.wash([[-60, 300], [260, 250], [520, 300], [780, 240], [1060, 280], [1380, 230], [1720, 280], [1720, 520], [-60, 520]], T.sky2, { opacity: 0.9, layers: 10, variance: 0.12, spread: 30 });
      W.glow(CX, 420, 760, T.sky3, 0.8, 'source-over', 260);
    });
    // city lights (fewer on the left, where the words are)
    const R = P.R;
    for (let i = 0; i < 520; i++) {
      const x = R.range(-40, 1640), y = R.range(250, 470) + (x < 600 ? R.range(0, 60) : 0);
      if (x < 600 && R() < 0.65) continue;
      P.dot(x, y, R.range(0.5, 1.3), R() < 0.8 ? T.glow : T.stone1, R.range(0.15, 0.6));
    }
    // the hotel towers and the clock tower, faint: tall, thin, lit only at their crowns
    const towers = [[912, 50, 196], [1250, 50, 206], [800, 40, 262], [1362, 42, 252], [1004, 26, 230], [1158, 26, 236]];
    towers.forEach(([x, hw, top]) => P.wash(G.rect(x - hw, top, hw * 2, 440 - top), mix(T.sky3, T.stone3, 0.22), { opacity: 0.95, layers: 8, variance: 0.02, spread: 1.5 }));
    const clock = [[CX - 3, -60], [CX + 3, -60], [CX + 14, 6], [CX + 30, 26], [CX + 30, 58], [CX + 38, 64], [CX + 38, 150], [CX + 54, 166], [CX + 54, 300], [CX + 96, 316], [CX + 96, 440],
      [CX - 96, 440], [CX - 96, 316], [CX - 54, 300], [CX - 54, 166], [CX - 38, 150], [CX - 38, 64], [CX - 30, 58], [CX - 30, 26], [CX - 14, 6]];
    P.wash(clock, mix(T.sky3, T.stone3, 0.32), { opacity: 0.97, layers: 8, variance: 0.02, spread: 1 });
    P.dot(CX, 104, 23, mix(T.accent2, T.deep, 0.45), 0.95);
    P.dot(CX, 104, 19, mix(T.accent2, T.sky3, 0.15), 0.9);
    P.fill(G.rect(CX - 34, 132, 68, 4), T.accent2, 0.8);
    // window lights: rows of faint warm specks, crowns lit
    towers.concat([[CX, 52, 170]]).forEach(([x, hw, top]) => {
      for (let y = top + 14; y < 430; y += 8) for (let xx = x - hw + 5; xx < x + hw - 3; xx += 6) if (R() < 0.38) P.dot(xx, y, 0.7, T.glow, R.range(0.15, 0.5));
      P.fill(G.rect(x - hw, top, hw * 2, 3), T.glow, 0.6);
    });

    // the city packed round the haram: dark blocks, scattered lit windows
    P.wet(3, (W) => {
      W.wash([[600, 460], [700, 430], [1600, 430], [1720, 460], [1720, 1100], [-60, 1100], [-60, 900], [420, 860], [600, 800]], mix(T.sky1, T.stone3, 0.22), { opacity: 0.97, layers: 8, variance: 0.03, spread: 4 });
      for (let i = 0; i < 70; i++) {
        const x = R.range(440, 1720), y = R.range(440, 1000), w = R.range(30, 90), h = R.range(16, 50);
        if (x < 600 && y < 840) continue;
        W.wash(G.rect(x, y, w, h), mix(T.sky1, T.stone3, R.range(0.12, 0.38)), { opacity: 0.8, layers: 4, variance: 0.02, spread: 1 });
      }
    });
    for (let i = 0; i < 900; i++) {
      const x = R.range(420, 1720), y = R.range(440, 1000);
      if (x < 620 && y < 850) continue;
      P.dot(x, y, R.range(0.5, 1), R() < 0.75 ? T.glow : T.stone1, R.range(0.12, 0.5));
    }

    // the haram's outer buildings: storeys of stone with rows of lit windows (straight runs, not a bowl)
    const OCT = [];
    for (let i = 0; i < 8; i++) OCT.push(ell(500, (i / 8) * Math.PI * 2 + Math.PI / 8));
    const outer = OCT.map(([x, y]) => [x + (x - CX) * 0.12, y + (y > CY ? 70 : -14)]);
    // its front walls, facing us, with two storeys of lit arches
    for (let i = 0; i < 8; i++) {
      const p0 = outer[i], p1 = outer[(i + 1) % 8];
      if (p0[1] < CY + 40 || p1[1] < CY + 40) continue;
      P.wash([p0, p1, [p1[0], p1[1] + 58], [p0[0], p0[1] + 58]], mix(T.stone3, T.stone2, 0.2), { opacity: 0.97, layers: 6, variance: 0.01, spread: 0.8 });
      const n = Math.floor(Math.hypot(p1[0] - p0[0], p1[1] - p0[1]) / 15);
      for (let j = 1; j < n; j++) {
        const x = p0[0] + ((p1[0] - p0[0]) * j) / n, y = p0[1] + ((p1[1] - p0[1]) * j) / n;
        [[20, 12], [44, 14]].forEach(([dy, h]) => P.fill([[x - 3.2, y + dy + h]].concat(G.pointed(x - 3.2, x + 3.2, y + dy + 3, y + dy, 3, 0.3), [[x + 3.2, y + dy + h]]), T.glow, dy > 30 ? 0.65 : 0.45));
      }
    }
    P.wet(3, (W) => W.wash(outer, mix(T.stone3, T.sky3, 0.62), { opacity: 0.97, layers: 8, variance: 0.02, spread: 3 }));
    for (let k = 0; k < 5; k++) {
      const f = 0.84 + k * 0.035;
      for (let i = 0; i < 8; i++) {
        const [x0, y0] = outer[i], [x1, y1] = outer[(i + 1) % 8];
        const ax = CX + (x0 - CX) * f, ay = CY + (y0 - CY) * f, bx = CX + (x1 - CX) * f, by = CY + (y1 - CY) * f;
        const n = Math.ceil(Math.hypot(bx - ax, by - ay) / 6);
        for (let j = 0; j < n; j++) if (R() < 0.75) P.dot(ax + ((bx - ax) * j) / n, ay + ((by - ay) * j) / n, 0.8, k % 2 ? T.stone1 : T.glow, R.range(0.25, 0.6));
      }
    }
    // the white courtyard round the mataf, filled with rows of worshippers
    P.wash(G.ellipse(CX, CY, 400, 400 * K + 8, 64), mix(T.stone2, T.stone3, 0.35), { opacity: 0.97, layers: 10, variance: 0.01, spread: 1.2 });
    P.wet(10, (W) => W.wash(G.ellipse(CX, CY, 390, 390 * K + 6, 48), T.stone2, { opacity: 0.5, layers: 8, variance: 0.04, spread: 8 }));
    for (let i = 0; i < 2600; i++) {
      const r = R.range(306, 396), a = R() * Math.PI * 2;
      const [x, y] = ell(r, a);
      P.dot(x, y, 0.75, T.stone1, R.range(0.25, 0.75));
    }
    // the far arcade: its lit inner face, a run of small arches
    const ARC_R = 404;
    const band = G.arc(CX, CY, ARC_R, ARC_R * K, Math.PI + 0.02, 2 * Math.PI - 0.02, 60);
    P.wash(band.concat(band.slice().reverse().map(([x, y]) => [x, y - 30])), mix(T.stone2, T.stone1, 0.3), { opacity: 0.95, layers: 6, variance: 0.01, spread: 0.8 });
    for (let a = 0.06; a < Math.PI - 0.06; a += 0.034) {
      const [x, y] = ell(ARC_R, a);
      const w = 4.2 * (0.45 + 0.55 * Math.sin(a));
      [[0, 13, 4], [-15, 10, 3]].forEach(([dy, h, hh]) =>
        P.fill([[x - w, y + dy]].concat(G.pointed(x - w, x + w, y + dy - h + hh, y + dy - h, 3, 0.3), [[x + w, y + dy]]), T.glow, 0.45 + 0.4 * Math.sin(a)));
    }
    // the mataf floor: lit marble, a shade darker than the people on it
    P.wash(G.ellipse(CX, CY, RM, RM * K, 64), mix(T.stone3, T.stone2, 0.78), { opacity: 0.98, layers: 10, variance: 0.01, spread: 1.2 });
    P.wet(14, (W) => W.wash(G.ellipse(CX, CY - 4, 250, 250 * K, 40), T.stone2, { opacity: 0.45, layers: 8, variance: 0.05, spread: 10 }));
    // the outer edge of the mataf is packed and still (people praying in rows)
    for (let r = 250; r < 300; r += 5) {
      for (let a = 0; a < Math.PI * 2; a += 2.4 / r) {
        const [x, y] = ell(r + R.gauss() * 1.2, a + R.gauss() * 0.004);
        P.dot(x, y, 0.8, T.stone1, R.range(0.35, 0.85));
      }
    }
    // a ring of small domes on the near side of the portico
    for (let a = Math.PI + 0.16; a < 2 * Math.PI - 0.16; a += 0.13) {
      const [x, y] = ell(ARC_R + 26, a);
      const s = 0.75 + 0.35 * -Math.sin(a);
      P.wash(G.arc(x, y, 15 * s, 13 * s, Math.PI, 2 * Math.PI, 12).concat([[x + 15 * s, y + 4 * s], [x - 15 * s, y + 4 * s]]), mix(T.stone3, T.accent1, 0.25), { opacity: 0.97, layers: 6, variance: 0.02, spread: 0.6 });
      P.dot(x - 4 * s, y - 7 * s, 3 * s, T.glow, 0.35);
    }
    // minarets: white light, green at the galleries
    MINARETS.forEach((m) => {
      const body = G.lathe(m.x, minaret(m.x, m.base, m.top, m.hw));
      P.wash(body, T.stone1, { opacity: 0.97, layers: 6, variance: 0.01, spread: 0.6 });
      P.clip(body, () => {
        P.wash(G.rect(m.x + m.hw * 0.25, m.top - 40, m.hw * 2, m.base - m.top + 60), T.stone2, { opacity: 0.6, layers: 6, variance: 0.03, spread: 2 });
        GALLERIES.forEach((g) => P.wash(G.rect(m.x - m.hw * 1.4, m.top + (m.base - m.top) * g, m.hw * 2.8, (m.base - m.top) * 0.03), T.accent2, { opacity: 0.8, layers: 4, variance: 0.02, spread: 0.6 }));
      });
      P.fill(G.arc(m.x, m.top - 34, m.hw * 0.4, m.hw * 0.4, -0.1 * Math.PI, 1.1 * Math.PI, 10), T.accent1, 0.9);
    });

    // the Kaaba (also redrawn on the live layer so near tawaf lights can pass in front)
    paintKaaba(P.ctx, T);
  }

  function paintKaaba(ctx, T) {
    const poly = (pts, c, a = 1) => { ctx.globalAlpha = a; ctx.fillStyle = c; ctx.beginPath(); pts.forEach(([x, y], i) => (i ? ctx.lineTo(x, y) : ctx.moveTo(x, y))); ctx.closePath(); ctx.fill(); };
    ctx.save();
    // Hijr Ismail: the low curved white wall on one side
    ctx.strokeStyle = rgba(T.stone1, 0.85);
    ctx.lineWidth = 2.6;
    ctx.beginPath();
    ctx.ellipse(KB.x0 + 4, KB.y1 - 7, 32, 14, 0, Math.PI * 0.5, Math.PI * 1.5);
    ctx.stroke();
    poly(FRONT, T.deep);
    poly(TOPF, mix(T.deep, T.stone3, 0.4));
    poly(SIDE, mix(T.deep, T.sky1, 0.5));
    // the gold band (hizam) round the kiswa, and the door
    poly([[KB.x0, BAND_Y], [KB.x1, BAND_Y], [KB.x1, BAND_Y + 5], [KB.x0, BAND_Y + 5]], T.accent1, 0.95);
    poly([[KB.x1, BAND_Y], [KB.x1 + KB.dx, BAND_Y + KB.dy], [KB.x1 + KB.dx, BAND_Y + KB.dy + 5], [KB.x1, BAND_Y + 5]], mix(T.accent1, T.deep, 0.35), 0.95);
    poly([[KB.x1 - 15, 560], [KB.x1 - 6, 560], [KB.x1 - 6, 578], [KB.x1 - 15, 578]], T.accent1, 0.85);
    // Maqam Ibrahim: a small gold-lit shelter in front
    ctx.globalAlpha = 0.95;
    ctx.fillStyle = T.accent1;
    ctx.beginPath();
    ctx.arc(1128, 604, 3.2, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();
  }

  function paintLights(P) {
    const { T } = P;
    // the mataf glows white; the arcade glows warm
    P.glow(CX, CY, 380, T.stone1, 0.42, 'screen', 180);
    for (let a = 0.1; a < Math.PI - 0.1; a += 0.16) { const [x, y] = ell(404, a); P.glow(x, y - 10, 34, T.glow, 0.22); }
    // minaret galleries
    MINARETS.forEach((m) => {
      GALLERIES.forEach((g) => P.glow(m.x, m.top + (m.base - m.top) * g, m.hw * 4, T.stone1, 0.45));
    });
    // the clock face, green
    P.glow(CX, 104, 80, T.accent2, 0.5);
    P.glow(CX, 104, 24, T.ring, 0.55);

  }

  function ink(I, T) {
    MINARETS.forEach((m) => I.line(G.lathe(m.x, minaret(m.x, m.base, m.top, m.hw)), { w: m.hw > 10 ? 0.8 : 0.5, o: 0.35, closed: true, jitter: 0.04 }));
    I.line(G.ellipse(CX, CY, RM, RM * K, 90), { w: 0.6, o: 0.3, closed: true, jitter: 0.1 });
    // the clock face: a ring and two hands
    I.line(G.ellipse(CX, 104, 19, 19, 40), { w: 0.7, o: 0.45, closed: true, color: T.ring, jitter: 0.03 });
    I.line([[CX, 104], [CX, 90]], { w: 0.9, o: 0.55, color: T.stone1, jitter: 0 });
    I.line([[CX, 104], [CX + 10, 108]], { w: 0.9, o: 0.55, color: T.stone1, jitter: 0 });
    // the Kaaba's edges, very lightly
    I.line([[KB.x0, KB.y1], [KB.x0, KB.y0], [KB.x1, KB.y0], [KB.x1 + KB.dx, KB.y0 + KB.dy], [KB.x1 + KB.dx, KB.y1 + KB.dy], [KB.x1, KB.y1], [KB.x0, KB.y1]], { w: 0.6, o: 0.22, jitter: 0.02 });
  }

  // tawaf: lights circling the Kaaba counter-clockwise, inner rings a little quicker
  function live(env) {
    const { T, rng } = env;
    const R = rng(1446);
    const N = 2600;
    const pts = [];
    for (let i = 0; i < N; i++) {
      const r = 46 + 205 * Math.pow(R(), 1.7);
      pts.push({ r, a: R() * Math.PI * 2, w: ((2 * Math.PI) / 84) * Math.pow(100 / r, 0.55), ph: R() * 6.28, al: R.range(0.5, 1), warm: R() < 0.1, s: R.range(1.1, 1.7) });
    }
    const white = T.stone1, warm = mix(T.stone1, T.glow, 0.5);
    let t0 = -1;
    function drawPts(ctx, t, far) {
      pts.forEach((p) => {
        const a = p.a + p.w * t; // increasing angle = counter-clockwise
        const sn = Math.sin(a);
        if (far !== sn > 0) return;
        const r = p.r + 1.6 * Math.sin(t * 0.4 + p.ph);
        const x = CX + r * Math.cos(a), y = CY - r * K * sn;
        ctx.globalAlpha = p.al;
        ctx.fillStyle = p.warm ? warm : white;
        ctx.fillRect(x - p.s / 2, y - p.s / 2, p.s, p.s);
        // a faint trail behind each walker, along the direction of the circuit
        ctx.globalAlpha = p.al * 0.35;
        ctx.fillRect(x + 2.2 * sn - p.s / 2, y + 2.2 * K * Math.cos(a) - p.s / 2, p.s, p.s);
      });
    }
    return {
      draw(ctx, t) {
        if (t0 < 0) t0 = t;
        const tt = t - t0;
        drawPts(ctx, tt, true);
        ctx.globalAlpha = 1;
        paintKaaba(ctx, T);
        drawPts(ctx, tt, false);
        ctx.globalAlpha = 1;
      },
    };
  }

  GP.scenes.isha = {
    seed: 1446,
    focal: [CX, CY],
    layers: [
      { id: 'night', paint: paintNight, grain: { mottle: 0.34, tooth: 0.16 } },
      { id: 'lights', paint: paintLights, grain: false },
    ],
    ink,
    live,
  };
})();
