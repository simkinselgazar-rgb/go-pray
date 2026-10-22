/* Maghrib — sunset. A great gold dome and a tall minaret dark against amber haze, the town
   fading into light behind; a flock of birds wheeling round the minaret; the sun sinking
   almost imperceptibly across the block. Reference: "Maghrib Prayer Inspiration.jpg". */
(function () {
  'use strict';
  const GP = window.GoPray;
  const { G, mix, rgba } = GP.wc;

  const SUN = [1395, 585];
  const DOME_X = 860, MIN_X = 1215;

  // onion dome profile, top → bottom
  const ONION = G.bez([0, 336], [36, 352], [150, 396], [128, 482], 22).concat(G.bez([128, 482], [122, 530], [114, 548], [112, 560], 8).slice(1));
  const MINARET = [
    [1.5, 380], [10, 386], [22, 396], [31, 412], [34, 426], [30, 438], [22, 444], [28, 444], [30, 456], [50, 458], [52, 470],
    [36, 472], [36, 552], [56, 552], [56, 572], [50, 580], [40, 594], [36, 602], [36, 880],
  ];

  function paintSky(P) {
    const { T, ctx } = P;
    ctx.fillStyle = T.ground;
    ctx.fillRect(-60, -60, 1720, 1120);
    P.wet(16, (W) => {
      W.ctx.fillStyle = W.lin(0, -60, 0, 760, [[0, T.sky1], [0.16, mix(T.sky1, T.sky2, 0.5)], [0.45, T.sky2], [0.78, mix(T.sky2, T.sky3, 0.6)], [1, T.sky3]]);
      W.ctx.fillRect(-60, -60, 1720, 1160);
      // the light spreads sideways from the sun
      W.glow(SUN[0], SUN[1], 900, T.sky3, 0.7, 'source-over', 420);
    });
    // long streaks of cloud, darker above, lit along their lower edges
    P.wet(3.5, (W) => {
      [
        [-60, 70, 900, 18, 0.32], [520, 40, 1200, 14, 0.28], [180, 150, 760, 12, 0.26], [900, 175, 800, 16, 0.3],
        [-60, 236, 640, 10, 0.2], [700, 268, 1000, 11, 0.22], [1150, 340, 600, 9, 0.18], [280, 330, 520, 8, 0.16],
      ].forEach(([x, y, len, th, o]) => {
        const pts = [[x, y], [x + len * 0.3, y - th * 0.6], [x + len * 0.7, y - th * 0.4], [x + len, y + th * 0.2], [x + len * 0.65, y + th], [x + len * 0.25, y + th * 0.8]];
        W.wash(pts, mix(T.sky1, T.stone2, 0.35), { opacity: o, layers: 10, variance: 0.1, spread: 10, edge: 1.2, smooth: 3 });
        W.wash(pts.map(([px, py]) => [px, py + th * 0.7]), T.sky3, { opacity: o * 0.8, layers: 6, variance: 0.08, spread: 8, edge: 0.4, smooth: 3 });
      });
    });
  }

  // the sun, on its own layer so it can sink behind the haze across the block
  function paintSun(P) {
    const { T } = P;
    P.glow(SUN[0], SUN[1], 520, T.sky2, 0.55, 'screen', 300);
    P.glow(SUN[0], SUN[1], 170, T.sky3, 0.85);
    P.dot(SUN[0], SUN[1], 30, T.accent2, 1);
    P.glow(SUN[0], SUN[1], 46, T.accent2, 0.9);
  }

  function paintTown(P) {
    const { T } = P;
    // far town in the haze: pale, low, a few domes and minarets
    P.wet(4, (W) => {
      const far = mix(T.stone1, T.sky3, 0.25);
      const line = [[-60, 742], [80, 742], [80, 724], [150, 724], [150, 736], [300, 736], [300, 716], [360, 716], [360, 730], [520, 730], [520, 712], [600, 712], [640, 700],
        [1300, 700], [1320, 690], [1380, 690], [1380, 708], [1460, 708], [1470, 690], [1560, 690], [1560, 712], [1720, 712], [1720, 1100], [-60, 1100]];
      W.wash(line, far, { opacity: 0.55, layers: 8, variance: 0.03, spread: 3 });
      [[230, 24, 716], [470, 18, 712], [1440, 22, 690], [1600, 26, 690]].forEach(([x, r, y]) => W.wash(G.arc(x, y, r, r * 1.1, Math.PI, 2 * Math.PI, 14), far, { opacity: 0.55, layers: 6, variance: 0.03, spread: 1.5 }));
      [[400, 600], [1505, 560], [1650, 610]].forEach(([x, top]) =>
        W.wash(G.lathe(x, [[1, top], [5, top + 14], [7, top + 30], [11, top + 34], [11, top + 40], [7, top + 44], [7, 740]]), far, { opacity: 0.55, layers: 6, variance: 0.03, spread: 1 }));
    });
    // middle town: warmer, a step darker
    P.wet(2.5, (W) => {
      const mid = mix(T.stone2, T.stone1, 0.45);
      W.wash([[-60, 812], [140, 812], [140, 790], [260, 790], [260, 804], [420, 804], [430, 784], [560, 784], [560, 800], [700, 800],
        [1080, 800], [1080, 770], [1180, 770], [1330, 780], [1330, 760], [1480, 760], [1480, 782], [1720, 782], [1720, 1100], [-60, 1100]], mid,
        { opacity: 0.7, layers: 8, variance: 0.03, spread: 2 });
      W.wash(G.arc(1420, 760, 40, 46, Math.PI, 2 * Math.PI, 16), mid, { opacity: 0.7, layers: 6, variance: 0.03, spread: 1.5 });
    });

    // the mosque: block, iwan, drum, onion dome, corner kiosks — warm, hazed toward the top
    const block = [[688, 642], [1042, 642], [1042, 860], [688, 860]];
    P.wash(block, P.lin(0, 640, 0, 860, [[0, mix(T.stone2, T.stone1, 0.35)], [1, T.stone2]]), { opacity: 0.95, layers: 10, variance: 0.02, spread: 1.2 });
    const iwan = [[812, 860]].concat(G.pointed(812, 918, 760, 690, 16, 0.3), [[918, 860]]);
    P.wash(iwan, mix(T.stone3, T.stone2, 0.3), { opacity: 0.85, layers: 8, variance: 0.02, spread: 1 });
    P.wash([[836, 860]].concat(G.pointed(836, 894, 790, 744, 10, 0.3), [[894, 860]]), T.stone1, { opacity: 0.4, layers: 6, variance: 0.03, spread: 1 });
    // a row of small arched windows across the block
    for (let x = 712; x < 1030; x += 26) {
      if (x > 800 && x < 930) continue;
      P.wash([[x, 732]].concat(G.pointed(x, x + 12, 712, 702, 4, 0.3), [[x + 12, 732]]), T.stone3, { opacity: 0.45, layers: 4, variance: 0.02, spread: 0.6 });
    }
    // drum
    const drum = G.rect(DOME_X - 112, 560, 224, 84);
    P.wash(drum, mix(T.stone2, T.stone1, 0.25), { opacity: 0.95, layers: 8, variance: 0.02, spread: 1 });
    for (let a = -72; a <= 72; a += 18) {
      const s = Math.sin((a * Math.PI) / 180), c = Math.cos((a * Math.PI) / 180);
      const x = DOME_X + 112 * s;
      P.wash([[x - 6 * c, 628]].concat(G.pointed(x - 6 * c, x + 6 * c, 596, 584, 4, 0.3), [[x + 6 * c, 628]]), T.stone3, { opacity: 0.5, layers: 4, variance: 0.02, spread: 0.6 });
    }
    // the gold dome, lit from the sun on the right
    const dome = G.lathe(DOME_X, ONION);
    P.wash(dome, T.accent1, { opacity: 0.97, layers: 10, variance: 0.02, spread: 1, smooth: 1 });
    P.clip(dome, () => P.wet(18, (W) => {
      W.wash([[DOME_X + 10, 350], [DOME_X + 150, 420], [DOME_X + 140, 560], [DOME_X + 40, 560]], mix(T.accent1, T.sky3, 0.6), { opacity: 0.8, layers: 10, variance: 0.15, spread: 20 });
      W.wash([[DOME_X - 160, 400], [DOME_X - 50, 370], [DOME_X - 60, 560], [DOME_X - 160, 560]], mix(T.accent1, T.stone3, 0.5), { opacity: 0.6, layers: 10, variance: 0.15, spread: 20 });
      W.glow(DOME_X + 70, 440, 40, T.sky3, 0.55, 'screen', 70);
    }));
    P.fill(G.rect(DOME_X - 1.5, 292, 3, 46), T.accent1);
    P.dot(DOME_X, 318, 5.5, T.accent1);
    P.fill(G.arc(DOME_X, 296, 7, 7, -0.1 * Math.PI, 1.1 * Math.PI, 12).concat(G.arc(DOME_X, 293, 5.5, 5.2, 1.05 * Math.PI, -0.05 * Math.PI, 12)), T.accent1);
    // corner kiosks
    [712, 1018].forEach((x) => {
      P.wash(G.rect(x - 16, 600, 32, 44), mix(T.stone2, T.stone1, 0.2), { opacity: 0.95, layers: 6, variance: 0.02, spread: 0.8 });
      P.wash(G.rect(x - 8, 610, 16, 30), mix(T.sky3, T.stone1, 0.3), { opacity: 0.7, layers: 4, variance: 0.02, spread: 0.6 });
      P.wash(G.lathe(x, [[1, 570], [10, 580], [18, 594], [19, 600]]), T.accent1, { opacity: 0.95, layers: 6, variance: 0.02, spread: 0.8 });
    });

    // the minaret: backlit, so darker, with light coming through its arcaded gallery
    const mbody = G.lathe(MIN_X, MINARET);
    P.wash(mbody, P.lin(0, 380, 0, 880, [[0, T.stone2], [1, mix(T.stone3, T.stone2, 0.3)]]), { opacity: 0.97, layers: 10, variance: 0.02, spread: 1 });
    P.clip(mbody, () => {
      P.wet(10, (W) => W.wash(G.rect(MIN_X + 8, 370, 70, 520), mix(T.stone2, T.glow, 0.4), { opacity: 0.55, layers: 8, variance: 0.06, spread: 6 }));
      // the gallery openings show the bright sky through
      for (let k = -2; k <= 2; k++) {
        const x = MIN_X + k * 13;
        P.wash([[x - 4.5, 546]].concat(G.pointed(x - 4.5, x + 4.5, 490, 480, 4, 0.3), [[x + 4.5, 546]]), mix(T.sky3, T.sky2, 0.4), { opacity: 0.95, layers: 4, variance: 0.02, spread: 0.5 });
      }
      // carved panels down the shaft
      [[620, 700], [720, 800]].forEach(([y0, y1]) => P.wash(G.rect(MIN_X - 26, y0, 52, y1 - y0), T.stone3, { opacity: 0.3, layers: 6, variance: 0.03, spread: 1 }));
    });
    P.fill(G.rect(MIN_X - 1.2, 336, 2.4, 46), T.accent1);
    P.dot(MIN_X, 362, 4.2, T.accent1);
    P.fill(G.arc(MIN_X, 340, 6, 6, -0.1 * Math.PI, 1.1 * Math.PI, 12).concat(G.arc(MIN_X, 337.5, 4.6, 4.4, 1.05 * Math.PI, -0.05 * Math.PI, 12)), T.accent1);

    // a cool veil of haze over everything below the sun line
    P.wet(30, (W) => W.wash([[-60, 640], [1720, 620], [1720, 860], [-60, 880]], T.sky3, { opacity: 0.18, layers: 8, variance: 0.1, spread: 30, edge: 0 }));

    // foreground roofs, dark, low on the left so the words sit on sky
    P.wet(1.6, (W) => {
      const fg = [[-60, 900], [120, 900], [120, 884], [250, 884], [262, 874], [380, 874], [380, 890], [540, 890], [540, 870], [640, 870], [660, 858],
        [760, 858], [760, 846], [980, 846], [980, 830], [1080, 830], [1090, 812], [1170, 812], [1170, 836], [1290, 836], [1290, 818], [1420, 818],
        [1420, 800], [1540, 800], [1540, 826], [1720, 826], [1720, 1100], [-60, 1100]];
      W.wash(fg, W.lin(0, 800, 0, 1000, [[0, T.stone3], [0.4, T.deep], [1, T.deep]]), { opacity: 0.97, layers: 10, variance: 0.02, spread: 1.5 });
      W.wash(G.arc(320, 874, 52, 40, Math.PI, 2 * Math.PI, 16), T.stone3, { opacity: 0.95, layers: 8, variance: 0.02, spread: 1.2 });
      W.wash(G.arc(1350, 818, 46, 38, Math.PI, 2 * Math.PI, 16), T.stone3, { opacity: 0.95, layers: 8, variance: 0.02, spread: 1.2 });
      [[1108, 798, 14], [1135, 798, 12]].forEach(([x, y, r]) => W.wash(G.ellipse(x, y, r, r * 0.9, 12), T.stone3, { opacity: 0.9, layers: 6, variance: 0.02, spread: 1 }));
    });
  }

  function ink(K) {
    K.line(G.lathe(DOME_X, ONION), { w: 1.1, o: 0.6, closed: true, jitter: 0.06 });
    K.line(G.rect(DOME_X - 112, 560, 224, 84), { w: 0.9, o: 0.5, closed: true, jitter: 0.1 });
    K.line([[688, 642], [1042, 642], [1042, 860]], { w: 0.9, o: 0.5, jitter: 0.15 });
    K.line([[688, 860], [688, 642]], { w: 0.9, o: 0.5, jitter: 0.15 });
    K.line([[812, 860]].concat(G.pointed(812, 918, 760, 690, 16, 0.3), [[918, 860]]), { w: 0.9, o: 0.55, jitter: 0.08 });
    // ribs of the dome
    [-0.55, -0.2, 0.2, 0.55].forEach((s) => K.line(ONION.filter((_, i) => i > 3).map(([w, y]) => [DOME_X + w * s, y]), { w: 0.5, o: 0.3, jitter: 0.1 }));
    K.line(G.lathe(MIN_X, MINARET), { w: 1, o: 0.6, closed: true, jitter: 0.06 });
    [[472, 36], [552, 56], [572, 56], [602, 36], [700, 36], [800, 36]].forEach(([y, hw]) => K.line(G.band(MIN_X, y, hw, 2, 10), { w: 0.7, o: 0.5, jitter: 0.08 }));
    for (let k = -2; k <= 2; k++) {
      const x = MIN_X + k * 13;
      K.line([[x - 4.5, 546]].concat(G.pointed(x - 4.5, x + 4.5, 490, 480, 4, 0.3), [[x + 4.5, 546]]), { w: 0.5, o: 0.5, jitter: 0.03 });
    }
  }

  // a flock wheeling round the minaret: they keep together on a slow loop, flapping out of step
  function live(env) {
    const { T, rng } = env;
    const R = rng(91);
    const near = rgba(mix(T.deep, T.stone3, 0.4), 0.88);
    const far = rgba(mix(T.stone3, T.sky2, 0.45), 0.75);
    const birds = [];
    for (let i = 0; i < 28; i++) {
      birds.push({ off: R.gauss() * 0.42, r: 150 + R.gauss() * 32, dy: R.gauss() * 18, ph: R() * 6.28, f: R.range(2.6, 3.6), sz: R.range(0.8, 1.2) });
    }
    return {
      draw(ctx, t) {
        const cx = MIN_X + 40 * Math.sin(t * 0.05), cy = 448 + 18 * Math.sin(t * 0.071);
        const A = -t * ((2 * Math.PI) / 34); // one loop every ~34 s
        ctx.lineCap = 'round';
        ctx.lineJoin = 'round';
        birds.forEach((b) => {
          const a = A + b.off;
          const depth = Math.sin(a); // >0: the near side of the loop
          const x = cx + b.r * Math.cos(a) * 1.25;
          const y = cy + b.r * 0.34 * depth + b.dy;
          const s = b.sz * (1 + 0.22 * depth) * 1.15;
          const fl = Math.sin(t * b.f * Math.PI * 2 + b.ph);
          const w = 9 * s, tip = -6 * s * fl, mid = -1.5 * s + 1.5 * s * fl;
          ctx.strokeStyle = depth > 0 ? near : far;
          ctx.lineWidth = 1.9 * s;
          ctx.beginPath();
          ctx.moveTo(x - w, y + tip);
          ctx.quadraticCurveTo(x - w * 0.45, y + mid - 2 * s, x, y);
          ctx.quadraticCurveTo(x + w * 0.45, y + mid - 2 * s, x + w, y + tip);
          ctx.stroke();
        });
      },
    };
  }

  GP.scenes.maghrib = {
    seed: 1818,
    focal: SUN,
    layers: [
      { id: 'sky', paint: paintSky, grain: { mottle: 0.3, tooth: 0.14 } },
      { id: 'sun', paint: paintSun, grain: false },
      { id: 'town', paint: paintTown, grain: { mottle: 0.28, tooth: 0.14 } },
    ],
    ink,
    live,
  };
})();
