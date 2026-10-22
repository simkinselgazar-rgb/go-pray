# Contract notes (core lane, 2026-10-22)

Changes and clarifications to Architecture Plan "Final plan (2026-10-22)" §C made while building core. Owner: PM. Lanes read this before they start. Anything not listed here is exactly as in the plan.

## Contract changes (in `GoPray/Core/Contracts.swift`)

1. **`PrayerScheduleProviding.times(on:)` and `nextAthan(after:)` return optionals.** `nil` means "no valid schedule" (bad lat/lon, adhan-swift's failable `PrayerTimes` init returned nil). Reason: §G "bad schedule → no block" needs a way to say "no schedule". The gate and scheduler then never block. Lane A: return `nil`, never a made-up time.
2. **`Voice` is also `Codable`.** `Settings.voice` is saved to disk.
3. **The `Settings` struct lives in `Contracts.swift`** (the shape is the contract, §C.5). Lane A adds defaults, validation and `SettingsStore` as *extensions* in `Prayer/Settings.swift` / `Prayer/SettingsStore.swift`. Do not add or rename fields without a PM amendment. adhan-swift enums are stored as raw values so Core never imports Adhan:
   - `method: String` = `CalculationMethod.rawValue`
   - `madhab: Int` = `Madhab.rawValue` (1 shafi, 2 hanafi)
   - `highLatitudeRule: String?` = `HighLatitudeRule.rawValue`, `nil` = `HighLatitudeRule.recommended(for:)`
   - `SettingsError.blocked` is also in `Contracts.swift`.
4. **Name clash:** adhan-swift exports its own `Prayer` (with `.sunrise`). Inside our module `Prayer` is ours; write `Adhan.Prayer` for theirs.

## BlockGate API (`GoPray/Core/BlockGate.swift`)

5. Matches §C.3, plus:
   - `phase` is a **computed** get-only property (from the state + the clock), so clock jumps apply at once. Same external API as `private(set) var`.
   - `init` has **no `lockDuration:` param** any more: the lock comes from `Settings.lockMinutes` and is captured per block (#26). It has two extra defaulted params, `leavingTimeout: Duration = .seconds(4)` and `systemReduceMotion: () -> Bool`.
   - `authorizeSettingsChange() throws` (`SettingsError.blocked` during a block). **Lane A: `SettingsStore.mutate` calls this first for every change**, including mode, `lockMinutes` and pause/resume.
   - Read-only extras for UI: `currentBlock`, `hiddenAppName`, `shieldContext()`, `state`.
   - `BlockGate` is `@Observable` (lane A: read `gate.isBlocked` in views; use `TimelineView` for countdowns, since `phase` follows the clock).
   - `BlockGate` is the `ShieldDelegate`. It sets `shield.delegate = self` in `init`. Lane B never sets the delegate.
6. **Two private exits, both only in `BlockGate.swift`:** `endBlock()` (the confirmed end; one caller, `requestConfirm()`) and `failOpen(_:)` (window closed, next Athan replaces, crash loop, no schedule). `guard.sh` checks both.
7. **Lane B (shield):**
   - When the gate refuses `prayed`, it calls `shield.update(ctx)` with the true remaining time. That is the re-sync: on `update`, call `GoPrayBridge.show(ctx)` again.
   - Fail-open paths call `tearDown()`, which must work from any state, including during a `dismiss` fade.
   - Call `dismiss`'s completion on the main actor. If it is not called within 4 s, the gate calls `tearDown()` and goes idle anyway.
   - Gate order on a new block: write `state.json`, start the hider (coding mode), `audio.play`, then `shield.show(ctx)`.
8. **Lane C (audio):** `play` throwing is logged and the block still starts. `onFinished` → the gate sends `shield.update` with `athanRemainingMs = 0`. A relaunch never replays (`athanPlayed` is written `true` together with the block).
9. **Lane D (hider):** `start()` is called at block start *and* again on a relaunch that resumes a block in coding mode; `stop()` on every exit. Both must be safe to call more than once. `onReHide` after the block ended is ignored.

## state.json

10. **New optional field `lastDropped: {prayer, athanAt}`** (still schema v1; older files decode). It records a prayer given up by a fail-open rule while its window was still open (crash loop, corrupt or impossible file), so the wake rule does not block it again.
11. **"Done" rule:** a window whose Athan is at or before `max(lastConfirmed.athanAt, lastDropped.athanAt)` is never blocked again. This is how "clock back before a confirmed Athan → no second block" (§E.5) works with only one `lastConfirmed` record.
11b. **`block.lockSeconds`**: the lock length is copied from `Settings.lockMinutes` (clamped) when the block starts. Changing the setting later never shortens, ends or extends a running block, and that holds across a relaunch. A missing field decodes as 600. The gate never honours more than 1800 s (a tampered file cannot trap).
12. Dates are ISO 8601 with fractional seconds (plain ISO 8601 also decodes), so a resumed block keeps its exact start.
13. Launch-time validation: `blockStartedAt` more than 60 s before `athanAt`, or more than 60 s in the future → quarantine (`state.corrupt-<unix>.json`) + idle + the open window is dropped. While running, a clock that goes back only opens the button (clamp); it never quarantines.

## Scheduler

14. `scheduler.handle(_ reason:)` is the one entry for events: the gate re-evaluates, then the timer re-arms. Lane A's `SettingsStore` change hook calls `scheduler.handle(.settingsChanged)`. The timer is armed for the next Athan or the next local midnight, whichever is first. There is no re-arm on confirm, because confirming does not change the next Athan. **While paused, no Athan is armed**: the timer wakes at `pausedUntil` (kind `.pauseEnds` → `gate.reevaluate(.pauseEnded)`), or at midnight if that comes first (always for "until resumed"). Lane A calls `scheduler.handle(.settingsChanged)` after a pause or resume.

## Project

15. **`project.yml` (XcodeGen 2.45.3) is the source of `GoPray.xcodeproj`.** After editing it, run `xcodegen generate`. The PM owns both. `GoPray/` and `GoPrayTests/` are file-system-synchronized groups, so lanes just add files.
16. `GoPray/Resources/scenes/` and `GoPray/Resources/athan/` are **folder references**: they are copied as `Contents/Resources/scenes/...` and `Contents/Resources/athan/...` with subfolders kept, not flattened. Use `Bundle.main.url(forResource:withExtension:subdirectory:)` with `"scenes"` or `"athan/sunni"`. The `.gitkeep` placeholders can be deleted once real files land. `Info.plist` sets `ATSApplicationFontsPath = fonts` (see #35).
17. **Build phases (already in the project):**
    - "Guards" runs `scripts/guard.sh` on every build.
    - "Check scene manifest" runs `scripts/check-manifest.sh` if it exists and is executable (lane B).
    - "Install launch agent plist" copies `GoPray/Launch/com.ahmedelgazar.gopray.agent.plist`, if present, to `Contents/Library/LaunchAgents/`. `Launch/*.plist` is kept out of Resources (lane C).
18. Module name is `GoPray` (`@testable import GoPray`). The product is `Go Pray.app` and the bundle id is `com.ahmedelgazar.gopray`. Debug is ad-hoc signed with no hardened runtime, so hosted tests load. Release is Developer ID, team 3BB4JMG8GR, hardened runtime.
19. `Package.resolved` lives at `GoPray.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. adhan-swift is pinned to `a6fa2deee80c5abb0b9ad04466f8ab12b53144e7` (tag 1.5.0).
20. Tests use **Swift Testing** (`import Testing`). Recording fakes for every lane protocol live in `GoPrayTests/Core/Fakes.swift` (`FakeSchedule`, `FakeShield`, `FakeAudio`, `FakeHider`, `Harness`). Reuse them; do not edit them, add your own beside them. Tests run hosted in the app. In DEBUG, the app skips live wiring when it sees the XCTest environment, and a test asserts this.
21. Build and test from a worktree (keep DerivedData out of the vault):
    ```
    xcodebuild -project GoPray.xcodeproj -scheme GoPray -derivedDataPath <scratch>/dd -clonedSourcePackagesDirPath <scratch>/dd/spm test
    ```
22. `guard.sh` extras beyond §C.7:
    - also bans `addGlobalMonitorForEvents`, `disableSessionTermination`, and debug entry points outside `#if DEBUG`
    - `--strict` (ship) requires exactly one `allowingReadAccessTo`; before lane B lands, zero is allowed
    - `--release <Go Pray.app>` checks a Release binary for debug strings (§E.10)
    - `// comments` are stripped before matching

## Lock length + pause (PM amendment, Ahmed 2026-10-22)

26. **`Settings.lockMinutes: Int`**: 10–30, default 10. The rules live in `LockPolicy` (`Contracts.swift`): `minMinutes = 10`, `maxMinutes = 30`, `defaultMinutes = 10`, `clamp(_:)`, `seconds(forMinutes:)`. The value is captured into state.json at block start (#11b). `ReevalReason` gains `.pauseEnded`.
27. **`Settings.pausedUntil: Date?`**:
    - `nil` means active.
    - `.distantFuture` means "until I resume".
    - A past date also means active.
    - Choices come from `PauseOption` (`.oneDay`, `.threeDays`, `.oneWeek`, `.untilResumed`); use `.until(from: now)`. Calendar days, so a DST change does not shift it.
    - **Pause and resume are allowed only between prayers.** `authorizeSettingsChange()` throws during a block. A pause that slips past the store anyway neither ends nor shortens the running block (tested).
    - **To resume, set `pausedUntil = now`.** `nil` also works while the app is running.
    - Gate rule (stateless): a window whose Athan came before `pausedUntil` is never blocked. This covers a pause that ran out while the Mac was asleep or the app was down.
28. **First setup and resume never block the open window** (PM ruling a). When `setupComplete` goes false → true, or a pause ends (by expiry or resume), the gate marks the open window as dropped (`lastDropped`). Blocks start again at the next Athan.

## §E.3, read it this way (PM ruling b)

29. **Wake after the old prayer's window closed:**
    - The old prayer is missed and is never blocked.
    - If another prayer's window is open now, that prayer blocks at wake (`blockStartedAt` = wake), per §3.
    - If nothing is open (e.g. after sunrise, before Dhuhr) → idle.
    - Where §E.3 says "→ idle", it means "no block for the missed prayer", not "idle no matter what".

## Not built

30. Debug "Set clock to <date>". It needs a FakeClock in the live app. Deferred.

## Shield (lane B, PM amendment 2026-10-22)

31. **`ShieldContext` gains `blockStartedAt: Date?` and `lockSeconds: Int`** (both defaulted, so existing initialisers compile; `lockSeconds == 0` = unknown). `BlockGate.shieldContext()` fills them from `state.json` (`block.blockStartedAt`, the captured lock). The page gets `lockMs` and `bridge.js` re-pins the ring offset to the true progress (`ui.js` untouched), so a relaunch mid-block no longer restarts the ring at 0.
32. **`index.html` (the preview page) is not shipped.** `Resources/scenes` holds the eight approved scene files + fonts (byte-identical to `design/scenes`) and the app-only `shield.html`, `bridge.js`, `shield.css`, all in `MANIFEST.sha256`.
33. **Coding notice is 420 x 520**: scene band on top (no text on the art), the prayer's ground colour below, forced reduce-motion. Secondary displays and the notice always run reduced.
34. **Bridge additions (not in §C.6):** `GoPrayBridge.dismiss()` (Swift asks the page to play "May Allah accept it." when the gate confirmed without a click) and `GoPrayBridge.violations()` (CSP violation count, for tests). `show` payload carries `lockMs` and `reduceMotion`.

## Wiring (PM, lane-wire, 2026-10-22)

35. **Native fonts:** `GoPray/Resources/fonts/` (folder reference → `Contents/Resources/fonts/`) holds TTFs of Cormorant Garamond (variable) and Amiri from google/fonts, with their OFL files. `ATSApplicationFontsPath = fonts`. ATS cannot load WOFF, so the scene WOFFs in `scenes/fonts` stay for the web page only (manifest unchanged).
36. **One copy at a time** (`App/SingleInstance.swift`, PM ruling 2026-10-22). The agent plist has RunAtLoad, so `register()` starts a second copy. The choke point is `flock(LOCK_EX)` on `~/Library/Application Support/GoPray/instance.lock` (the one support folder, S6): only the holder wires gate, menu and shield. The launchd copy (`XPC_SERVICE_NAME` = the agent label) that finds it taken waits for it on a background thread with no menu icon; the kernel releases it on exit or kill -9, so the waiter then wires and resumes from state.json. A hand-opened copy that finds it taken posts the distributed notification `com.ahmedelgazar.gopray.show` (the holder opens Setup or Settings) and exits 0. A hand-opened holder exits 0 (hand-over) once the agent is registered, the launchd copy runs, nothing is blocked and no window is open. An unopenable lock file never stops the app (it wires). Launch at login off: the hand copy is the only copy, no KeepAlive (the user's choice, stated in the README).
37. **Setup and Settings windows** are AppKit-hosted (`App/Windows.swift`); Setup opens at launch while `setupComplete == false`. `WebPrewarm` loads the shield page once in no window at launch.
38. **Debug only** (`Debug/DebugMenu.swift`, all `#if DEBUG`): "Trigger Athan now (20 s lock)" per mode for the open/next prayer (needs setup done); user default `GoPrayDebugHideOnly` (comma-separated bundle IDs) replaces the coding-apps list; launch argument `-GoPrayDebugSeed toronto` does Setup's Finish (Toronto, ISNA, volume 0.15, login agent re-registered). `guard.sh --release` now scans every binary in `Contents/MacOS` (Debug keeps its code in `Go Pray.debug.dylib`) and also checks `GoPrayDebugHideOnly` / `GoPrayDebugSeed`.
39. **Debug blocks resume (DEBUG only):** `debugTriggerAthan` writes `block.debugWindowEnd` (= trigger + 1 h) to state.json; `BlockGate.window(of:)` uses it as the block's window (capped at 1 h), so a relaunch mid-block resumes with the original start like a real block. The field and key exist only in DEBUG (`guard.sh` checks the source and the Release binary).
40. **Support folder choke point:** `StateStore.supportBase()` is the one place that picks `~/Library/Application Support` (state, settings, stills, instance lock). In a DEBUG test host (`TestHost.isActive`) it is a per-process temp folder; Release has no switch.
41. **Tests never read the source tree at run time** (it lives under ~/Documents; macOS privacy can refuse the test host). The GoPrayTests "Copy test fixtures" phase copies `scripts/check-manifest.sh` and the design `scenes/` into the test bundle's `Fixtures/`; the login agent plist is read from the app bundle.
42. **Ship-gate item: upgrade in place.** `brew upgrade` and replacing the .app by hand must leave the login agent working (no `EX_CONFIG` / `BTMErrorDomain -95` spawn loop; kill -9 still relaunches). Test before every release. A rebuilt ad-hoc debug app at the same path was refused by Background Items until re-registered from a new path; whether a Developer ID upgrade does the same is UNKNOWN. At launch `AppDelegate.wire()` (GoPrayApp.swift) asks `SingleInstance.shouldRepairAgent(status:setupComplete:launchAtLogin:)` and, if yes, calls `LoginAgent.register()`: re-register on `.notFound` / `.notRegistered`, never on `.requiresApproval` (the person's System Settings choice).
43. **Cask uninstall** quits the app and removes the `com.ahmedelgazar.gopray.agent` launchd job; `zap` removes `Application Support/GoPray` (state, settings, stills, the instance lock), the cache and the prefs plist. Note: `brew uninstall` during a block ends it (removing the job stops the process). Accepted: an admin action, not a reflex (§A).
44. **Launch at login off from the launchd copy** (found live 2026-10-22): `SMAppService.unregister()` stops the running agent job. So `SettingsViewModel.setLaunchAtLogin(false)` saves the setting FIRST (a refused save never unregisters; a failed unregister puts it back), and `LoginAgent.unregister()` called from the launchd copy first starts a successor (`open -n -g <bundle> --args -GoPraySuccessor YES`). The successor waits for the instance lock and wires up when the old copy is gone (it gives up after 30 s if the old copy stays). The launch-time repair runs only after setup (`setupComplete && launchAtLogin`), so a first run never registers before the person chooses.
45. **Opening the app while it runs** sends a reopen, not a new copy: `applicationShouldHandleReopen` shows Setup or Settings. The lock's "ask the holder" path covers `open -n` and a second install.
46. **No window under the shield** (pre-ship review S1): `AppDelegate.showRequested()` returns while `gate.isBlocked`, so a reopen or `show` request cannot open Setup or Settings during a block.
47. **`spike/evidence/` is not in the tree** (S7): the spike screenshots show Ahmed's own screens and must never go public. The directory is deleted from the tree and `spike/evidence/` + `spike/build/` are in `.gitignore`. History is NOT rewritten here: the PM squashes history before the first public push, so the PNGs vanish from every commit then. `spike/ANSWERS.md` stays.

## Pause other media (PM, lane-media, 2026-10-22)

48. **`AthanPlayer.play` pauses the system Now Playing app** (`Audio/MediaPauser.swift`, private MediaRemote, `kMRPause` = 1 only) right before it starts the sound. It never resumes. A relaunch never pauses because it never replays (#8). A throw before the sound (unknown voice, missing or undecodable file) never pauses. No wait before `p.play()` (the shield order in #7 stays). Calls are not Now Playing, so they are untouched (no call detection in v1). `guard.sh` rule 11 pins the API to that file. `AthanPlaying`, `Contracts.swift` and `GoPrayApp` wiring are unchanged. Tests use `FakeMediaPauser` and only check that the symbol loads; they never send a real pause. Not App Store safe (README).
