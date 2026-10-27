# Go Pray design spec (excerpt for the Windows port)

Copied 2026-10-23 from the Mac app's design spec. The Mac SwiftUI views in `GoPray/UI/` are the reference for exact copy and layout; this file gives the rules (palette, type, tone, screens, motion, loading). Windows adaptations: use Segoe UI where the Mac uses SF Pro; tray icon instead of a menu bar icon; Fluent-style controls are fine but keep the palette, spacing and copy.

# Design Spec Sheet — Go Pray

One page that every screen and component must obey. Fill every section. Write UNKNOWN rather than guess. Built per Design Build Process.

Inputs: Go Pray (avatar, locked decisions), Architecture Plan, references.md, `design/inspiration/` (Ahmed's per-prayer pictures + `STYLE - Ortakoy watercolor.jpg`), Color Palettes to Test, UX Design Principles. Built prototype: `design/scenes/` (open `index.html`; screenshots in `design/scenes/shots/`).

> Updated 2026-10-22 to match the built scenes: full-bleed, code-drawn, one palette per prayer, no cream paper, no fixed PNGs. Scenes await Ahmed's review.

## Avatar + first principles
- **For:** a Muslim vibe coder (Ahmed first) deep in flow. Wants a stop at every Athan without remembering. Fears a lockout mid call, or an app so annoying he turns it off. Does not care about streaks, stats, feeds.
- **Job of the design:** make the stop feel like a kind tap on the shoulder, and make "when can I go back" obvious at a glance. One screen does the real work (the block). Everything else is small and quiet.
- **Code vs art:** code does all of it. Each prayer's scene is drawn in code as a watercolor-and-ink motion graphic (painted once, then a few quiet loops); type, ring and buttons sit over it. No image files, no image generation, no AI at runtime.
- **Delete:** anything that counts, scores or scolds. No history of missed prayers anywhere.

## 1. Product in one line
A Mac menu bar app that stops vibe coding at every Athan with a full-screen, hand-painted scene of that prayer, and lets you back after a 10-minute break. For a Muslim coder lost in flow. It must feel like a gentle hand on the shoulder, not a lock on the door.

## 2. Features (locked)
| Feature | In MVP / Defer / Cut | Screen(s) |
|---|---|---|
| Prayer times from a typed city, computed locally | MVP | Setup, Popover, Settings |
| Athan plays at prayer time | MVP | Block screen, Coding notice |
| Silence button (sound only, never the block) | MVP | Block screen, Coding notice |
| Whole-screen block on every display (default) | MVP | Block screen |
| Coding-apps-only mode (hide, re-hide, never quit) | MVP | Coding notice |
| 10-minute ring + "I prayed" (disabled until 10 min) | MVP | Block screen, Coding notice |
| Today's 5 times, next-prayer countdown, mode | MVP | Popover |
| City, method, Asr madhab, high-latitude rule, mode, Athan volume + preview, launch at login | MVP | Setup, Settings |
| Settings and mode read-only during a block | MVP | Settings, Popover |
| Athan voice picker | MVP (Ahmed, 2026-10-22): 28 PrayTimes voices (16 Sunni, 12 Shia; Yusuf Islam removed) + Fajr always Sheikh Hamed from 9.0 s; credits screen. See `audio/CREDITS.md` | Settings |
| "Use my location" | Defer (v1.1) | Setup |
| Countdown text in the menu bar itself | Defer | Menu bar |
| Jumu'ah toggle | Defer (v1.1) | Settings |
| Stats, streaks, history, accounts, sync, Qibla, Hijri date | Cut | — |
| Snooze, delay, emergency exit | Cut (locked: no escape) | — |

## 3. Mood
- Pinterest board: UNKNOWN (no board link). Mood source is the local folder `design/inspiration/` (5 prayer images + the style image).
- Mood words: **quiet, sacred, handmade, warm, unhurried.**
- One sentence on the feeling a first-time user should have: "Oh, it's time. Let me go pray, my work will be right here."
- Anti-mood: alarm, punishment, parental-control lockout, habit tracker, neon tech, dark-mode hacker UI.
- **Locked art style** (Ahmed, 2026-10-21): scenes are **drawn in code as motion graphics**, with the watercolor + ink *feel* of `STYLE - Ortakoy watercolor.jpg` (bottom half): loose washes, soft bleeding edges, fine ink linework, pigment granulation. Not flat vector, not 3D. **Cream paper is not required**: the scene fills the screen and each prayer has its own ground. From the Ortakoy title we keep the thin, widely spaced serif caps with a small rule under them.
- **One look per prayer, from its own picture** (Ahmed, 2026-10-21). The subject and the whole palette come from that prayer's inspiration picture; only `nabawi` (the "I prayed" green) is shared. **Isha uses the Kaaba picture as the main reference.** No human figures and no lettering in the art; architecture respectful and recognisable.

| Prayer | Scene | Palette read | Inspiration file |
|---|---|---|---|
| Fajr | Dark room, deep cusped-arch window, first light growing through it, dust in the shaft | Near-black + warm amber (no indigo: the picture has none) | `Fajir Prayer Inspiration.jpg` |
| Dhuhr | Clear blue sky, Nabawi green dome, cream minaret with brass finial, a dove crossing | Sky blue, Nabawi green, cream, brass | `Zuhur Prayer Inspiration.png` |
| Asr | White marble arcade, gold capitals and lanterns, green dome far off through the arch | Marble white, gold, green, pale sky | `Asr Prayer Inspiration.jpg` |
| Maghrib | Gold dome and minaret against amber haze, a flock wheeling, the sun sinking | Gold-amber, dusk grey, dark roofs | `Maghrib Prayer Inspiration.jpg` |
| Isha | Masjid al-Haram from above at night, the Kaaba at the centre, tawaf as lights circling counter-clockwise, clock tower faint | Black night, white light, gold arcade, clock-tower green | `Isha Prayer Inspiration.jpg` |

## 4. Palette
Rewritten 2026-10-22 by the scenes lane, to match `design/scenes/` (supersedes the single cream-paper palette: Ahmed ruled cream paper is not required and each prayer takes its palette from its own picture).

**Source.** Each prayer was sampled from its own inspiration picture: `magick <img> -colors 8 -unique-colors` plus averaged crops of the sky, stone and accent regions (quantize alone averages away thin accents). Marks: **(s)** sampled, **(d)** derived from a sample (lightened/darkened for contrast or as a shadow), **(e)** eyeballed because the region is too thin to sample (it averages into its neighbours).

**One token block.** All colours live in `design/scenes/styles.css` (`:root` + one `[data-prayer=…]` block per prayer). The scene JS reads them with `getComputedStyle`; it only mixes tokens, never adds a hex. Same 15 names in every prayer: `ground sky-1..3 stone-1..3 deep accent-1 accent-2 glow ink text text-soft ring`.

### Shared
| Token | Hex | Use |
|---|---|---|
| `nabawi` | `#3E6B3A` | "I prayed" fill once unlocked, every prayer |
| `on-nabawi` | `#F4EEE2` | label on the button (5.3:1) |

### Per prayer
| Prayer | Sky (`sky-1/2/3`) | Ground / architecture (`stone-1/2/3`, `deep`) | Accents (`accent-1`, `accent-2`, `glow`) | `ink` (linework) | `text` / `text-soft` | `ring` |
|---|---|---|---|---|---|---|
| **Fajr** | window light `#FEFCF5` (s), `#F5D4A0` (s), haze `#CFA371` (s) | pillar `#73492D` (s), wall `#513223` (s), shadow `#2A1A11` (d), near-black `#0E0705` (s) | shaft `#976742` (s), lit floor `#C3926B` (s), glow `#F5D4A0` (s) | `#120A06` (d) | `#F2E4CC` / `#C9B293` (d) | `#F5D4A0` (s) |
| **Dhuhr** | `#44687E` (s), `#829BA3` (s), `#A4ADAC` (s) | minaret `#FADAAB` (s), `#EDBC82` (s), shade `#A9825A` (d), `#2B3A24` (d) | dome `#58683D` (s), brass `#9B774F` (s), glow `#F0CD9F` (s) | `#1F2A2E` (d) | `#17232A` / `#34444B` (d) | `#2E4D60` (d) |
| **Asr** | `#DEE9F3` (s), `#D8DFE6` (s), haze `#E8DCCB` (d) | marble `#EEE9E2` (d), `#D6D1CE` (s), `#A8A19A` (s), `#4A3521` (s) | gold `#9C7F5C` (s), green dome `#447E6F` (s), lantern `#F6D9A2` (e) | `#2D1C0E` (s) | `#2D1C0E` (s) / `#5C4835` (s) | `#7A5C22` (d) |
| **Maghrib** | dusk `#D9C0C8` (s), amber `#EC9894` (s), near sun `#FEDCBC` (s) | haze `#DBA073` (s), `#94623D` (s), `#523B2B` (s), roofs `#1F1808` (s) | gold dome `#A36E30` (s), sun `#FEFDEE` (s), glow `#F1D9BD` (s) | `#241C0D` (s) | `#241C0D` (s) / `#4B3719` (d) | `#5C3A12` (d) |
| **Isha** | night `#08080F` (s), far city `#16151C` (s), tower `#1A191A` (s) | white light `#D3D3D4` (s), `#9D9B9C` (s), `#43423E` (s), Kaaba `#12141A` (s) | Kaaba band `#B8935A` (e), clock green `#4B8E72` (s), arcade light `#E2B97A` (e) | `#E9E6DF` (d, pale: night linework) | `#EDE9E1` / `#B9B4AA` (d) | `#62A38E` (s) |

`ground` is the colour shown before the paint blooms: Fajr `#0E0705`, Dhuhr `#F0EEE7` (paper, from the style reference), Asr `#F1ECE4`, Maghrib `#F1D9BD`, Isha `#08080F`.

### Contrast, measured on the painted scenes
Measured on 1440×900 renders: UI hidden, background under each text box cropped, blurred 2px (so paper grain does not count), linear-light Rec.709 luminance, worst case of the darkest and lightest pixel against the text colour. AA = 4.5 (small text), 3.0 (large text, the name, graphics).

| Prayer | Name (large) | Arabic (large) | Copy line (`text-soft`) | Numerals | Silence label | Ring stroke (graphic) |
|---|---|---|---|---|---|---|
| Fajr | 15.35 | 14.80 | 8.96 | 14.84 | 9.73 | 12.75 |
| Dhuhr | 5.06 | 7.09 | 5.30 | 9.46 | 6.82 | 5.11 |
| Asr | 9.68 | 9.87 | 5.26 | 10.83 | 5.86 | 3.81 |
| Maghrib | 6.55 | 8.04 | 6.41 | 11.59 | 7.65 | 6.22 |
| Isha | 13.99 | 13.80 | 8.04 | 15.59 | 9.53 | 5.12 |

All pass AA. Tightest: Dhuhr name 5.06 (the sky deepens toward the top; the paint is lifted under the text column on purpose), Asr ring 3.81 (gold on marble; the numerals inside carry the information). Menu bar popover still uses system colours; prayer accents appear there only as a 6pt dot.

## 5. Typography
| Role | Font | Weight | Size / line height |
|---|---|---|---|
| Display (prayer name, Latin caps) | Cormorant Garamond | Light 300 | clamp(34, 5% of screen height, 58) pt, tracking 0.4em, all caps, line height 1.0 |
| Display (prayer name, Arabic) | Amiri | Regular 400 | 0.9 × the Latin size, **no tracking**, line height 1.4 |
| Heading (setup titles, popover next prayer) | Cormorant Garamond | Regular 400 | 26/30 setup; 20/24 popover, tracking 0.25em caps |
| Countdown numerals | SF Pro Display | Light | 26% of ring diameter, `.monospacedDigit()` |
| "May Allah accept it." | Cormorant Garamond | Regular 400 italic | 0.72 × the name size |
| Body | SF Pro Text | Regular | 13/17 (macOS default); block-screen copy line 15/20 |
| Caption | SF Pro Text | Regular | 11/14 |
| Mono (coordinates field only) | SF Mono | Regular | 12/16 |

Licence and source for each font (bundled in the prototype as WOFF subsets in `design/scenes/fonts/` with their OFL texts; the app can bundle the same files):
- **Cormorant Garamond:** SIL Open Font License 1.1. Source: https://github.com/CatharsisFonts/Cormorant (also Google Fonts). OFL allows bundling in a sold app. Ship `OFL.txt` in the bundle; load via `ATSApplicationFontsPath` in Info.plist. Why: high contrast, very thin hairlines, closest free match to the Ortakoy title.
- **Amiri:** SIL Open Font License 1.1. Source: https://github.com/aliftype/amiri (also Google Fonts). Classic Naskh built to sit with old-style serifs like Garamond. Styles: Regular, Bold (+ italics). Note: development ended in 2022, so it is stable, not maintained. Fallback with the same licence: Noto Naskh Arabic.
- **SF Pro / SF Mono:** Apple system fonts, called through `.system()` so nothing is bundled. Apple's licence allows them only in apps for Apple platforms, which this is. Source: https://developer.apple.com/fonts/
- Why SF for numerals: Cormorant's default figures are old-style and jump around in a countdown. Lining + tabular figures in Cormorant are UNKNOWN; check in Phase 2, switch if they exist.

## 6. Shape and space
- **Spacing scale:** 4pt base: 4, 8, 12, 16, 24, 32, 48, 64, 96.
- **Corner radius:** buttons 10; coding notice panel 14; popover and settings use the system radius. No pills, no sharp 0.
- **Borders / shadows / depth rule:** no shadows on the block screen; depth comes only from the painted scene. Lines are 1pt `text` at 20–26% (button outlines, ring track) or 1pt `text` at 60% (the 40pt rule under the name, from the Ortakoy title). The disabled "I prayed" is a 7% `text` tint with a 1pt outline, never a solid plate over the art. Only the coding notice panel gets the standard macOS window shadow, because it floats over other apps.
- **Scene:** full-bleed on every display. Drawn in a 1600 × 1000 space and cover-fitted (centred; on 16:9 the top and bottom crop slightly, on 16:10 nothing crops). Every scene keeps its left ~38% calm (sky, wall, haze or a niche) so the text sits on quiet paint. Each scene's subject sits on the right.
- **Grid and safe areas (block screen, main display):** one column, 440pt max (36vw), its centre at **21% of the screen width**, vertically centred. Inside it, centred: name → 8 → Arabic → 16 → rule (40pt) → 24 → copy line → 32 → ring (clamp 120–188pt, 19% of screen height; stroke 1.6, track 0.9 in a 100-unit box) → 32 → "I prayed" (240 × 44) → 12 → Silence (ghost, 32 tall). About 500pt tall; fits 1440 × 900 with room. **Narrow screens** (aspect ≤ 5:4): the column moves to the bottom centre, 6% up from the bottom edge. "May Allah accept it." appears at the same spot as the column.
- **Other displays:** the same scene full-bleed + the name only. One set of buttons, on the main display (the one with the menu bar).
- **Art files:** none. Scenes are code: `design/scenes/watercolor.js` (engine + stage) and one module per prayer; the shield loads the same files in a WKWebView (Architecture Plan amendment). The old `design/art/*-v1.png` plan is dropped.

## 7. Components and references
Mobbin reference pull (2026-10-21, 21 mobbin.com links): references.md. Every row below cites a Mobbin link from it. 21st.dev items are React; we copy the pattern and rebuild it in SwiftUI.

| Screen | Mobbin reference | 21st.dev component | Notes |
|---|---|---|---|
| **Block screen** (whole screen) | [WHOOP breathing timer](https://mobbin.com/screens/2b556fce-4fd5-4267-abe9-d1c7409595d3), [Oura session start](https://mobbin.com/screens/04714b1c-e796-43a3-adf0-cfcfa226bcbc), [Insight Timer](https://mobbin.com/screens/7bf892dd-c66e-4a13-be51-3a9633d0a363), [Opal "Block Again"](https://mobbin.com/screens/f8792486-21e2-406f-8c52-86caf194e740), [Opal block screens](https://mobbin.com/screens/f378fff4-ead9-49b9-8231-8c776aeca98b) | [Circle Progress](https://21st.dev/@hihahihahoho/components/circle-progress/countdown.md) | The prayer's scene full-bleed behind everything (blooms in like wet paint, then lives quietly; §8–9). Left column, top to bottom: **DHUHR** → **الظهر** → rule → "Time to pray. Your work will be right here." → thin ring with `6:12` inside (fill = the prayer's `ring`, track = `text` 22%) → **I prayed** (disabled: 7% `text` tint, 1pt outline, `text-soft` label and a small lock; enabled: `nabawi` soaks in left to right, `on-nabawi` label) → **Silence** ghost button with `speaker.slash`, "Athan playing · Silence", shown while the Athan plays, then fades to 0 opacity in place (no reflow). After "I prayed": "May Allah accept it." for about 1 second while the shield fades. WHOOP/Oura give the ring, Insight Timer the quiet single control, Opal the locked-then-open button. Built: `design/scenes/index.html`. |
| **Coding-apps notice** (hidden app reopened, or block start in this mode) | [Opal "Block Again"](https://mobbin.com/screens/f8792486-21e2-406f-8c52-86caf194e740), [Oura session start](https://mobbin.com/screens/04714b1c-e796-43a3-adf0-cfcfa226bcbc) | Circle Progress | 400 × 560 panel, centred on the main display, radius 14, filled with the prayer's `ground`. A 400 × 200 crop of the prayer's scene at the top (bleeds to the edges; painted once, ambient loops off) → name + Arabic at 28pt → "**Cursor** is resting until you pray. Your agents keep running." (at block start: "Your coding apps are resting until you pray.") → ring 112pt → I prayed → Silence. Same per-prayer tokens as the block screen. |
| **Menu bar popover** | [Lumy sun times](https://mobbin.com/screens/e37f48a3-fb38-43c3-86b4-2ba29608408d), [Sunlitt widget](https://mobbin.com/screens/7f631834-4126-4bf3-b8de-10e2228b32f6), [Jomo widgets](https://mobbin.com/screens/fa1ae031-13bc-4eba-ad97-106f8f85b6f4), [Opal timer](https://mobbin.com/screens/9710c507-b950-414b-825c-ebc0f711c446) | [Countdown Timer with labels](https://21st.dev/@anubra266/components/countdown-timer/timer-w-labels.md) | 320pt wide, system material. Header: a 320 × 96 still of the next prayer's scene (painted once, no motion), then **ASR** (Cormorant caps) + "in 1 h 49 min" (Lumy). Five rows: name left, time right, tabular; next prayer gets a 6pt accent dot; past prayers in `secondaryLabelColor`. No ticks, no "prayed" marks. Mode chip (Opal timer): "Whole screen" / "Coding apps". Footer: city pill, e.g. "Toronto · ISNA · Shafi" (Lumy), Settings…, Quit. During a block: header reads "Dhuhr · 6:12 left", mode chip and Quit disabled. Menu bar icon: a thin arch (mihrab) template image, 18pt. |
| **First-run setup** (3 steps + done) | [Rodeo "Where do you live?"](https://mobbin.com/screens/226c5c8d-31d5-4b9e-b62f-44b6d7b4cee7), [Stardust city search](https://mobbin.com/screens/a7306060-9328-4460-8073-20954c7231d3), [Clue units picker](https://mobbin.com/screens/c439936f-f10f-4d6d-b7a2-c2147f30e173), [Bevel calculations](https://mobbin.com/screens/806f433a-9df1-4526-8aeb-1e9eb408fa4e), [Square segmented control](https://mobbin.com/screens/f80c7681-8e45-4ad3-8475-0b9ea227ae70) | none (native) | 520 × 600 window, system look, with a small still of the next prayer's scene across the top (no motion). **1. "Where do you pray?"** one search field, type-ahead (city bold, region below), Next disabled until picked; link "Enter coordinates instead". **2. "How are your times worked out?"** method radio list (default from library for the region) + Asr: Standard / Hanafi with one grey help line. **3. "How should Go Pray stop you?"** segmented Whole screen / Coding apps only, one line under each; Athan volume slider + Preview; Launch at login toggle (on). **Done:** "You're set. Next: Asr at 3:41 PM." The Waymo permission screen is not needed (no Location in v1). |
| **Settings** | [timespent settings](https://mobbin.com/screens/577d1ad8-3bb7-487c-b46f-9174ceef95ba), [Clue units picker](https://mobbin.com/screens/c439936f-f10f-4d6d-b7a2-c2147f30e173), [Bevel calculations](https://mobbin.com/screens/806f433a-9df1-4526-8aeb-1e9eb408fa4e), [Square segmented control](https://mobbin.com/screens/f80c7681-8e45-4ad3-8475-0b9ea227ae70) | none (native) | SwiftUI `Settings` scene, one grouped `Form`, system look. Groups: Location (city, Change…), Prayer times (method, Asr, high-latitude rule), Block (mode, segmented), Athan (volume + Preview; voice row deferred), General (Launch at login). During a block every control is disabled with one line on top: "Settings open again after you pray." That rule is enforced in `BlockGate`, not in the view. [Opal rule sheet](https://mobbin.com/screens/f1a122f3-33ab-4ca2-9677-cc3baf33072e)'s "Hold to Commit" is not used. |

## 8. Illustration, icons, mascot
- **Icon set and style:** SF Symbols at Light/Regular weight (`speaker.slash`, `lock`, `gearshape`, `location`); in the HTML prototype these are two small authored SVGs in `ui.js`. Menu bar icon: a thin mihrab-arch template image (unchanged).
- **Illustration source: drawn in code** (Ahmed, 2026-10-21; no image generation, no stock photos). `design/scenes/`: shared `watercolor.js` (engine + stage), one module per prayer (`fajr.js`, `dhuhr.js`, `asr.js`, `maghrib.js`, `isha.js`), `ui.js`, `styles.css`, `index.html` (preview). SVG + Canvas + vanilla JS, classic scripts, no CDN, no build, works from `file://` (checked) so a WKWebView can load the folder as is. Fonts bundled in `scenes/fonts/` (Cormorant Garamond variable + Amiri, WOFF subsets, OFL texts alongside). The inspiration pictures are mood only and are never shipped.
- **How the watercolor is made:** each static layer is painted once into an offscreen canvas as layered translucent washes (a polygon deformed by recursive midpoint displacement, 6–18 slightly different layers, Chaikin-smoothed edges, a faint darker rim where pigment pools). Skies and shading are painted wet-in-wet (drawn to a scratch canvas, then laid down blurred once). Then pigment mottling and paper tooth (soft-light noise) are baked in. Ink is SVG linework with a `feTurbulence` + `feDisplacementMap` wobble, line weight 0.4–1.3, and it draws itself in. Full-bleed scene drawn in a 1600×1000 space, cover-fitted; the UI sits in a calm column on the left (21% of the width) that every scene keeps quiet.
- **Scenes (no human figures, no lettering in the art):**
  - **Fajr:** dark room, a deep window with a seven-lobed cusped arch, the town's minaret faint in the haze outside; a light shaft falls onto the floor as the window's own shape; dust in the shaft.
  - **Dhuhr:** clear blue sky, Masjid an-Nabawi's green dome (bullet profile, ribs, drum of small arches, brass finial with crescent) and the cream minaret with its crescent finial, traced from the photo's proportions; a dove crosses.
  - **Asr:** a white marble arcade with cusped arches, gold capitals, eight-point star medallions, wall and hanging lanterns; the green dome far off through the arch; a blind mihrab-shaped niche frames the text.
  - **Maghrib:** amber sky with long streaked clouds, a gold onion dome and a tall minaret with a lit arcaded gallery against the sun, the town fading into haze, dark roofs in front; a flock wheeling.
  - **Isha:** Masjid al-Haram from above at night: the Kaaba (kiswa, gold band, door), the Hijr Ismail wall, Maqam Ibrahim, the mataf, the lit Ottoman arcade, the ring of small domes, white minarets with green galleries, the city, and the clock tower faint behind.
- **Mascot:** none.

## 9. Motion
- **Signature motion: the scene blooms in like wet paint (2.5s).** A low-resolution "reveal time" map (distance from the scene's focal point + fractal noise) is thresholded each frame and stretched up smoothly, so the paint spreads from the focal point with an uneven, feathered wet front over the `ground` colour; easing spreads fast then soaks in slowly (`1 − (1−t)^2.4`). Focal points: Fajr the window, Dhuhr the dome, Asr the far dome, Maghrib the sun, Isha the Kaaba. The ink draws in with `stroke-dashoffset` (1.5s, nearest the focal point first, up to 1.3s stagger). The text column fades up from 1.7s (500ms, 60ms stagger, 6px rise).
- **Then it lives quietly (ambient loops only):**
  - **Fajr:** the light layer brightens from 38% to 100% across the whole block (the first light grows as the 10 minutes pass); about 90 dust motes drift and catch the light only inside the shaft.
  - **Dhuhr:** one dove crossing (about 20s, flaps in bursts then glides), then a pause of 18–34s.
  - **Asr:** two sets of lantern glow breathe out of phase (7s); column shadows on the floor slowly skew from their bases as the sun moves (90s, alternate).
  - **Maghrib:** 28 birds wheel round the minaret (a 34s loop, flapping out of step, smaller and paler on the far side); the sun layer sinks 3.2vh across the block.
  - **Isha:** tawaf as 2,600 small lights circling the Kaaba **counter-clockwise as seen from above**, slow and continuous (about 84s per circuit at mid-radius, inner rings quicker), with a faint trail behind each. Lights on the far side pass behind the Kaaba. Minaret and arcade lights breathe very slightly (9s).
- **Smaller moments:** the ring fills like ink, one tick per second (1s linear, eased one second ahead so it lands on the wall-clock value). At 0:00 "I prayed" soaks to `nabawi` from left to right (400ms clip-path) and the lock fades out. Silence fades to 0 in place (no reflow), on tap or when the Athan ends. **After "I prayed":** the column fades (200ms), "May Allah accept it." (Cormorant italic) comes up in 250ms, and the whole shield fades over 1s with the line still showing.
- **Budget (it runs full screen for 10+ minutes):** static art is painted once (measured 60–150ms per scene at 1440×900 @2x); after the bloom the paint canvases never redraw. Moving parts are either compositor-only CSS (opacity/transform on pre-rendered layers: Fajr light, Asr lanterns and shadows, Maghrib sun, Isha lights) or one "live" canvas capped at **30fps**, measured at 0.04–0.8ms per frame (Isha's 2,600 lights is the most). Asr has no JS loop at all. The loop stops when the page is hidden. No per-frame filters: the SVG wobble filter only re-rasterises during the 2.5s draw-in.
- **Tool and authoring path:** vanilla Canvas 2D + SVG + CSS animations, no libraries. The shield hosts the same files in a WKWebView (Architecture Plan amendment).
- **Reduce Motion** (`prefers-reduced-motion`, or the preview toggle): no bloom. The finished scene crossfades in over 200ms with the ink already drawn. All ambient loops stop: the light layers hold at 85%, the dove/birds/dust are not drawn, and the tawaf lights are drawn once, frozen. UI is opacity only, with no rise. The button switches state instantly; the shield fades in 150ms after the 1s "May Allah accept it." The ring still updates every second (it is information).
- **Preview** (`design/scenes/index.html`): keys 1–5 or the chips switch prayer; D toggles demo (20s instead of 10 min, Athan 9s); M toggles Reduce Motion; R replays. URL params: `?prayer=isha&demo=0&reduce=1&chrome=0`.

## 10. UX principle check
Run against UX Design Principles before build; re-run on built screens (block screen re-run 2026-10-22 on the prototype).
- **Block screen:** Emphasis and Hierarchy pass if the order reads scene → name → ring → button. Risk: a full-bleed scene could out-shout the name. Fix if it does: calm that scene's left side (lift or thin the paint there), never shrink the name. Negative space: pass. Contrast: pass, measured on the painted pixels (§4).
- **Coding notice:** pass. Risk: the app name line gets long ("Visual Studio Code is resting…"); cap at one line, truncate the app name.
- **Popover:** Proximity and Alignment pass with tabular times. Risk: the scene header pushes the five times below the fold on small popovers; keep it at 96pt.
- **Setup / Settings:** pass (native controls, one question per step).
- **Resolved:** the bright-cream-at-night risk is gone. Fajr and Isha are dark scenes (near-black grounds, light text).

## 11. Do-not list
- No red, no alarm icons, no warning triangles on the block screen.
- No streaks, counts, badges, history, "missed" labels or ticks for prayed. Anywhere.
- No guilt copy ("You missed…", "Don't break…"), no exclamation marks, no emoji.
- No snooze-looking or "5 more minutes" controls; nothing that looks like an exit.
- **Never letter-space Arabic** (it breaks the joined letters). Tracking applies to Latin caps only.
- Gold and brass accents are never text and never the only cue; the ring always has numerals inside.
- No photos, Pinterest images or generated images in the app; scenes are code. No human figures and no lettering (real or fake) in the art. No glassmorphism or drop shadows over the scene.
- No spinners in content areas (actions only).
- No second set of buttons on secondary displays.

## 12. Loading and empty states
**Skeletons (async regions):**
- **City search results** (geocoder call): 3 skeleton rows matching the result row (a 140pt bar for the city, an 80pt bar under it), in the system's quaternary fill, slow shimmer off under Reduce Motion.
- **Scene** (painted on first show, 60–150ms): the prayer's `ground` colour fills the exact scene frame first and is the skeleton; the paint then blooms over it, so nothing shifts. Same for the popover header and the coding-notice crop.
- **Not async, no skeleton:** prayer times (local math), the ring, settings values.
- **Action spinners (allowed):** "Next" while geocoding the picked city; "Preview" while the Athan file loads.

**Empty-state copy:**
- Popover before setup: "Add your city to see today's prayer times." + **Set up**.
- City search, no match: "No match. Try a bigger city nearby, or enter coordinates."
- City search, offline: "Can't reach the map service right now. Check your connection, or enter coordinates."
- Settings during a block: "Settings open again after you pray."
- Block screen while the Athan plays: the ghost button reads "Athan playing · Silence" (Architecture Plan §4), so a muted Mac is still clear.
