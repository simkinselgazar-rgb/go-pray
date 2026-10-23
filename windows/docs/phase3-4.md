# Phases 3–4: tray, Setup, Settings, Credits, audio, media pause, hider, autostart (2026-10-23)

Screenshots: `docs/phase3-screens/`. They come from `GoPray.exe --debug-screens` (DEBUG only), which renders
each window's own visual off-screen, so there is no desktop content and nothing appeared on screen. Live logs:
`docs/phase4-evidence/`.

## What was built (ports of the Mac files named)

| Windows | Mac reference |
|---|---|
| `Core/UI/MenuSnapshot.cs` (popover rules, TimeText) | `UI/MenuViewModel.swift`, `TimeText` |
| `Core/UI/CitySearch.cs` (states, debounce, coordinates) | `CitySearchModel`, `CityMatch`, `CoordinateInput` |
| `Core/UI/SetupSettingsModels.cs` (SetupModel, SettingsModel, AthanPreview) | `SetupViewModel`, `SettingsViewModel`, `AthanPreview` |
| `Core/Prayer/Labels.cs` (all copy: methods, madhab, rules, modes, pause, voices, credits) | `Prayer/Settings.swift` labels, `VoiceChoices`, `CreditsViewData` |
| `App/UI/PopoverWindow, SetupWindow, SettingsWindow, CreditsWindow, CitySearchView, Theme` | `MenuView`, `SetupView`, `SettingsView`, `CreditsView`, `SetupViewComponents` |
| `App/UI/SceneStill.cs` (still painted from the real scene, Mac crop frames, cached per version) | `UI/SceneStill.swift` |
| `App/Tray/TrayIcon.cs` (mihrab icon, light/dark taskbar) | menu bar extra |
| `App/Places/Geocoder.cs` in `Prayer/` (Open-Meteo, the only network) | `Prayer/Geocoder.swift` |
| `App/Audio/AthanPlayer.cs` (NAudio, Fajr from 9.0 s) + `MediaPauser.cs` (GSMTC, pause only) | `AthanPlayer`, `Voices`, `MediaPauser` |
| `App/Blocker/AppHider.cs` + `CodingApps.cs` (minimise only, event + 250 ms poll) | `AppHider`, `CodingApps` |
| `App/Launch/LogonTask.cs` (schtasks XML: logon + every-minute trigger, `--tick`) + `LogonSession.cs` | `LoginAgent` |
| `App/App/AppHost.cs` (wiring, launch decision, show broadcast, SystemEvents → scheduler, repair task, Quit → userQuit) | `GoPrayApp.swift`, `Windows.swift` |
| `App/Debug/DebugMenu.cs` (Trigger Athan now 20 s per mode, Wipe state, `--debug-seed toronto`), `DebugScreens.cs` | `Debug/DebugMenu.swift` |

## Live results on Ahmed's PC

- **P4-A, coding-apps block with the real hider, real Athan and real media pause** (`p4-a-coding.log`, `p4-test-window.log`, `q2-media-target.log`):
  - my silent SMTC session went Playing → **Paused** at the Athan's first note and stayed paused;
  - the Athan played (volume 0.05) and **Silence stopped the sound while the block went on**;
  - my test window was minimised at block start; when it restored and activated itself, it was **minimised again in under 100 ms** (the 100 ms poll never saw it restored), with the notice told the app's name;
  - after the block nothing was restored (as on the Mac), no keyboard hook, and the foreground stayed in the person's app.
  Ahmed's Spotify was listed and already paused before the run (checked first).
- **P4-B, autostart with a self-contained Release build** (real `%LOCALAPPDATA%\GoPray`, created for the test and deleted after; Go Pray was paused so no block could start):
  - first launch → **task "Go Pray" registered** (logon trigger + every 1 min, `GoPray.exe --tick`, run as the user);
  - a tick while the task's own copy runs → refused by IgnoreNew (0x80070420), one process;
  - **End task (taskkill /F) → back in 24 s and 42 s** (two runs), log `launch Tick … → Wire`;
  - a hand launch while it runs → `ByHand mutex=False → AskHolderToShowAndExit`, the running copy opened **Settings**, exit 0;
  - `GoPray.exe --uninstall-task` → "logon task removed"; then `schtasks`/`Get-ScheduledTask` empty, no process, no data folder, no Run key.
  - Found: from **my sandboxed tool shell** a by-hand copy and a task copy did not see each other's `Local\` mutex (two copies ran). A launch outside the sandbox (a real double-click) sees it correctly. This is a test-environment artifact, not the product.

## Tests

`Core.Tests` 209 (new: `UiModelTests`, 35 cases (174 → 209): TimeText, popover snapshot incl. after-Isha/blocked/paused/no-schedule, city
search states/debounce/cancel, coordinates, Setup writes-once + first-setup-never-blocks + suggestion vs manual method
+ failed task never blocks + refused during a block, Settings refused during a block (side effects never run),
launch-at-login order, pause/resume, preview never stops a block's Athan, copy do-not list).
`App.Tests` 62 (new: `Phase4Tests` 14: hider with a fake desktop, list, task XML, Open-Meteo parsing, all 29 files, Fajr
at 9.0 s through NAudio, pause called once and never on a missing file, Stop never calls OnFinished, still crop
maths, a real still painted off-screen and cached). A DEBUG-only `GOPRAY_DEBUG_STATE_DIR` keeps every test away from
the real data folder (checked: it does not exist after the full run).

## Notes for the PM / not done

- **Size:** the self-contained publish is **209 MB** (PLAN guessed 70–90). WPF + WinForms + WebView2 + 29 MP3s. Phase 5:
  measure what ReadyToRun-off / excluding unused runtime packs saves. No trimming (WPF).
- **Settings during a block:** opens read-only with "Settings open again after you pray." (Setup never opens during a block).
- **Physical-keys check, Win+L, Ctrl+Alt+Del, multi-monitor:** still for Ahmed (unchanged).
- **Calls (Teams/Zoom) untouched by the media pause:** UNTESTED (no call available); GSMTC only lists media sessions.
- **Elevated terminals:** a window that refuses minimise is logged and left alone (UIPI); not exercised live (needs UAC).
- **Ship-gate items** (a full day, a real Athan, sleep-through-Athan) are Phase 6.
