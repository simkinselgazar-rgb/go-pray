/* Asr — a white marble arcade with gold capitals and lanterns; through the arches, the green
   dome far off in the afternoon haze. Lantern glow breathes; column shadows creep as the sun
   moves. Reference: "Asr Prayer Inspiration.jpg". */
(function () {
  'use strict';
  const GP = window.GoPray;
  const { G, mix, rgba } = GP.wc;

  const PIERS = [640, 1110, 1580];
  const PHW = 54; // pier half-width
  const SPRING = 410, APEX = 150, TOP = 118;
  const SHAFT_HW = 34, BASE_Y = 872, FLOOR_NEAR = 940, HORIZON = 640;
  const NICHE = { cx: 336, hw: 186, spring: 330, apex: 150, bottom: FLOOR_NEAR };

  function openings() {
    const out = [];
    for (let i = 0; i < PIERS.length - 1; i++) {
      const x0 = PIERS[i] + PHW, x1 = PIERS[i + 1] - PHW;
      const intra = G.cusped(G.pointed(x0, x1, SPRING, APEX, 48, 0.32), 7, 13, (x0 + x1) / 2, SPRING + 40);
      const extra = G.pointed(x0 - 26, x1 + 26, SPRING, APEX - 34, 48, 0.32);
      out.push({ x0, x1, cx: (x0 + x1) / 2, intra, extra });
    }
    return out;
  }
  const OPEN = openings();

  // the nabawi dome far off, small: same bullet profile as Dhuhr
  const DOME_X = 862;
  const FAR_DOME = G.bez([0, 516], [16, 516], [58, 538], [58, 600], 16).concat([[58, 606], [62, 606], [62, 640]]);

  function capital(x) { return [[x - 58, 452], [x + 58, 452], [x + 52, 470], [x + 38, 516], [x + 36, 524], [x - 36, 524], [x - 38, 516], [x - 52, 470]]; }

  function paintHall(P) {
    const { T, ctx } = P;
    ctx.fillStyle = T.ground;
    ctx.fillRect(-60, -60, 1720, 1120);

    // --- beyond the arches: sky, haze, the far haram wall, the green dome ---
    P.wet(14, (W) => {
      W.ctx.fillStyle = W.lin(0, 100, 0, HORIZON + 20, [[0, T.sky1], [0.7, T.sky2], [1, T.sky3]]);
      W.ctx.fillRect(560, -60, 1160, HORIZON + 80);
    });
    P.wet(2, (W) => {
      // far wall with its rhythm of small openings
      W.wash([[560, 606], [1700, 600], [1700, 668], [560, 672]], mix(T.sky3, T.stone3, 0.25), { opacity: 0.75, layers: 8, variance: 0.04, spread: 3 });
      // white domes and a slender far minaret
      [[760, 30, 604], [968, 34, 606], [1300, 26, 604], [1490, 38, 606]].forEach(([x, r, y]) =>
        W.wash(G.arc(x, y, r, r * 0.95, Math.PI, 2 * Math.PI, 16), mix(T.stone1, T.sky2, 0.3), { opacity: 0.9, layers: 8, variance: 0.03, spread: 1.5 }));
      [[1006, 430], [1432, 470]].forEach(([x, top]) => {
        const m = G.lathe(x, [[1.2, top], [4, top + 18], [6.5, top + 40], [10, top + 44], [10, top + 50], [7.5, top + 54], [7.5, 610]]);
        W.wash(m, mix(T.stone1, T.sky3, 0.35), { opacity: 0.9, layers: 8, variance: 0.03, spread: 1 });
      });
    });
    // the green dome
    const drum = G.rect(DOME_X - 62, 606, 124, 36);
    P.wash(drum, mix(T.stone1, T.sky3, 0.2), { opacity: 0.95, layers: 8, variance: 0.03, spread: 1 });
    const dome = G.lathe(DOME_X, FAR_DOME.slice(0, 17));
    P.wash(dome, T.accent2, { opacity: 0.95, layers: 10, variance: 0.03, spread: 1, smooth: 1 });
    P.clip(dome, () => {
      P.wet(6, (W) => {
        W.wash([[DOME_X + 14, 520], [DOME_X + 70, 540], [DOME_X + 70, 610], [DOME_X + 20, 610]], mix(T.accent2, T.deep, 0.45), { opacity: 0.6, layers: 8, variance: 0.1, spread: 6 });
        W.wash([[DOME_X - 40, 540], [DOME_X - 10, 525], [DOME_X - 6, 590], [DOME_X - 46, 596]], mix(T.accent2, T.sky1, 0.4), { opacity: 0.5, layers: 8, variance: 0.1, spread: 6 });
      });
    });
    P.fill(G.rect(DOME_X - 1.2, 494, 2.4, 24), T.accent1);
    P.dot(DOME_X, 504, 3.2, T.accent1);
    P.dot(DOME_X, 494, 2.2, T.accent1);
    // aerial haze pushes it all back
    P.wet(20, (W) => W.wash([[560, 470], [1700, 470], [1700, 690], [560, 690]], T.sky3, { opacity: 0.22, layers: 8, variance: 0.1, spread: 20, edge: 0 }));

    // --- the far parapet with its lattice, then the floor ---
    P.wash([[560, 700], [1700, 700], [1700, 830], [560, 830]], mix(T.stone2, T.sky3, 0.3), { opacity: 0.95, layers: 8, variance: 0.02, spread: 1.5 });
    P.wash([[560, 700], [1700, 700], [1700, 716], [560, 716]], T.stone1, { opacity: 0.95, layers: 6, variance: 0.02, spread: 1 });
    P.wash([[560, 800], [1700, 800], [1700, 830], [560, 830]], T.stone2, { opacity: 0.9, layers: 6, variance: 0.02, spread: 1 });
    for (let x = 700; x < 1700; x += 118) {
      P.wash(G.rect(x - 9, 698, 18, 132), T.stone1, { opacity: 0.95, layers: 6, variance: 0.02, spread: 1 });
      P.dot(x, 690, 8, T.stone1);
    }
    // marble floor, rug runners
    P.wet(6, (W) => {
      W.wash([[-60, 830], [1720, 830], [1720, 1100], [-60, 1100]], W.lin(0, 830, 0, 1000, [[0, T.stone1], [1, T.stone2]]), { opacity: 1, layers: 6, variance: 0.02, spread: 2 });
      [[858, 884], [914, 952]].forEach(([y0, y1]) =>
        W.wash([[560, y0], [1720, y0 - 2], [1720, y1 + 2], [560, y1]], mix(T.accent2, T.stone2, 0.55), { opacity: 0.32, layers: 8, variance: 0.03, spread: 3 }));
    });

    // --- the arcade itself ---
    OPEN.forEach((o) => {
      // spandrel above each arch, cut by the extrados
      const sp = [[o.x0 - 2, TOP], [o.x1 + 2, TOP], [o.x1 + 2, SPRING]].concat(o.extra.slice().reverse(), [[o.x0 - 2, SPRING]]);
      P.wash(sp, T.stone1, { opacity: 0.97, layers: 8, variance: 0.02, spread: 1, smooth: 1 });
      // the arch ring between extrados and intrados
      const ring = o.extra.concat(o.intra.slice().reverse());
      P.wash(ring, T.stone1, { opacity: 0.97, layers: 8, variance: 0.02, spread: 1, smooth: 1 });
      P.clip(ring, () => P.wet(10, (W) => W.wash([[o.x0 - 30, 300], [o.cx, 120], [o.x1 + 30, 300], [o.x1 + 30, 420], [o.cx + 60, 230], [o.cx - 60, 230], [o.x0 - 30, 420]],
        T.stone3, { opacity: 0.4, layers: 8, variance: 0.1, spread: 10 })));
    });
    PIERS.forEach((x) => {
      const pier = G.rect(x - PHW, TOP, PHW * 2, SPRING - TOP + 4);
      P.wash(pier, T.stone1, { opacity: 0.97, layers: 8, variance: 0.02, spread: 1 });
      P.clip(pier, () => P.wet(8, (W) => W.wash(G.rect(x + PHW * 0.35, TOP, PHW, SPRING - TOP), T.stone2, { opacity: 0.6, layers: 8, variance: 0.08, spread: 6 })));
      // impost block with three rosettes
      P.wash(G.rect(x - 60, 410, 120, 42), T.stone2, { opacity: 0.95, layers: 6, variance: 0.02, spread: 1 });
      [-32, 0, 32].forEach((dx) => { P.dot(x + dx, 431, 7.5, mix(T.stone3, T.deep, 0.2), 0.55); P.dot(x + dx, 431, 3, T.accent1, 0.9); });
      // gold capital
      P.wash(capital(x), T.accent1, { opacity: 0.97, layers: 8, variance: 0.02, spread: 1 });
      P.clip(capital(x), () => {
        P.wash(G.rect(x + 14, 450, 50, 80), mix(T.accent1, T.deep, 0.35), { opacity: 0.6, layers: 6, variance: 0.08, spread: 4 });
        P.wash([[x - 14, 466], [x + 14, 466], [x + 12, 496], [x, 510], [x - 12, 496]], mix(T.accent1, T.glow, 0.4), { opacity: 0.8, layers: 6, variance: 0.04, spread: 1.5 });
      });
      // marble shaft, lit on the left, veined
      const shaft = G.rect(x - SHAFT_HW, 524, SHAFT_HW * 2, BASE_Y - 524);
      P.wash(shaft, T.stone1, { opacity: 0.98, layers: 8, variance: 0.01, spread: 0.8 });
      P.clip(shaft, () => P.wet(5, (W) => {
        W.wash(G.rect(x + 6, 520, 40, 360), T.stone2, { opacity: 0.75, layers: 8, variance: 0.05, spread: 4 });
        W.wash(G.rect(x + 22, 520, 20, 360), T.stone3, { opacity: 0.45, layers: 6, variance: 0.05, spread: 3 });
      }));
      // base and plinth
      P.wash(G.lathe(x, [[38, BASE_Y], [44, BASE_Y + 8], [44, BASE_Y + 18], [64, BASE_Y + 22], [64, FLOOR_NEAR]]), T.stone1, { opacity: 0.98, layers: 8, variance: 0.02, spread: 1 });
      P.wash(G.rect(x + 18, BASE_Y + 22, 46, FLOOR_NEAR - BASE_Y - 22), T.stone2, { opacity: 0.6, layers: 6, variance: 0.05, spread: 3 });
      // wall lantern on the pier face
      P.wash(G.lathe(x, [[4, 280], [14, 292], [18, 300], [18, 356], [12, 366], [6, 378]]), T.accent1, { opacity: 0.97, layers: 6, variance: 0.02, spread: 0.8 });
      P.wash(G.rect(x - 12, 302, 24, 50), T.glow, { opacity: 0.95, layers: 6, variance: 0.02, spread: 0.6 });
      P.wash(G.rect(x - 5, 310, 10, 34), T.stone1, { opacity: 0.9, layers: 4, variance: 0.02, spread: 0.6 });
      // spandrel medallion: an eight-point star in gold, green at its heart
      P.wash(G.star8(x, 236, 34), T.accent1, { opacity: 0.9, layers: 6, variance: 0.02, spread: 0.8 });
      P.wash(G.star8(x, 236, 26), mix(T.accent2, T.stone1, 0.15), { opacity: 0.85, layers: 6, variance: 0.02, spread: 0.8 });
      P.dot(x, 236, 7, T.accent1, 0.9);
    });
    // hanging lanterns in each arch
    OPEN.forEach((o) => {
      P.fill(G.rect(o.cx - 0.8, APEX + 6, 1.6, 104), T.accent1, 0.9);
      P.wash(G.lathe(o.cx, [[2, 250], [10, 258], [15, 268], [15, 304], [9, 314], [3, 322]]), T.accent1, { opacity: 0.97, layers: 6, variance: 0.02, spread: 0.8 });
      P.wash(G.rect(o.cx - 10, 270, 20, 32), T.glow, { opacity: 0.95, layers: 6, variance: 0.02, spread: 0.6 });
      P.wash(G.rect(o.cx - 4, 276, 8, 20), T.stone1, { opacity: 0.9, layers: 4, variance: 0.02, spread: 0.6 });
    });

    // --- the left wall, with a blind niche that frames the words ---
    const wall = [[-60, TOP], [PIERS[0] - PHW + 2, TOP], [PIERS[0] - PHW + 2, FLOOR_NEAR], [-60, FLOOR_NEAR]];
    P.wash(wall, T.stone1, { opacity: 0.98, layers: 8, variance: 0.01, spread: 1 });
    const niche = [[NICHE.cx - NICHE.hw, NICHE.bottom]].concat(
      G.cusped(G.pointed(NICHE.cx - NICHE.hw, NICHE.cx + NICHE.hw, NICHE.spring, NICHE.apex, 60, 0.3), 9, 12, NICHE.cx, NICHE.spring + 60),
      [[NICHE.cx + NICHE.hw, NICHE.bottom]]);
    P.wet(14, (W) => {
      W.wash(G.rect(-60, TOP, 700, 840), T.stone2, { opacity: 0.35, layers: 8, variance: 0.12, spread: 30 });
    });
    P.wash(niche, T.stone2, { opacity: 0.38, layers: 8, variance: 0.02, spread: 1, smooth: 1 });
    P.clip(niche, () => P.wet(18, (W) => W.wash([[NICHE.cx - NICHE.hw - 20, 140], [NICHE.cx - NICHE.hw + 40, 140], [NICHE.cx - NICHE.hw + 40, 960], [NICHE.cx - NICHE.hw - 20, 960]], T.stone3, { opacity: 0.35, layers: 8, variance: 0.1, spread: 10 })));
    // floor in front
    P.wash([[-60, FLOOR_NEAR], [1720, FLOOR_NEAR], [1720, 1100], [-60, 1100]], P.lin(0, FLOOR_NEAR, 0, 1000, [[0, T.stone2], [1, mix(T.stone2, T.stone3, 0.4)]]), { opacity: 1, layers: 6, variance: 0.01, spread: 1 });

    // a little uneven pigment over the stone so it reads as paint, not plaster
    P.wet(26, (W) => {
      [[220, 760, 260, 200], [700, 300, 200, 160], [1180, 760, 220, 180], [1500, 330, 180, 150], [380, 260, 200, 120]].forEach(([x, y, rx, ry]) =>
        W.wash(G.ellipse(x, y, rx, ry, 20), T.stone2, { opacity: 0.16, layers: 8, variance: 0.25, spread: 30 }));
    }, { blend: 'multiply' });

    // afternoon light: a warm glaze slanting in from the right, cool shade under the arches
    P.wet(40, (W) => {
      W.wash([[900, 120], [1720, 60], [1720, 1000], [1100, 1000]], T.glow, { opacity: 0.28, layers: 10, variance: 0.2, spread: 40, edge: 0 });
      OPEN.forEach((o) => W.wash([[o.x0 - 40, 130], [o.x1 + 40, 130], [o.x1 + 20, 260], [o.x0 - 20, 260]], T.stone3, { opacity: 0.18, layers: 8, variance: 0.2, spread: 30, edge: 0 }));
      W.wash([[-60, 120], [600, 120], [600, 300], [-60, 360]], T.stone2, { opacity: 0.2, layers: 8, variance: 0.2, spread: 40, edge: 0 });
    }, { blend: 'multiply' });

    // --- frieze and ceiling across the top ---
    P.wash([[-60, 64], [1720, 64], [1720, TOP + 2], [-60, TOP + 2]], mix(T.accent2, T.deep, 0.5), { opacity: 0.97, layers: 8, variance: 0.01, spread: 1 });
    P.wash([[-60, -60], [1720, -60], [1720, 66], [-60, 66]], mix(T.deep, T.stone3, 0.35), { opacity: 0.97, layers: 8, variance: 0.01, spread: 1 });
    P.wash([[-60, 60], [1720, 60], [1720, 68], [-60, 68]], T.accent1, { opacity: 0.9, layers: 4, variance: 0.01, spread: 0.5 });
    P.wash([[-60, TOP - 4], [1720, TOP - 4], [1720, TOP + 3], [-60, TOP + 3]], T.accent1, { opacity: 0.9, layers: 4, variance: 0.01, spread: 0.5 });
  }

  function lanterns(set) {
    return (P) => {
      const { T } = P;
      const warm = mix(T.glow, T.accent1, 0.45);
      const spots = [];
      PIERS.forEach((x, i) => spots.push([x, 328, i % 2]));
      OPEN.forEach((o, i) => spots.push([o.cx, 286, (i + 1) % 2]));
      spots.filter((s) => s[2] === set).forEach(([x, y]) => {
        P.glow(x, y, 170, warm, 0.85, 'source-over');
        P.glow(x, y, 50, warm, 0.9, 'source-over');
      });
    };
  }

  // soft shadows of the columns on the near floor; the layer skews from the floor line
  function shadows(P) {
    const { T } = P;
    const c = mix(T.stone3, T.deep, 0.35);
    P.wet(10, (W) => {
      PIERS.forEach((x) => W.wash([[x - 64, FLOOR_NEAR], [x + 40, FLOOR_NEAR], [x - 110, 1120], [x - 300, 1120]], c, { opacity: 0.45, layers: 8, variance: 0.06, spread: 10, edge: 0 }));
      W.wash([[-60, FLOOR_NEAR], [1720, FLOOR_NEAR], [1720, FLOOR_NEAR + 26], [-60, FLOOR_NEAR + 26]], c, { opacity: 0.18, layers: 6, variance: 0.06, spread: 8, edge: 0 });
    });
  }

  function ink(K, T) {
    const gold = T.accent1;
    OPEN.forEach((o) => {
      K.line(o.intra, { w: 1.1, o: 0.7, jitter: 0.1 });
      K.line(o.extra, { w: 0.9, o: 0.5, jitter: 0.1 });
      K.line([[o.cx, APEX + 4], [o.cx, 250]], { w: 0.5, o: 0.5, color: gold, jitter: 0 });
      K.line(G.lathe(o.cx, [[2, 250], [10, 258], [15, 268], [15, 304], [9, 314], [3, 322]]), { w: 0.7, o: 0.7, closed: true, jitter: 0.05 });
      // spandrel panels framed in gold
      K.line([[o.x0 + 18, TOP + 16], [o.x1 - 18, TOP + 16]], { w: 0.7, o: 0.6, color: gold, jitter: 0.1 });
    });
    PIERS.forEach((x) => {
      K.line([[x - PHW, TOP], [x - PHW, SPRING]], { w: 0.9, o: 0.5, jitter: 0.1 });
      K.line([[x + PHW, TOP], [x + PHW, SPRING]], { w: 0.9, o: 0.5, jitter: 0.1 });
      K.line(G.rect(x - 60, 410, 120, 42), { w: 0.8, o: 0.55, closed: true, jitter: 0.1 });
      K.line(capital(x), { w: 0.9, o: 0.65, closed: true, jitter: 0.05 });
      K.line([[x - SHAFT_HW, 524], [x - SHAFT_HW, BASE_Y]], { w: 0.9, o: 0.55, jitter: 0.15 });
      K.line([[x + SHAFT_HW, 524], [x + SHAFT_HW, BASE_Y]], { w: 0.9, o: 0.55, jitter: 0.15 });
      // a few veins in the marble
      K.line(G.bez([x - 20, 556], [x - 2, 620], [x - 22, 700], [x + 2, 800], 10), { w: 0.4, o: 0.16, jitter: 0.3 });
      K.line(G.bez([x + 10, 600], [x + 22, 660], [x + 4, 700], [x + 14, 770], 8), { w: 0.35, o: 0.13, jitter: 0.3 });
      // capital detail: a band of small scallops (muqarnas, simplified)
      K.line([[x - 52, 470], [x + 52, 470]], { w: 0.6, o: 0.55, color: T.deep, jitter: 0.05 });
      const sc = [];
      for (let k = -4; k < 4; k++) G.arc(x + k * 11 + 5.5, 470, 5.5, 7, 0, Math.PI, 6).forEach((p) => sc.push(p));
      K.line(sc, { w: 0.5, o: 0.45, color: T.deep, jitter: 0.03 });
      K.line([[x - 38, 516], [x + 38, 516]], { w: 0.6, o: 0.5, color: T.deep, jitter: 0.05 });
      K.line(G.lathe(x, [[38, BASE_Y], [44, BASE_Y + 8], [44, BASE_Y + 18], [64, BASE_Y + 22], [64, FLOOR_NEAR]]), { w: 0.8, o: 0.55, closed: true, jitter: 0.1 });
      K.line(G.lathe(x, [[4, 280], [14, 292], [18, 300], [18, 356], [12, 366], [6, 378]]), { w: 0.7, o: 0.7, closed: true, jitter: 0.05 });
      K.line(G.star8(x, 236, 34), { w: 0.7, o: 0.8, closed: true, color: gold, jitter: 0.05 });
      K.line(G.star8(x, 236, 26), { w: 0.5, o: 0.6, closed: true, color: gold, jitter: 0.05 });
    });
    // parapet lattice: diamonds between the posts
    for (let x = 700; x < 1700; x += 118) {
      for (let k = 0; k < 4; k++) {
        const x0 = x + 9 + k * 25, cy = 758;
        K.line([[x0, cy], [x0 + 12.5, cy - 30], [x0 + 25, cy], [x0 + 12.5, cy + 30]], { w: 0.5, o: 0.32, closed: true, jitter: 0.2 });
      }
    }
    K.line([[560, 716], [1700, 716]], { w: 0.7, o: 0.4, jitter: 0.3 });
    K.line([[560, 800], [1700, 800]], { w: 0.7, o: 0.4, jitter: 0.3 });
    K.line([[560, 830], [1700, 830]], { w: 0.6, o: 0.35, jitter: 0.3 });
    // the far dome and minarets, lightly
    K.line(G.lathe(DOME_X, FAR_DOME.slice(0, 17)), { w: 0.6, o: 0.45, closed: true, jitter: 0.05 });
    // frieze: a running band of gold lozenges (geometric, no lettering)
    const z = [];
    for (let x = -40; x <= 1680; x += 28) z.push([x, 76], [x + 14, 106]);
    K.line(z, { w: 0.6, o: 0.65, color: gold, jitter: 0.1 });
    // the niche
    const n = G.cusped(G.pointed(NICHE.cx - NICHE.hw, NICHE.cx + NICHE.hw, NICHE.spring, NICHE.apex, 60, 0.3), 9, 12, NICHE.cx, NICHE.spring + 60);
    K.line([[NICHE.cx - NICHE.hw, NICHE.bottom]].concat(n, [[NICHE.cx + NICHE.hw, NICHE.bottom]]), { w: 1, o: 0.6, jitter: 0.08 });
    K.line([[NICHE.cx - NICHE.hw - 22, NICHE.bottom]].concat(G.pointed(NICHE.cx - NICHE.hw - 22, NICHE.cx + NICHE.hw + 22, NICHE.spring, NICHE.apex - 30, 60, 0.3), [[NICHE.cx + NICHE.hw + 22, NICHE.bottom]]),
      { w: 0.7, o: 0.55, color: gold, jitter: 0.08 });
    K.line([[-40, FLOOR_NEAR], [1680, FLOOR_NEAR]], { w: 0.7, o: 0.4, jitter: 0.4 });
  }

  GP.scenes.asr = {
    seed: 1530,
    focal: [DOME_X, 600],
    layers: [
      { id: 'hall', paint: paintHall, grain: { mottle: 0.26, tooth: 0.12 } },
      { id: 'shadows', paint: shadows, origin: [0, FLOOR_NEAR], grain: false },
      { id: 'lanterns-a', paint: lanterns(0), grain: false },
      { id: 'lanterns-b', paint: lanterns(1), grain: false },
    ],
    ink,
  };
})();
