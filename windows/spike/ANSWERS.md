# Go Pray for Windows: Phase 0 spike answers

Run 2026-10-23 on Ahmed's PC by the Windows General Worker. Windows 11 Pro 26H2 (build 26300), x64, **one monitor** (1920x1080 at 125 %, 1536x864 logical), WebView2 Runtime 155.0.4283.62, .NET 10 SDK 10.0.402. Code: `GoPraySpike/` (one WPF exe, modes by argv, see `Program.cs`). Evidence: `evidence/` (logs + one WebView2 capture of our own page; no screenshots of Ahmed's desktop).

Safety held. Every shield closed itself in 10 to 15 s with a background `Environment.Exit` watchdog 2 s later, and Ctrl+Alt+Shift+F12 was a hard exit (registered, not pressed). Win+L was never injected. Only windows and processes I launched were minimized or stopped, matched by a title marker or PID. Two Start menus opened by the no-hook negative controls were closed with one Esc each, after checking that Start was in front. Audio: two 2.5 s clips at volume 0.08. The scheduled task was deleted, and the proof is at the end. Screen use was announced to the other Windows sessions with LOCK/UNLOCK.

## Bugs in the plan's recipe (fix these in the real build)

1. **`RestartOnFailure` does NOT relaunch after End task.** I killed the task's process with exit code 1 (`taskkill /F`, which is TerminateProcess like Task Manager's End task). The result was `LastTaskResult=1`, state `Ready`, and **no restart in 210 s**. The setting covers failures to start the task, not a process that dies. **Fix (tested):** add a second trigger to the same task, a `TimeTrigger` repeating every `PT1M` indefinitely, with `MultipleInstancesPolicy=IgnoreNew`. The process came back **40 s after the kill** (worst case 60 s). A tick that fires while the app is still running is dropped, so there are no duplicates. One task, no watchdog process, so decision 1 holds. See Q3 for what this does to "Quit".
2. **The keyboard hook is not optional; without it the shield cannot win back foreground.** In the no-hook control, an injected Win tap opened Start (`SearchHost`). Then **30 of 30 `SetForegroundWindow` calls were refused**, the AttachThreadInput variant was refused too (`attach=False`), and the taskbar stayed uncovered until the test ended. With the hook, Start never opens. Decision 2 (A) is required, not just better.
3. **`EVENT_SYSTEM_FOREGROUND` arrives late for console and Windows Terminal windows.** When my conhost/`cmd` window or WT window was restored and brought to the front, the event came about 3 s later, at the *next* foreground change (`q6-hider-run2-event-only.log`). Edge and Cursor got it within 35 to 70 ms. **Fix (tested):** keep the WinEvent hook and add a 250 ms `GetForegroundWindow` poll. Console windows were then re-minimized in 125 to 165 ms (`q6-hider-run3-event-plus-poll.log`). Use the same poll in the shield's `ForegroundWatch`.
4. **A console window does not belong to `conhost`.** `GetWindowThreadProcessId` on a classic `ConsoleWindowClass` window returns the **shell** (`cmd`, `powershell`), not `conhost.exe`. WT windows map to `WindowsTerminal`. The list already has `cmd`/`powershell`/`pwsh`, so it works, but `conhost`/`OpenConsole` never match a top-level window. Also, **Warp's process is `warp` (lower case)**, so compare names `OrdinalIgnoreCase`.
5. **.NET:** this PC has only the .NET **8** runtime system-wide. A framework-dependent build shows a "You must install .NET" dialog. The plan's self-contained publish is mandatory; keep it.

## 1. Shield (topmost window per monitor + foreground re-assert + LL hook)

**Answer: yes on one monitor. With the hook, nothing reached anything in 2 × 15 s of reflex chords. Multi-monitor, physical keys, Win+L and Ctrl+Alt+Del are UNTESTED; see the manual test below.**

| Test (injected with `SendInput` while the shield was up) | Hook on | Evidence |
|---|---|---|
| Window bounds | `SetWindowPos(HWND_TOPMOST, 0,0,1920,1080)` gave exactly (0,0,1920,1080) in device pixels with PerMonitorV2 | `q1-shield-hook-a.log` |
| Win tap | swallowed (down+up), shield stayed foreground | `q1-*-hook-a.log` |
| Alt+Tab, Win+Tab, Ctrl+Esc, Alt+Esc | each swallowed, foreground stayed ours | `q1-*-hook-a.log` |
| Ctrl+Shift+Esc | swallowed, Task Manager did not start (0 `Taskmgr` before and after) | `q1-*-hook-b.log` |
| Win+D | swallowed | `q1-*-hook-b.log` |
| Alt+F4 | passed to the window, `Closing` cancelled | `q1-shield-hook-b.log` |
| Foreground thief (my own window calling `SetForegroundWindow` on itself) | it **did** get foreground; the re-assert took it back in **62 ms**, with `SetForegroundWindow` accepted on the 1st try | `q1-shield-hook-b.log`, `q1-steal.log` |
| Mouse click on the taskbar centre | hit the shield, foreground stayed ours | `q1-*-hook-b.log` |
| Taskbar | a `WindowFromPoint` probe on the taskbar centre every 20 ms showed **our window the whole time** in all hook runs (0 peeks), including during the steal | `SUMMARY` lines |
| Was `SetForegroundWindow` refused? | with hook: 0 of 1 refused. **Without hook: refused 30 of 30 against Start** (bug 2) | `q1-shield-nohook*.log` |
| Negative control, no hook | Win tap → `SearchHost` (Start) foreground, taskbar uncovered, not recoverable | `q1-shield-nohook.log`, `q1-keys-nohook.log` |

Caveats:
- All keys were **injected**. The LL hook saw them with `LLKHF_INJECTED=1`. Physical keys go through the same hook; still, Ahmed should confirm by hand (below).
- **Win+L: UNTESTED** (injecting it would have locked Ahmed's PC). My hook swallows the Win key itself and lets L through, so whether Win+L still locks under the hook needs a real keypress. Docs say Win+L is handled below hooks. **Ctrl+Alt+Del: UNTESTED** (it cannot be injected).
- Only **one monitor**, so the second-monitor `layout: "art"` window and "unplug a monitor" are UNTESTED. No maximized VS Code or full-screen YouTube underneath (VS Code is not installed; Cursor is).
- Toasts over the shield: UNTESTED.

**Manual check for Ahmed (2 minutes, closes itself after 15 s):** `windows\spike\bin\GoPraySpike.exe shield --seconds 15`, then press with real keys: Win, Alt+Tab, Ctrl+Shift+Esc, then **Win+L (must lock)**. Run it again and press **Ctrl+Alt+Del (must show the security screen)**. Ctrl+Alt+Shift+F12 exits at once. Log: `windows\spike\bin\evidence\q1-shield.log`.

**Real build:** as planned (topmost per monitor, re-assert debounced about 50 ms then retry every 100 ms, LL hook only during a whole-screen block), plus the 250 ms foreground poll from bug 3.

## 2. Media pause (GSMTC from an unpackaged exe)

**Answer: works, no prompt, no manifest, no package identity.**

- `GlobalSystemMediaTransportControlsSessionManager.RequestAsync()` returned in 37 to 43 ms. Foreground did not change, so no consent UI appeared (`q2-*.log`).
- My own silent SMTC session (`GoPraySpike.exe`, WinRT `MediaPlayer`): `TryPauseAsync` → `True` in about 515 ms, and the session went Playing → **Paused** (`q2-media-pause.log` + `q2-media-target.log`).
- **Real Edge** (a throwaway profile playing a silent file; session AUMID `MSEdge`): `TryPauseAsync` → `True` in 504 ms, Playing → **Paused** (`q2-media-pause-edge.log`).
- Ahmed's Spotify (Store app, AUMID `SpotifyAB.SpotifyMusic_zpdnekdrzrea0!Spotify`) was listed as a session but was already paused, and the spike never touched it. **Pausing a playing Spotify: UNTESTED** (I would not start Ahmed's music). Spotify registers with GSMTC, which is what matters.
- **Chrome and Firefox: UNTESTED** (not installed). **Teams/Zoom call untouched: UNTESTED** (no call available).
- Each `TryPauseAsync` takes about 0.5 s, so pause the sessions in parallel and keep the plan's 2 s timeout. Every Edge profile shares the AUMID `MSEdge`; the real build pauses everything that is Playing, so that does not matter.

## 3. Autostart + relaunch (Task Scheduler)

**Answer: the per-user logon task registers without admin. `RestartOnFailure` does not relaunch after End task (bug 1). A 1-minute repeating trigger with `IgnoreNew` does, in ≤ 60 s (40 s measured).**

- `schtasks /create /xml` with `LogonTrigger` (this user), `InteractiveToken`, `LeastPrivilege`, `ExecutionTimeLimit=PT0S`, `RestartOnFailure PT1M×3`, `IgnoreNew`, and both battery flags false: **SUCCESS from a non-elevated standard-user token**. Final XML: `evidence/q3-task-final.xml`.
- `schtasks /run` → started. Kill with exit 1 → no restart in 210 s (above).
- Added a `TimeTrigger` (StartBoundary = registration time, `Repetition Interval=PT1M`, no duration): it started on the first tick, the next tick was ignored while running (1 start), and after a kill it **relaunched in 40 s** (`evidence/q3-task-starts-repeat-trigger.log`).
- **Sign-out/sign-in start: UNTESTED** (it would have signed Ahmed out). Registration with the logon trigger worked; the real start at logon still needs one check on a test account, or when Ahmed next signs in.
- Task Scheduler's Operational history log is disabled on this PC (default). I did not enable it, since that is a system setting, so "History shows the restart" is UNTESTED. `LastRunTime`/`LastTaskResult` from `Get-ScheduledTaskInfo` were enough.
- **Design consequence for the PM:** with a repeating trigger, **Quit when idle also relaunches within a minute.** Suggested fix: the trigger passes `--tick`, and a `--tick` launch exits 0 at once unless `state.json` holds an open block *or* the app was not quit on purpose (a `userQuit` flag written by Quit, cleared at logon or on the next manual launch). "Launch at login off" still deletes the task.

## 4. WebView2: `shield.html` through a virtual host + the webkit shim

**Answer: yes to everything. `shield.html`/`bridge.js` stay byte-identical; the host-injected shim runs under the page CSP.**

From `evidence/q4-webview.log`:
- `SetVirtualHostNameToFolderMapping("gopray.invalid", <repo>/GoPray/Resources/scenes, Deny)` → `https://gopray.invalid/shield.html` loaded, and `ready` arrived **70 ms** after navigation (well inside the 4 s fallback).
- Shim (`AddScriptToExecuteOnDocumentCreatedAsync`): `typeof window.webkit.messageHandlers.gopray.postMessage` = `"function"`, and `GoPrayBridge.violations()` = **0**.
- `ExecuteScriptAsync("GoPrayBridge.show({...8000 ms...})")` painted Dhuhr (`evidence/q4-webview-unlocked.png`).
- Trusted (CDP `Input.dispatchMouseEvent`) click on "I prayed" **before** unlock: button `disabled=true`, **no message**. After 8 s: `disabled=false`, click → exactly one `{"type":"prayed"}`, then `{"type":"gone"}` after the accept fade. `e.Source` = `https://gopray.invalid/shield.html` on every message.
- **CSP negative control:** a page-created inline `<script>` did not run (`window.__inline` stayed undefined) and `violations()` went 0 → **1**. The CSP is live, and host-injected scripts are exempt from it.
- `location.href='https://example.com/'` → `NavigationStarting` cancelled, and the page stayed on the virtual host.

**Real build:** exactly as the plan says. No Windows-only `shield.html` is needed.

## 5. Audio (NAudio)

**Answer: all 29 files decode with every candidate decoder; `Mp3FileReader` (ACM) is fine for MPEG-2.5.**

- `Mp3FileReader` 29/29, `MediaFoundationReader` 29/29, NLayer 29/29. Full decode takes 30 to 110 ms per file with ACM (`evidence/q5-audio.log`).
- 28 files are 11025 Hz mono (MPEG-2.5). The Fajr file is **48 kHz stereo**, 195.2 s.
- Fajr: `CurrentTime = 9.0 s` → reads back **9.0000 s** (byte position 1728000 = 9.0 × 192000 B/s), and 9.1000 s after a 0.1 s read.
- Real playback through `WaveOutEvent` at volume 0.08, 2.5 s each: Fajr from 9.0 s (stream at 11.70 s afterwards) and `Aghati.mp3` (11 kHz) (stream at 2.70 s). No errors.
- "9.0 ± 0.1 s against a stopwatch on the Mac": not done (needs both machines); the reader's own position is exact.

## 6. Hider (minimize listed apps, re-minimize on foreground)

**Answer: yes for conhost/cmd, Windows Terminal, Cursor and Edge. Re-minimize needs the event + poll (bug 3). Elevated terminal: UNKNOWN.**

- `ShowWindow(SW_MINIMIZE)` → `True`, `IsIconic=True` for all four test windows (`q6-hider-run*.log`).
- Brought forward (restore + `SetForegroundWindow`), they were re-minimized after: Edge 63 to 70 ms, Cursor 35 to 43 ms (event); WT 125 ms and cmd 165 ms (poll). Event-only, WT and cmd took about 3 s.
- Exe names of visible top-level windows on this PC: `cmd`, `msedge`, `Cursor`, `WindowsTerminal`, `warp`, `powershell`, `ChatGPT`, `explorer`, `SystemSettings`, `ApplicationFrameHost`, `TextInputHost`, `Spotify`. Add **`warp`** (case) and note that `Cursor` is the VS Code fork installed here; `Code` was not seen (VS Code not installed).
- **Elevated terminal (UIPI): UNKNOWN.** This Windows account is a standard user (`Administrators` membership false, Medium integrity), so an elevated window needs a UAC prompt for Ahmed. Manual test: open "Terminal (Admin)", then in a normal PowerShell run `windows\spike\bin\GoPraySpike.exe hider --marker "Administrator"`, which minimizes only windows whose title contains that text.
- **Codex desktop exe name: UNKNOWN** (not installed).
- Nothing was killed by the hider. Cleanup closed only processes I started (matched by PID or my temp-profile command line). A gotcha for anyone testing: **Edge with a fresh `--user-data-dir` auto-signed into Ahmed's Work account** (implicit sign-in), so its window title was not my page. I targeted it by PID and deleted the temp profile afterwards.

## 7. Facts

| | |
|---|---|
| Windows | Windows 11 Pro, version 26H2, build 26300 |
| CPU arch | **x64** (`AMD64`) → `win-x64` only |
| Monitors | **1**: 1920x1080 at 125 % (1536x864 logical) |
| WebView2 Runtime | **installed**, 155.0.4283.62 |
| .NET | system: **.NET 8.0.32 runtime only**. **.NET 10 SDK 10.0.402** installed by me per-user at `%USERPROFILE%\dev\dotnet` (no admin, not on PATH) |
| Account | AzureAD account, **standard user** (not in Administrators), so UAC prompts need Ahmed |
| signtool | Windows SDK **10.0.19041.0** `signtool.exe` exists (`C:\Program Files (x86)\Windows Kits\10\bin\10.0.19041.0\x64\`). That is **older than the ≥ 10.0.2261.755 Artifact Signing needs**, so install the Artifact Signing Client Tools in Phase 5. `AzureSignTool`: not found. Inno Setup: not installed |
| Morrow's signing scripts | not grepped (brief: don't touch other projects); ask before Phase 5 |
| **Adhan NuGet 0.9.0 licence** | **MIT.** The nuspec has no licence field, but it was built from `stankovski/adhan-csharp` at commit `5f44be9` ("Merge pull request #2 from stankovski/nuget", 2025-02-01). That repo is a fork of `davidpet86/Adhan-csharp`, and both carry an MIT `LICENSE` (Copyright (c) 2019 davidpet86). The DLL is not Authenticode-signed. **Use it, pinned, with the mandatory parity test.** Put the MIT notice in Credits/`LICENSES` because the package itself does not ship it |

## Acceptance line status

- "60 s during which nothing but Win+L and Ctrl+Alt+Del reach anything": **met for injected keys on one monitor** (2 × 15 s; nothing reached anything). Physical keys, Win+L and Ctrl+Alt+Del need Ahmed's manual check above.
- "Media paused": **yes** (own session + real Edge). "Call alive": **UNTESTED**.
- Every UNKNOWN in §2–§3: answered, except elevated terminal (UIPI), Codex exe name, Teams/Zoom, Chrome/Firefox, multi-monitor, and logon-time start. These are listed above as UNTESTED/UNKNOWN with the manual step for each.

## Cleanup proof (2026-10-23 16:38)

```
schtasks /delete /tn "GoPraySpike-Restart-TEST" /f  -> SUCCESS
schtasks /query /fo csv | findstr /i gopray        -> (empty)
Get-ScheduledTask -TaskName *GoPray*               -> (empty)
HKCU\...\CurrentVersion\Run  matching gopray       -> (none)
Startup folder *gopray*                            -> (none)
Get-Process GoPraySpike                            -> 0
%LOCALAPPDATA%\GoPraySpike, temp Edge/Cursor profiles -> deleted
```

## Reproduce

```
cd windows\spike\GoPraySpike
<dotnet10>\dotnet.exe build -c Debug -o ..\bin
set GOPRAY_SPIKE_EVIDENCE=<dir>     (logs go to bin\evidence otherwise)
..\bin\GoPraySpike.exe shield --seconds 15 [--nohook] [--strong]   + keys --steps win,alttab,...
..\bin\GoPraySpike.exe media-target  /  media-pause
..\bin\GoPraySpike.exe web --scenes ..\..\..\GoPray\Resources\scenes
..\bin\GoPraySpike.exe audio --athan ..\..\..\GoPray\Resources\athan [--noplay]
..\bin\GoPraySpike.exe hider --marker <title text> [--pids p1,p2] [--poll]
..\bin\GoPraySpike.exe idle --minutes 10      (the Task Scheduler target)
```
