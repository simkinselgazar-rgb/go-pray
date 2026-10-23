# Go Pray for Windows

The Windows port of Go Pray. The plan is `PLAN.md`. The Mac app in `../GoPray/` is the reference
implementation, and `../GoPray/Resources/` (scenes, audio) is read-only input.

## Layout (so far)

| Path | What |
|---|---|
| `src/GoPray.Core/` | The law, ported 1:1 from `GoPray/Core/` + `Prayer/Settings*`: `BlockGate` (the one choke point), `BlockState` + `StateStore` (state.json, Mac-compatible), `Scheduler`, `Clock`, `LockPolicy` + `PauseOption`, `Settings` + `SettingsStore` (settings.json, Mac-compatible), `Launch/` (the `--tick` + single-instance decision, the `Local\GoPray.Instance` mutex, launch.json). Plain `net10.0`, no WPF/WinRT (guard rule 12). |
| `tests/GoPray.Core.Tests/` | xUnit. The Mac's `BlockGateTests`, `LockAndPauseTests`, `SchedulerTests`, `DebugBlockTests`, `SettingsStoreTests` use the same test names. `StateStoreTests`, `MacFixtureTests` and `LaunchDecisionTests` are Windows-only. `fixtures/` holds Mac-shaped JSON. |
| `scripts/guard.ps1` | Grep guards (translation of `scripts/guard.sh`, PLAN.md §6). `-Strict` adds the ship-time "exactly one" rules; `-Release <dir>` scans binaries for debug strings. |
| `scripts/guard-selftest.ps1` | A negative control for every guard rule, plus `-Release` on Debug (must fail) and Release (must pass) builds. |
| `src/GoPray.App/` | The Windows shell. Phase 2: `Shield/` (ShieldController, ShieldWindow, SceneWebView, KeyboardGuard, ForegroundWatch, NativeFallbackShield), `Debug/DebugHarness.cs` (DEBUG only). Scenes are synced from `../GoPray/Resources/scenes` at build (git blobs, manifest-checked). |
| `tests/GoPray.App.Tests/` | Real WebView2 off-screen: bridge, lockdown (local listener), fallback, manifest, keyboard decision. |
| `docs/` | `adhan.md` (why the prayer math is a port), `phase2.md` (shield results + live evidence). |
| `spike/` | Phase 0 throwaway + `ANSWERS.md`. |

## Build and test

Needs the .NET 10 SDK (`global.json` pins the 10.0.4xx band). On Ahmed's PC it is installed per user at
`%USERPROFILE%\dev\dotnet\dotnet.exe`.

```
dotnet test GoPray.sln
powershell -ExecutionPolicy Bypass -File scripts\guard.ps1
powershell -ExecutionPolicy Bypass -File scripts\guard-selftest.ps1 -Dotnet <path to dotnet.exe>
```

Run `guard.ps1` and `dotnet test` after every change, and put their output in each hand-off.

## Launch model (PM ruling 2026-10-23)

The Task Scheduler task `Go Pray` has one action, `GoPray.exe --tick`. Its triggers are at logon and
a time trigger repeating every minute, with `MultipleInstancesPolicy = IgnoreNew` (spike Q3:
`RestartOnFailure` never fires after End task). `LaunchDecision.Decide` is the one place that decides:
- a tick runs only if state.json holds an open block, or the person did not Quit on purpose in this logon session;
- a hand launch always runs, or asks the running copy to show itself;
- Quit (allowed only with no block up) writes `launch.json { userQuitLogonId }`, and a new logon session's id differs.

state.json stays the Mac's exact v1 shape. The quit flag lives in its own file.
