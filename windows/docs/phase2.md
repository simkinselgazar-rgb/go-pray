# Phase 2: shield (results, 2026-10-23)

The code is in `src/GoPray.App/Shield/` and `src/GoPray.Core/Shield/BridgeMessage.cs`. Assets come from
`scripts/sync-assets.ps1` + `scripts/check-manifest.ps1`, and both run on every build. Live evidence is in
`docs/phase2-evidence/` (logs only; no screenshots of Ahmed's desktop).

## Acceptance (PLAN.md §7 Phase 2), measured on Ahmed's PC (1 monitor)

| Line | Result | Evidence |
|---|---|---|
| Debug "Trigger Athan now" → shield on every monitor, ring | yes: one full-layout window per monitor, page `ready` in about 0.3 s; art windows on other monitors tested off-screen with 3 fake displays | `live-a-shield.log`; `threeDisplaysGiveThreeWindowsAndUIOnlyOnTheMainOne` |
| `prayed` before the lock ends is refused and the page re-syncs | yes, live (`early: page click`, phase stays Locked) and in the test (gate's update re-shows 5:00) | `live-a`, `prayedBeforeUnlock…` |
| After the lock: "May Allah accept it." then idle | yes: Leaving → Idle in 1.3 s, `lastConfirmed` written | `live-a/b` |
| Kill the WebView2 process → fallback within 1 s with the right remaining time | yes: live renderer crash → fallback in **157 ms**; test kills the real renderer process → fallback < 1 s, remaining 296–300 s; the fallback's early click is refused, its click after the lock confirms | `live-c-crash.log`, `killingTheRendererProcess…` |
| One byte changed in `ui.js` → build fails | yes: `check-manifest FAIL: ui.js differs from the manifest`, MSB3073, Build FAILED (built with `-p:GoPrayScenesSource=<copy with one flipped bit>`) | this file; `ManifestTests` |
| Hook present only during the block (key test before/after) | yes: installed at block start, removed at confirm. F24 injected after the block was not seen (key-event count unchanged during the linger) | `live-b-shield.log` + `live-b-keys.log` |

## Live reflex test with the product hook (injected keys, `live-a`)

Win, Alt+Tab, Win+Tab, Ctrl+Esc, Ctrl+Shift+Esc, Win+D, and Alt+F4 (Closing cancelled): the shield
kept the foreground every time, and Task Manager never started. A foreground thief (`live-b`) got the
foreground for a moment; the shield won it back on the first re-assert (1 try, 0 refused). Coding-apps
notice (`live-d`): no hook, and the foreground stayed in the person's app (Warp).

## Found and fixed

1. **Git for Windows checks the scene text files out with CRLF** (`core.autocrlf=true`), so the working
   copy is not byte-identical to the approved files. sync-assets reads the committed blobs with
   `git cat-file blob HEAD:<path>` instead. A test proves CRLF would fail the manifest.
2. **One WebView2 profile shares one virtual-host mapping across its views.** A test with another scenes
   folder made the next test's pages resolve there. The app maps exactly one folder; tests use one profile per folder.
3. **The CSP alone does not stop the top-level navigation request** (`location = …`): the GET goes out before
   `NavigationStarting`'s cancel lands. The host's 403 filter (`WebResourceRequested`, every non-virtual-host
   URL) stops it. The filter alone is not enough either: WebSocket and some subresource loads slip past it,
   and the CSP stops those. Shipped (both layers): 0 HTTP requests reach a local listener, over 3 runs.
   Chromium still opens a bare TCP preconnect (no request, no data) when a navigation or popup starts.
   `--dns-prefetch-disable` and the NetworkPrediction feature flags do not stop it. It is counted and
   reported in the test, not hidden. **PM ruling (2026-10-23): ship both layers; the bare preconnect (no request, no data) is ACCEPTED** and belongs in the threat model.
4. **Windows caps a window at the virtual-screen size plus borders.** ShieldWindow answers `WM_GETMINMAXINFO`
   with its monitor's size, so the bounds are exact.
5. **Nothing had the focus after the shield closed.** A whole-screen shield now remembers the foreground
   window and hands focus back (live: back to Warp).

## Not done / UNTESTED

- Real multi-monitor and `DisplaySettingsChanged` (1 monitor here); the rebuild path is code-reviewed only.
- Physical keys, Win+L and Ctrl+Alt+Del (manual check in `spike/ANSWERS.md` §1).
- The coding notice's rounded corners (DWM) were not checked visually. Reduce-motion on secondary/notice is forced, as on the Mac.
- `release.ps1` must not ship `.pdb` files (they name `DebugHarness.cs`); `guard -Release` scans `.exe`/`.dll`.
- The "fade" of the Mac's dismiss: the page plays its own accept fade; the Windows host closes without a window fade.

## Debug harness (DEBUG builds only)

```
set DOTNET_ROOT=%USERPROFILE%\dev\dotnet
src\GoPray.App\bin\Debug\net10.0-windows10.0.19041.0\GoPray.exe --debug-shield --prayer dhuhr --lock 10 ^
    --click-early-at 2 --crash-at 4 --click-at 11 --linger 2 --cap 15 --log <file>
```
`--cap` is at most 15 s (the shield is torn down and the process exits), a watchdog exits 3 s later, and the hook dies with the process.
