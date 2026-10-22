# Go Pray Phase 0 spike: answers

Run 2026-10-22 on Ahmed's Mac (macOS 26.5, Xcode 26.6 / Swift 6.3, three displays: 1512x982 built-in, 1920x1080, 2560x1440). Binary signed "Developer ID Application: Ahmed Elgazar (3BB4JMG8GR)", unsandboxed, no hardened runtime. Code: `Sources/main.swift` (one binary, modes by argv), `build.sh`, `scripts/`. Evidence: `evidence/`.

Safety held: every shield had a 15 s hard cap (timer + background watchdog) and a Ctrl-Opt-Cmd-Q Carbon hotkey. The hotkey registered (status 0) but I did NOT test pressing it; the timers always fired first. Only apps I launched were touched.

## Bugs found in the plan's recipe (fix these in the real build)

1. **`NSPanel(contentRect:screen:)` treats the rect as screen-relative.** Passing `screen.frame` for the 2nd/3rd display doubled the origin (logged `{3024,-94}` instead of `{1512,-47}`), so panels landed on the wrong display and overlapped. Fix: create, then `panel.setFrame(screen.frame, display: true)`. (`evidence/q1-a-screensaver-noactivate.log` has the bad frames; later logs have the fixed ones.)
2. **`didResignActive` -> `activate()` ping-pongs.** With a re-activate handler, we got ~15 resign/activate pairs in the first 500 ms (every ~15 ms, `q2-*-opts.log`). Debounce: only re-activate if the frontmost app is not us, at most once per 250 ms.
3. **`WKWebView.loadFileURL` with a relative URL hangs the main thread forever** (sync XPC wait). `URLComponents(url: fileURL)` returns a relative URL. Build the string from `fileURL.absoluteString + "?query"`. Cost me a long debug; the watchdog caught it.
4. **`NSRunningApplication.hide()` returns `false` even when it works.** Never trust the return value; poll `isHidden` on the run loop (a blocking poll starves the KVO update and lies).

## 1. Panel at `.screenSaver` / `CGShieldingWindowLevel`, `.accessory` app

**Answer: yes to everything we could test. The shield is above a full-screen app's Space, above Spotlight, above Mission Control, and activating does not bump the Space.**

| Test | Result | Evidence |
|---|---|---|
| Above a full-screen app's Space (own red full-screen window on the built-in display), non-activating panel, level 1000, `canJoinAllSpaces + canJoinAllApplications + fullScreenAuxiliary + stationary` | Covers it. CG list shows our 3 windows `layer=1000 onscreen=true` next to Dock's `Fullscreen Backdrop`. | `q1-a-screensaver-noactivate-d1.png`, `.log` |
| Same with `CGShieldingWindowLevel()` (2147483628) | Covers it, all 3 displays | `q1-fs-shielding-level-shot.png`, `.log` |
| Above Spotlight (Cmd-Space) | Spotlight opened (CG window `Spotlight layer=23`, 720x137) but is drawn UNDER the shield; screenshot shows only the shield. Works at 1000 and at the shielding level. | `q1-spotlight-noactivate-shot.png` + `.log`, `q1-spotlight-shielding-*` |
| Above Mission Control (Ctrl-Up) | MC opened (Dock `layer=18` windows appeared) and the shield still covers it | `q1-missioncontrol-noopts-shot.png`, `.log` |
| Above the Cmd-Tab app switcher | Shield still on top; the switch itself happened (see Q2) | `q2-cmdtab-noopts-shot.png` |
| `NSApp.activate` + `makeKey` from a full-screen Space bumps to another Space? | **No.** Full-screen app got `didResignActive`, stayed `onActiveSpace=true`, zero `activeSpaceDidChange` events during the shield; it got focus back on dismiss. | `q1-fs-activate-opts.log`, `q1-fsapp2.log` |

Caveats:
- **Spotlight still opens under the shield and takes keyboard focus** when we are NOT activated with presentationOptions (1 run). Typing then goes to an invisible Spotlight. With `activate + reactivate + all presentationOptions`, Spotlight did NOT open in the 1 run I did (`q2-spotlight-opts.log`). n=1, treat as likely, not proven.
- The test full-screen app was my own (red window); Warp/Brave were frontmost at times, so "front app" in logs is noisy.
- Cmd-Space / Ctrl-Up were injected with CGEvent (synthetic). Screenshots do not capture Spotlight itself, so I used `CGWindowListCopyWindowInfo` layers as the proof.

**Real build:** non-activating `.screenSaver` panels (level 1000 is enough; no need for the shielding level) + activate/makeKey + presentationOptions as in the plan, with the three fixes above.

## 2. presentationOptions (`hideDock, hideMenuBar, disableProcessSwitching, disableForceQuit, disableHideApplication`)

**Answer: accepted without exception; read back as raw=362 (`q2-*-opts.log`), `menuBarVisible=false`. Cmd-Tab and Mission Control are blocked. Cmd-Opt-Esc: UNKNOWN.**

- Cmd-Tab (held 1.5 s), no options: app switched away (`didResignActive; front=Warp` at 4.2 s). With options: no switch (`q2-cmdtab-noopts.log` vs `q2-cmdtab-opts.log`). n=1 each.
- Mission Control (Ctrl-Up), no options: 3 Dock `layer=18` windows appeared. With options: 0 (`q1-missioncontrol-noopts.log` vs `q2-missioncontrol-opts.log`).
- hideDock / hideMenuBar: readback only (`menuBarVisible=false`). Visual effect UNKNOWN because the shield covers it anyway; it does not matter for the product.
- **Cmd-Opt-Esc (Force Quit): UNKNOWN.** The synthetic chord opened no Force Quit window even with options off (`q2-forcequit-noopts.log`), so there is no working negative control and I cannot claim `disableForceQuit` works. Needs a real keyboard test by Ahmed: start `GoPraySpike shield --seconds 15 --activate --opts hideDock,disableProcessSwitching,disableForceQuit` and press Cmd-Opt-Esc.
- The options only hold while we are active (re-activation needed, per plan).

**Real build:** keep the plan's set. Add a one-time manual Cmd-Opt-Esc check to the Phase 1 gate.

## 3. SMAppService.agent (RunAtLoad, KeepAlive SuccessfulExit=false)

**Answer: works, no approval needed, relaunches after `kill -9` instantly if the process has been up more than 10 s.**

- `register()` -> `status=1 (.enabled)` immediately; no Login Items approval step. macOS showed one banner: "GoPraySpike can run in the background" (`q3-register-documents.log`). Worked from a bundle inside `~/Documents` too (signed Developer ID).
- `launchctl print` shows `managed_by = com.apple.xpc.ServiceManagement`, `BundleProgram` resolved.
- `kill -9` when the agent had been up ~9 s: back after **2.0 s**. When it had been up >10 s: back after **0.007 s** (new pid already started; `q3-agent-starts.log`). Cause: launchd's default `ThrottleInterval` of 10 s between launches. Real build: the app is up for hours so relaunch is instant; set `ThrottleInterval` to 1 in the plist so a crash loop at start still recovers in ~1 s.
- Clean exit (SIGTERM -> `exit(0)`) stays down (`-  0  com.gopray.spike.agent`), as designed.
- **Unregistered and verified** (`q3-after-unregister-verify.txt`): `launchctl list | grep -i gopray` empty, no agent process. `sfltool dumpbtm` still lists two GoPraySpike records, both `Disposition: [disabled, allowed ...]` (app #49, agent #50). They are disabled leftovers in the Background Items database, not active; macOS keeps them until the bundle is gone. I did not run `sfltool resetbtm` because it would reset all of Ahmed's login items. Ahmed may see a greyed "GoPraySpike" under System Settings > Login Items; remove it there if wanted.

**Real build:** as planned, plus `ThrottleInterval=1`. Warn the user about the "can run in the background" banner at first register.

## 4. WKWebView in the panel, approved scenes from local files

**Answer: renders with no network, light on CPU, JS <-> Swift round-trip works.**

- Render: `loadFileURL(absoluteURL, allowingReadAccessTo: .../scenes)`, `didFinish` in 2248 ms; fonts `loaded`, scene has 4 layers; screenshot `q4-web-fajr-render.png` shows the full Fajr scene, Arabic text, ring, buttons. Copy of scenes lives in the bundle's `Resources/scenes` (shots/ dropped).
- "No network": static grep of scenes finds no `http` except the SVG namespace string; the page loaded entirely from `file://`. I did not cut the network (it is Ahmed's machine), so "works offline" is by construction, not by disconnect. `performance.getEntriesByType('resource')` is empty for file:// so it cannot prove it.
- Round-trip: JS `webkit.messageHandlers.gopray.postMessage('prayed')` received in Swift; `evaluateJavaScript` round-trip **30 ms** (`q4-web-fajr-render.log`).
- CPU (demo=0, chrome=0, real 10-min timers). `ps` cputime delta; app + WebContent + GPU helper. Windows were 54 s measured, not 60 s. The 60 s runs used a mouse-transparent **1280x720** window in the corner of the smallest display (NOT a shield, to respect the 15 s shield cap); the 15 s runs are real full-screen shields (9 s measured, includes the bloom animation).

| Scene | Setup | App | WebContent | GPU | Total (% of one core) | RSS total |
|---|---|---|---|---|---|---|
| isha | 1280x720 window, 54 s | 2.9 | 15.2 | 9.1 | **~27** | ~109 MB |
| fajr | 1280x720 window, 54 s | 2.7 | 6.3 | 4.7 | **~14** | ~87 MB |
| isha | full-screen shield, 9 s | 2.6 | 13.1 | 7.9 | **~24** | ~166 MB |
| fajr | full-screen shield, 9 s | 2.9 | 19.9 | 4.9 | **~28** (bloom) | ~147 MB |

  Not counted: WindowServer compositing. Evidence `q4-cpu-*.txt`. Isha is the heavier steady state (about double fajr). Fine for 10 minutes on a Mac; on battery it is a measurable but small drain. If it matters, the scenes already have a reduce-motion path.

**Real build:** ship the scene folder in the bundle, `loadFileURL` with an absolute URL, one `WKScriptMessageHandler` named `gopray` for `prayed`/`silence`. The 10 min gate stays in Swift (`BlockGate`), not in the page.

## 5. `NSRunningApplication.hide()` and re-hide on activation

**Answer: works unsandboxed, no permission prompt, hidden within 5-40 ms.**

- Test apps launched by me: Calculator and TextEdit (not running before; both quit afterwards; Terminal untouched because hiding it would hide Ahmed's windows).
- Initial hide: `isHidden=true` after 15 ms (TextEdit), 25 ms (Calculator). `hide()` itself returns `false` anyway (see bug 4).
- Re-hide after `didActivateApplicationNotification` (activation forced by `osascript ... activate`): hidden again after **5 ms** typical, 20-40 ms when two apps activated at once (`q5-hide.log`, 12 re-hides, all succeeded).
- No dialog or prompt appeared at any point. Visual flicker (app visible for one or two frames) is possible; not captured.
- Caveats: only two simple apps. Apps that refuse hide or full-screen apps are UNKNOWN (Phase 3 per plan). Note: the notification arrives AFTER activation, so there is always a few-ms window where the app is frontmost.

**Real build:** as the plan says (Mode B). Poll `isHidden` on the run loop, retry once at +100 ms if still visible.

## 6. Audio

**Answer: offset works. System mute: UNKNOWN by test, expected to be respected.**

- `AVAudioPlayer`, candidate `C-egypt-cairo-mahmoudeya-sheikhhamed-fajr.mp3` (195.2 s, 48 kHz stereo): `currentTime = 9.0` read back as 9.0, played 9.000 -> 11.9997 in 3.0 s, volume 0.1 (`q6-audio-candidate-offset9.log`). Content check with ffmpeg: first 3 s mean -42.9 dB (near silent lead-in), 9-12 s mean -16.6 dB (the voice), so 9.0 skips the lead-in (`q6-content-check.txt`).
- PrayTimes `Adhan-Egypt.mp3` (182.7 s, **mono, 11.025 kHz**): offset 0 and 9 both work (`q6-audio-praytimes-offset*.log`). Quality note: 11 kHz mono is low fidelity; check against the licence/quality bar before shipping it.
- Mute: Ahmed was not muted (`output muted:false`, volume 74). I did not toggle his mute. CoreAudio exposes the device mute property (`mute=0`) and AVAudioPlayer goes through the default device, so a muted Mac should be silent, but I could not capture audio to prove it. **UNKNOWN** empirically. Test by hand: mute, run `GoPraySpike audio --file <mp3> --offset 9 --secs 3 --vol 0.1`.

**Real build:** per plan (no CoreAudio override). Seeking: set `currentTime` after `prepareToPlay()`, before `play()`.

## Other findings

- A signed bundle in `~/Documents` runs fine for the agent and the shield. WebKit worked from there too (the first hang was the relative-URL bug, not TCC).
- Launching test processes from the shell raised a macOS banner "bash can run in the background" a few times; harmless.
- Not tested: Fast User Switching, sleep/wake during a shield, a second user, hot corners, Stage Manager, Cmd-Opt-Esc (see Q2).

## Reproduce

```
./build.sh
BIN=build/GoPraySpike.app/Contents/MacOS/GoPraySpike
$BIN shield --seconds 10 --level screensaver --activate --web fajr    # panel + WebKit scene
scripts/keytest.sh <name> cmdspace cmdspace --level screensaver       # chord tests (inject modes)
scripts/cpu.sh <name> isha webcpu 60                                  # needs the bundle copied to /private/tmp/gopray-spike
```
