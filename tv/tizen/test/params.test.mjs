// node app/tv/tizen/test/params.test.mjs : pure logic of the Tizen app (logic.js), fake localStorage + fake clock.
import { createRequire } from 'node:module';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const L = require(path.join(here, '..', 'logic.js'));

let pass = 0, fail = 0;
function t(name, fn) {
  try { fn(); pass++; } catch (e) { fail++; console.log('FAIL ' + name + '\n  ' + String(e.message).split('\n').join('\n  ')); }
}
const mem = () => { const m = new Map(); return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), _m: m }; };
const at = (y, mo, d, h = 12, mi = 0, s = 0) => new Date(y, mo - 1, d, h, mi, s);
const q = (s) => L.parseQuery(s);

// ---- parseQuery
t('valid prayer + voice', () => assert.deepEqual(q('prayer=asr&voice=sunni.Minshawi'), { prayer: 'asr', voice: 'sunni.Minshawi', test: false }));
t('leading ?', () => assert.equal(q('?prayer=fajr').prayer, 'fajr'));
t('prayer is lower-cased', () => assert.equal(q('prayer=MAGHRIB').prayer, 'maghrib'));
t('test=1 only', () => { assert.equal(q('prayer=asr&test=1').test, true); assert.equal(q('prayer=asr&test=true').test, false); assert.equal(q('prayer=asr&test=2').test, false); });
t('invalid prayer -> null', () => { for (const p of ['', 'sunrise', 'asr ', 'asr1', 'fajr;x', '__proto__', 'constructor']) assert.equal(q('prayer=' + p), null, p); });
t('path-ish prayer -> null', () => { assert.equal(q('prayer=../x'), null); assert.equal(q('prayer=..%2Fx'), null); assert.equal(q('prayer=%2e%2e/asr'), null); });
t('no prayer key -> null', () => { assert.equal(q('voice=sunni.Minshawi'), null); assert.equal(q(''), null); assert.equal(q('garbage'), null); });
t('non-strings -> null', () => { for (const v of [undefined, null, 5, {}, []]) assert.equal(q(v), null); });
t('bad percent escape does not throw', () => assert.equal(q('prayer=%E0%A4%A'), null));
t('unknown keys dropped', () => assert.deepEqual(Object.keys(q('prayer=asr&evil=<script>&x=1')).sort(), ['prayer', 'test', 'voice']));
t('oversize string refused', () => assert.equal(q('prayer=asr&' + 'a=1&'.repeat(1000)), null));
t('__proto__ key harmless', () => assert.equal(q('__proto__=x&prayer=asr').prayer, 'asr'));

// ---- parseVoice
t('known sunni voice', () => assert.deepEqual(L.parseVoice('sunni.Minshawi'), { group: 'sunni', stem: 'Minshawi' }));
t('known shia voice', () => assert.deepEqual(L.parseVoice('shia.Tookhi'), { group: 'shia', stem: 'Tookhi' }));
t('group case folds', () => assert.equal(L.parseVoice('SUNNI.Minshawi').group, 'sunni'));
t('unknown voice -> default', () => { for (const v of ['', 'x', 'sunni.Nobody', 'shia.Minshawi', 'sunni.', '.Minshawi', 'sunni.minshawi', 'sunni.../../x', '__proto__.x', undefined, null, 7]) assert.deepEqual(L.parseVoice(v), { group: 'sunni', stem: 'Adhan-Makkah' }, String(v)); });
t('voice table matches the files on disk', () => {
  const root = path.join(here, '..', '..', '..', 'GoPray', 'Resources', 'athan');
  for (const g of ['sunni', 'shia']) {
    const disk = readdirSync(path.join(root, g)).filter((f) => f.endsWith('.mp3')).map((f) => f.slice(0, -4)).sort();
    assert.deepEqual([...L.KNOWN_VOICES[g]].sort(), disk, g);
  }
});
t('voice table matches Roku KnownVoices', () => {
  const brs = readFileSync(path.join(here, '..', '..', 'roku', 'components', 'AthanScene.brs'), 'utf8');
  for (const g of ['sunni', 'shia']) {
    const m = brs.match(new RegExp(g + ': \\[([^\\]]*)\\]'));
    const roku = m[1].split(',').map((s) => s.trim().replace(/"/g, ''));
    assert.deepEqual(roku, L.KNOWN_VOICES[g], g);
  }
});

// ---- audio file + label (built from the table only)
t('audioFile', () => {
  assert.equal(L.audioFile('asr', L.parseVoice('shia.Tookhi')), 'audio/shia.Tookhi.mp3');
  assert.equal(L.audioFile('fajr', L.parseVoice('shia.Tookhi')), 'audio/fajr.mp3');
  assert.equal(L.audioFile('isha', L.parseVoice('../../etc/passwd')), 'audio/sunni.Adhan-Makkah.mp3');
});
t('labelFor', () => {
  assert.equal(L.labelFor('asr', L.parseVoice('sunni.Abdul-Basit')), 'Athan · Abdul Basit');
  assert.equal(L.labelFor('fajr', L.parseVoice('sunni.Minshawi')), 'Athan · Sheikh Hamed');
});

// ---- findParams: AppControl shapes (the real one is UNKNOWN until Friday step 5)
const QS = 'prayer=asr&voice=sunni.Minshawi';
t('data = [{key,value:[qs]}] any key', () => { for (const k of ['PAYLOAD', 'metaTag', 'x', '']) assert.equal(L.findParams([[{ key: k, value: [QS] }]]).prayer, 'asr', k); });
t('value as plain string', () => assert.equal(L.findParams([[{ key: 'k', value: QS }]]).prayer, 'asr'));
t('PAYLOAD JSON holding the qs', () => assert.equal(L.findParams([[{ key: 'PAYLOAD', value: [JSON.stringify({ values: { metaTag: QS } })] }]]).prayer, 'asr'));
t('PAYLOAD JSON array', () => assert.equal(L.findParams([[{ key: 'PAYLOAD', value: [JSON.stringify([{ metaTag: QS }])] }]]).prayer, 'asr'));
t('location.search as a source', () => assert.equal(L.findParams([[], '?' + QS]).prayer, 'asr'));
t('first valid wins, invalid skipped', () => assert.equal(L.findParams([[{ key: 'a', value: ['prayer=bogus'] }, { key: 'b', value: ['prayer=isha&voice=shia.Tookhi'] }, { key: 'c', value: [QS] }]]).prayer, 'isha'));
t('nothing usable -> null', () => { for (const s of [[], [[]], [[{ key: 'a', value: ['hello'] }]], [null], [undefined], [[{ key: 'a', value: [42] }]], ['']]) assert.equal(L.findParams(s), null); });
t('no throw on hostile shapes', () => {
  const deep = []; let c = deep; for (let i = 0; i < 100; i++) { const n = []; c.push(n); c = n; } c.push(QS);
  assert.equal(L.findParams([deep]), null);   // too deep: ignored, not a crash
  assert.equal(L.findParams(['{"a":']), null);
});

// ---- bandPrayer boundaries
const band = (h, m) => L.bandPrayer(at(2026, 10, 30, h, m));
t('hour bands', () => {
  const cases = [[2, 59, 'isha'], [3, 0, 'fajr'], [9, 59, 'fajr'], [10, 0, 'dhuhr'], [14, 59, 'dhuhr'], [15, 0, 'asr'], [17, 29, 'asr'], [17, 30, 'maghrib'], [19, 14, 'maghrib'], [19, 15, 'isha'], [23, 59, 'isha'], [0, 0, 'isha']];
  for (const [h, m, want] of cases) assert.equal(band(h, m), want, h + ':' + m);
});

// ---- dayKey
t('dayKey pads', () => assert.equal(L.dayKey(at(2026, 3, 4), 'asr'), '2026-03-04/asr'));

// ---- decide
const T0 = at(2026, 10, 30, 15, 30);
const P = (s) => q(s);

t('first launch plays, records', () => {
  const s = mem(); const d = L.decide(s, P('prayer=asr&voice=sunni.Minshawi'), T0);
  assert.equal(d.action, 'play'); assert.equal(d.prayer, 'asr'); assert.equal(d.rec, true); assert.equal(d.resume, false); assert.equal(d.debug, false); assert.equal(d.fallback, false);
  assert.equal(s.getItem('gopray.last'), '2026-10-30/asr'); assert.equal(s.getItem('gopray.phase'), 'playing'); assert.equal(s.getItem('gopray.voice'), 'sunni.Minshawi');
  assert.equal(s.getItem('gopray.start'), String(Math.floor(T0.getTime() / 1000)));
});
t('test=1 plays, never records, shows debug', () => {
  const s = mem(); const d = L.decide(s, P('prayer=asr&test=1'), T0);
  assert.equal(d.action, 'play'); assert.equal(d.rec, false); assert.equal(d.debug, true); assert.equal(s._m.size, 0);
});
t('test=1 plays again and again, even after a real Athan ended', () => {
  const s = mem(); L.decide(s, P('prayer=asr'), T0); L.finish(s);
  for (let i = 0; i < 3; i++) assert.equal(L.decide(s, P('prayer=asr&test=1'), new Date(T0.getTime() + 1000 * (i + 1))).action, 'play');
  assert.equal(s.getItem('gopray.phase'), 'ended');
});
t('repeat while playing + alive -> resume with elapsed', () => {
  const s = mem(); L.decide(s, P('prayer=asr&voice=shia.Tookhi'), T0);
  const t1 = new Date(T0.getTime() + 40000);
  L.beat(s, new Date(T0.getTime() + 38000));
  const d = L.decide(s, P('prayer=asr&voice=sunni.Minshawi'), t1);
  assert.equal(d.action, 'play'); assert.equal(d.resume, true); assert.equal(d.elapsed, 40); assert.equal(d.tailLeft, 0);
  assert.deepEqual(d.voice, { group: 'shia', stem: 'Tookhi' }, 'resume keeps the voice that started it');
});
t('repeat while playing but heartbeat stale (>12 s) -> exit', () => {
  const s = mem(); L.decide(s, P('prayer=asr'), T0);
  assert.equal(L.decide(s, P('prayer=asr'), new Date(T0.getTime() + 13000)).action, 'exit');
});
t('heartbeat exactly 12 s old still resumes', () => {
  const s = mem(); L.decide(s, P('prayer=asr'), T0);
  assert.equal(L.decide(s, P('prayer=asr'), new Date(T0.getTime() + 12000)).action, 'play');
});
t('repeat during tail -> tail only, tailLeft counted', () => {
  const s = mem(); const st = { resumed: false, started: false };
  L.decide(s, P('prayer=asr'), T0);
  const tEnd = new Date(T0.getTime() + 200000);
  L.record(s, 'tail', st, tEnd);                      // tailEnd = +30
  const d = L.decide(s, P('prayer=asr'), new Date(tEnd.getTime() + 10000));
  assert.equal(d.action, 'play'); assert.equal(d.resume, true); assert.equal(d.tailLeft, 20);
});
t('tailLeft never below 1', () => {
  const s = mem(); const st = { resumed: false, started: false };
  L.decide(s, P('prayer=asr'), T0);
  L.record(s, 'tail', st, new Date(T0.getTime() + 100000));
  L.beat(s, new Date(T0.getTime() + 131000));
  assert.equal(L.decide(s, P('prayer=asr'), new Date(T0.getTime() + 131000)).tailLeft, 1);
});
t('repeat after ended -> exit at once', () => {
  const s = mem(); L.decide(s, P('prayer=asr'), T0); L.finish(s);
  assert.equal(L.decide(s, P('prayer=asr'), new Date(T0.getTime() + 5000)).action, 'exit');
});
t('different prayer same day plays', () => {
  const s = mem(); L.decide(s, P('prayer=asr'), T0); L.finish(s);
  assert.equal(L.decide(s, P('prayer=maghrib'), new Date(T0.getTime() + 3600000)).action, 'play');
});
t('next day plays', () => {
  const s = mem(); L.decide(s, P('prayer=asr'), T0); L.finish(s);
  assert.equal(L.decide(s, P('prayer=asr'), at(2026, 10, 31, 15, 30)).action, 'play');
});
t('record playing sets start once; resumed keeps start', () => {
  const s = mem(); const st = { resumed: false, started: false };
  L.decide(s, P('prayer=asr'), T0);
  L.record(s, 'playing', st, new Date(T0.getTime() + 2000));
  assert.equal(s.getItem('gopray.start'), String(Math.floor(T0.getTime() / 1000) + 2));
  L.record(s, 'playing', st, new Date(T0.getTime() + 9000));
  assert.equal(s.getItem('gopray.start'), String(Math.floor(T0.getTime() / 1000) + 2));
  const s2 = mem(); const r = { resumed: true, started: false };
  L.decide(s2, P('prayer=asr'), T0); L.record(s2, 'playing', r, new Date(T0.getTime() + 20000));
  assert.equal(s2.getItem('gopray.start'), String(Math.floor(T0.getTime() / 1000)));
});
t('tailEnd = +30 s and not rewritten', () => {
  const s = mem(); const st = { resumed: false, started: false }; L.decide(s, P('prayer=asr'), T0);
  const a = new Date(T0.getTime() + 100000);
  L.record(s, 'tail', st, a); const te = s.getItem('gopray.tailEnd');
  assert.equal(te, String(Math.floor(a.getTime() / 1000) + 30));
  L.record(s, 'tail', st, new Date(a.getTime() + 5000)); assert.equal(s.getItem('gopray.tailEnd'), te);
});
t('beat does nothing when ended or empty', () => {
  const s = mem(); L.beat(s, T0); assert.equal(s._m.size, 0);
  L.decide(s, P('prayer=asr'), T0); L.finish(s); const before = s.getItem('gopray.alive'); L.beat(s, new Date(T0.getTime() + 9000)); assert.equal(s.getItem('gopray.alive'), before);
});
t('finish on an empty store writes nothing', () => { const s = mem(); L.finish(s); assert.equal(s._m.size, 0); });

// ---- fallback (no usable params)
t('no params -> hour band + default voice + debug', () => {
  const s = mem(); const d = L.decide(s, null, at(2026, 10, 30, 6, 0));
  assert.equal(d.prayer, 'fajr'); assert.equal(d.fallback, true); assert.equal(d.debug, true); assert.deepEqual(d.voice, { group: 'sunni', stem: 'Adhan-Makkah' }); assert.equal(d.action, 'play');
});
t('no params -> last received voice', () => {
  const s = mem(); L.decide(s, P('prayer=maghrib&voice=shia.Salimi'), at(2026, 10, 29, 18, 0)); L.finish(s);
  const d = L.decide(s, null, at(2026, 10, 30, 18, 0));
  assert.equal(d.prayer, 'maghrib'); assert.deepEqual(d.voice, { group: 'shia', stem: 'Salimi' });
});
t('a corrupt stored voice -> default', () => {
  const s = mem(); s.setItem('gopray.voice', '<img src=x onerror=1>');
  assert.deepEqual(L.decide(s, null, T0).voice, { group: 'sunni', stem: 'Adhan-Makkah' });
});
t('fallback launch is de-duped too', () => {
  const s = mem(); L.decide(s, null, T0); L.finish(s);
  assert.equal(L.decide(s, null, new Date(T0.getTime() + 60000)).action, 'exit');
});
t('test=1 does not change the last-received voice', () => {
  const s = mem(); L.decide(s, P('prayer=asr&voice=shia.Tookhi&test=1'), T0);
  assert.equal(s.getItem('gopray.voice'), null);
});
t('prayer=../x falls back to band, never a path', () => {
  const p = L.findParams([[{ key: 'k', value: ['prayer=../x&voice=sunni.Minshawi'] }]]);
  assert.equal(p, null);
  const d = L.decide(mem(), p, at(2026, 10, 30, 11, 0));
  assert.equal(d.prayer, 'dhuhr'); assert.equal(L.audioFile(d.prayer, d.voice), 'audio/sunni.Adhan-Makkah.mp3');
});
t('storage that throws is not logic.js problem, but decide on a fresh store never throws on odd values', () => {
  const s = mem(); s.setItem('gopray.last', '2026-10-30/asr'); s.setItem('gopray.phase', 'playing'); s.setItem('gopray.alive', 'abc'); s.setItem('gopray.start', 'x');
  assert.equal(L.decide(s, P('prayer=asr'), T0).action, 'exit');
});

console.log(`tizen params tests: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
