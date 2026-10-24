# Go Pray v2 — plan (Mac + Windows)

Copied 2026-10-24 from the Mac PM's architecture plan. §9 (Fable) is authoritative for the emergency-exit details; §10 adds the updater approval and the lean-build rule. Windows signer CN is known: "Ahmed Elgazar" (drop the UNKNOWN in §8.1 rule 5).


Fable, 2026-10-24, read-only. Read: the project's locked decisions, the Mac architecture plan (Final plan, Pre-ship review, pause-media plan, Windows plan), the Mac repo `app/` @ `185076a` (`CONTRACT-NOTES.md` #1–48, `Core/Contracts.swift`, `Core/BlockGate.swift`, `Core/BlockState.swift`, `Blocker/CodingApps.swift`, `Blocker/AppHider.swift`, `Prayer/Settings.swift`, `Prayer/SettingsStore.swift`, `UI/SettingsView.swift`, `Shield/BridgeMessage.swift`, `Resources/scenes/bridge.js` + `ui.js`, `scripts/guard.sh`, `GoPrayApp.swift:50-64`), and `origin/windows` @ `f9c105e` (`GoPray.Core/BlockGate.cs`, `BlockState.cs`, `Prayer/Settings.cs`, `Prayer/SettingsStore.cs`, `GoPray.App/Blocker/CodingApps.cs` + `AppHider.cs`, `scripts/guard.ps1`, `.github/workflows/windows-release.yml`, `PLAN.md`). Brick's rules were checked on the web today (§2.1).

### 0. Avatar + first principles (short)

- **For:** Ahmed and his family. The same Muslim coder in flow, plus parents who are not coders. Wants to be stopped at every Athan and let back after a real break. New fear, from the family: *"what if I truly cannot stop right now, even once?"* The 2026-10-21 "no escape" rule answered "then you wait 10 minutes". Ahmed has chosen to amend it: a hard cap of 5 emergency exits, like Brick. Does not care about: stats, streaks, a server, accounts.
- **Job, feature 1:** let the person say *which* apps rest in Coding-apps mode, without opening a hole in a running block. **Job, feature 2:** give one deliberate, scarce way out, counted honestly, that can never be pressed by reflex and never refilled by a casual poke.
- **First principles.**
  - The list is a *setting*, so it obeys the two settings rules that already exist: changes only between prayers (`BlockGate.authorizeSettingsChange`, `BlockGate.swift:109`) and **captured into state.json at block start** like `lockMinutes` (`BlockGate.swift:291`, CONTRACT-NOTES #11b). The old protection ("a static list cannot be edited to dodge a block", `CodingApps.swift:2-3`) is replaced by the capture, not thrown away.
  - The exit is a *second door in the one gate*. `endBlock()` gains a `kind`; `requestEmergencyExit()` is the second and last caller. Everything else (page, menu, settings) still only asks. The Windows gate already reserved this exact slot (`BlockGate.cs:14-16`, `guard.ps1:23-25`).
  - **Honest record.** An emergency exit marks the prayer **dropped** (`lastDropped`), never **confirmed**. No "May Allah accept it." on the way out.
  - **Scarcity is enforced in code; deliberateness is UX.** The gate counts (5, persisted in two places). The 3-second hold and the confirm card stop a reflex; they are not a security boundary, because the user owns the machine (§G: "we stop the reflex, not the admin").
  - **Delete / not in v2:** a "strict mode" toggle that hides exits (decision 2), earning exits back, per-prayer exceptions, any sync of the count between the Mac and the PC, a typed-in bundle id / exe name field (pick a file or a running app only).

### 1. Feature 1 — editable blocked-apps list

#### 1.1 Rules
1. The compiled-in list stays in the binary as **the defaults** (`CodingApps.swift`, `CodingApps.cs`). It can grow with each release. The user turns defaults off by id and adds custom apps by id. Nothing is ever removed from the defaults table because the user disabled it.
2. **Effective list** (one function, Core): `(defaults − disabledDefaultApps) ∪ customApps[platform == this].id`, minus `BlockedApps.neverBlock`, deduped, platform-normalised (Mac: exact bundle id; Windows: process name, case-insensitive, no `.exe`).
3. **Captured at block start:** `state.block.hiddenApps = effective list`. `AppHiding.start(hiding:)` receives *that* set from the gate (`present()`, `BlockGate.swift:299-308`), never the settings. A relaunch mid-block hides the captured set. Settings edits are already refused during a block; the capture makes the invariant hold even if the store were bypassed.
4. **Never blockable** (the denylist is in Core, applied in `Settings.sanitized()` *and* when the gate reads `hiddenApps` back from disk, so neither a UI slip nor a hand-edited state.json can make us hide them). Hide-only means the damage of a bad entry is small; this list is the part that would still hurt:
   - Mac: `com.ahmedelgazar.gopray`, `com.apple.finder`, `com.apple.dock`, `com.apple.systemuiserver`, `com.apple.controlcenter`, `com.apple.notificationcenterui`, `com.apple.Spotlight`, `com.apple.loginwindow`, `com.apple.systempreferences`, `com.apple.WindowManager`, `com.apple.ActivityMonitor` (the user's Force Quit route stays visible).
   - Windows: `GoPray`, `explorer` (shell, taskbar, desktop), `Taskmgr` (the §6 bypass table promises Ctrl+Alt+Del → Task Manager works), `SystemSettings`, `ApplicationFrameHost` (hosts Settings and every store app), `ShellExperienceHost`, `StartMenuExperienceHost`, `SearchHost`, `SearchApp`, `LockApp`, `LogonUI`, `winlogon`, `dwm`, `csrss`, `sihost`, `ctfmon`, `TextInputHost`, `RuntimeBroker`, `SecurityHealthSystray`.
   - Terminal / Windows Terminal / cmd / PowerShell **stay blockable** (they are defaults today; hide and minimise never stop a running command). Anything else the user picks is allowed: it is their machine and the worst case is a minimised window.
5. **Add path is a picker, not a text field.** Mac: `NSOpenPanel` limited to `.application` → `Bundle(url:).bundleIdentifier` + `CFBundleDisplayName`/`CFBundleName`. Windows: a list of the top-level visible windows the hider already enumerates (`IWindowSystem.TopLevel()`), plus "Browse for an .exe…" → `Path.GetFileNameWithoutExtension` + `FileVersionInfo.FileDescription` for the name. A denylisted pick shows the refusal line and is not added.
6. Caps: `customApps` ≤ 50, `disabledDefaultApps` ≤ 200, ids ≤ 200 chars, names ≤ 60 (same cap as `hiddenAppName`). `sanitized()` trims; nothing throws for these.
7. An empty effective list in Coding-apps mode is allowed (honour system): the notice panel still shows; Settings says so.

#### 1.2 Contract changes (PM amendment; `Contracts.swift` / `Contracts.cs`, CONTRACT-NOTES #49–#53)
```swift
// Contracts.swift
enum AppPlatform: String, Codable, Sendable { case mac, windows }
struct CustomApp: Codable, Equatable, Sendable { var id: String; var name: String; var platform: AppPlatform }

struct Settings {   // two new fields; both ABSENT in old files → [] (custom init(from:) with decodeIfPresent)
    …
    var disabledDefaultApps: [String]      // ids from the compiled-in defaults the user turned off
    var customApps: [CustomApp]            // user-added apps, both platforms kept, only this platform applied
}

enum BlockedApps {
    static let current: AppPlatform = .mac            // .windows in the port
    static let neverBlock: Set<String>                // §1.1 rule 4, this platform
    static let maxCustom = 50, maxDisabled = 200
    /// The one place the list is computed. `defaults` is injected (Core never imports Blocker).
    static func effective(_ s: Settings, defaults: Set<String>) -> Set<String>
    static func normalize(_ id: String) -> String     // Mac: trimmed; Windows: lowercased, ".exe" dropped
}

@MainActor protocol AppHiding: AnyObject {
    var onReHide: ((String) -> Void)? { get set }
    func start(hiding ids: Set<String>)   // CHANGED: the gate passes the captured set; `start()` with no list is gone
    func stop()
}
```
```csharp
// Contracts.cs (GoPray.Core)
public enum AppPlatform { Mac, Windows }
public sealed record CustomApp(string Id, string Name, AppPlatform Platform);
public sealed record Settings { …; public IReadOnlyList<string> DisabledDefaultApps { get; init; } = [];
                                    public IReadOnlyList<CustomApp> CustomApps { get; init; } = []; }
public static class BlockedApps { public const AppPlatform Current = AppPlatform.Windows; public static readonly IReadOnlySet<string> NeverBlock; 
    public static IReadOnlySet<string> Effective(Settings s, IReadOnlySet<string> defaults); public static string Normalize(string id); }
public interface IAppHiding { Action<string>? OnReHide { get; set; } void Start(IReadOnlySet<string> ids); void Stop(); }
```
`BlockGate.init` gains `defaultApps: Set<String>` (Mac wiring passes `CodingApps.bundleIDs`, or the DEBUG `GoPrayDebugHideOnly` override exactly where it is applied today, `GoPrayApp.swift:52-55`; Windows passes `CodingApps.Names.Keys`). `CodingApps.swift` gains `static let defaults: [(id: String, name: String)]` for the UI (the Windows dictionary already has names); `bundleIDs` stays as `Set(defaults.map(\.id))`.

**settings.json** (both platforms, `.sortedKeys`; Windows `SettingsRules.Encode` writes the two keys in this alphabetical position, always, even when empty, for byte parity with the Mac fixture test):
```json
{
  "athanVolume": 0.8,
  "city": "Toronto",
  "customApps": [ { "id": "com.figma.Desktop", "name": "Figma", "platform": "mac" },
                  { "id": "figma", "name": "Figma", "platform": "windows" } ],
  "disabledDefaultApps": [ "com.apple.Safari", "msedge" ],
  "highLatitudeRule": …,
  …
}
```
A 0.1.x file has neither key → both `[]` → behaviour identical to today. `disabledDefaultApps` may hold ids of both platforms; each platform only matches its own defaults, so one file works on both machines.

**state.json** (schema stays 1): `block.hiddenApps: [String]?`. Written always from v2. Missing (a 0.1.x file resumed after upgrade) → the gate computes the effective list from current settings once at resume and writes it back. On read, denylisted ids and anything over 200 entries are dropped (tamper rule, mirrors `lock(of:)`).
```json
"block": { "prayer": "asr", "athanAt": "…", "blockStartedAt": "…", "silenced": false, "athanPlayed": true,
           "lockSeconds": 600, "hiddenApps": ["com.anthropic.claudefordesktop", "com.apple.Terminal", "com.figma.Desktop"] }
```

#### 1.3 UI (Settings → new section **Blocked apps**, right under **Block**; disabled during a block like every other section)
- Header help: *"Only these apps rest in Coding apps mode. Turn ours off, or add your own. Changes start at the next prayer."*
- Rows: every default with its name and an on/off switch (`Toggle`); custom apps with name, a grey id line, and a **Remove** (−) button. Order: AI + terminals, editors, browsers, then "Added by you".
- **Add an app…** button → picker. Refusal notice (reuses `GPNotice`): Mac *"Go Pray can't rest that one. It's part of macOS."*, Windows *"…part of Windows."* Duplicate pick: *"Already on the list."*
- Empty effective list: *"Nothing is on the list, so Coding apps mode rests nothing."*
- Mac picker: `NSOpenPanel`, `allowedContentTypes = [.application]`, starts in `/Applications`. Windows: a small window with the running-apps list (name, exe) and a **Browse…** button (`OpenFileDialog`, filter `*.exe`).
- No new spec sheet: this is a list inside the already specified Settings form (same rule as the Windows plan §3 row 13).

### 2. Feature 2 — emergency exit (amends "No escape", Ahmed 2026-10-23/24)

#### 2.1 Brick's actual rules (checked 2026-10-24)
- **Count:** 5 Emergency Unbricks per device/account ("You get 5, so you're covered if you lose your Brick or are away from home"; "meant for emergencies, not daily use").
- **Reset:** **they do not reset on their own.** Brick's own page says "5 Emergency Unbricks are available and they don't reset - so use carefully." At 0 you can **request more inside the app** (Settings → Emergency UnBrick → Use → a confirm pop-up → "Request" → a short survey); Brick resets them "within 1 business day" (the support article says 2). You can only request at 0. Reinstalling the app does not refill them (reviewers report they are tied to the account).
- **Deliberateness:** a confirm pop-up; no hold. **Strict Mode** removes the option entirely (reported by reviewers; not on the official page I could open — mark that detail UNKNOWN).
- Sources: https://support.getbrick.com/en/articles/7950209 , https://getbrick.app/pages/emergency-unbricks , https://www.protectyoungeyes.com/devices/brick , https://eftm.com/2026/07/brick-review-adding-a-physical-roadblock-to-end-your-doom-scrolling-277956 , https://www.whistleout.com/CellPhones/Apps/brick-for-phone-limits-app-review
- **What that means for us:** Brick's "refill" is a human at a company. We have no server and no company, so the honest copy of Brick is **5, never refilled**, and the only refill is a full uninstall (admin action, like `brew zap`, accepted in §G).

#### 2.2 Our rules
1. **Total 5 per install (device).** `EmergencyExitPolicy.total = 5`. **Reset: never** (recommend; decision 1). At 0 the button is gone and nothing nags.
2. **Deliberate:** press-and-hold **3 s** on a quiet footer button (release early cancels, a thin bar fills), then a confirm card with the count, then the request goes to the gate. Keyboard: no shortcut. Reduce Motion: the bar still fills (it is information, not decoration).
3. **Honest record:** the gate writes `lastDropped = {prayer, athanAt}`, never `lastConfirmed`. The dismiss is a plain fade: **no "May Allah accept it."** The wake rule will not re-block that prayer (same `latestDoneAthan` rule as crash-loop drops, CONTRACT-NOTES #10–11).
4. **Both modes, both phases:** available while `locked` and while `canConfirm` (a person who did not pray can leave honestly instead of pressing "I prayed"). Not available while `idle` or `leaving`.
5. **Offline, local, no account.** Count stored in two places (§2.4); remaining = `total − max(file.used.count, mirror.used)`, clamped to 0…5.
6. **Not consumable by the page except by request.** New bridge message `emergency` (fifth and last name). The gate alone decides; a refused request re-syncs the page with the true count (same pattern as `prayed`, `BlockGate.swift:396-399`).
7. **The ledger write comes first.** `requestEmergencyExit()` records the use, then ends the block. If the record cannot be written, the exit is **refused** (the user is not trapped: the normal 10-minute path is untouched) and the page shows *"Couldn't use the exit. Try again in a moment."*
8. **One per block, by construction:** after `endBlock` the block is nil, so further messages are ignored.
9. **Debug hooks only in DEBUG:** `debugSetEmergencyExitsUsed(_ n: Int)` behind `#if DEBUG`, guarded by `guard.sh` rule 9 and the `--release` string scan.

#### 2.3 Contract changes (PM amendment)
```swift
// Contracts.swift
enum EmergencyExitPolicy { static let total = 5; static let holdSeconds: TimeInterval = 3 }

struct ShieldContext { …; var emergencyExitsLeft: Int = 0 }     // 0 → the page draws no button

@MainActor protocol ShieldDelegate: AnyObject {
    func shieldDidRequestConfirm()
    func shieldDidRequestSilence()
    func shieldDidRequestEmergencyExit()   // NEW → gate.requestEmergencyExit(); refused → shield.update(ctx)
}

// Core/EmergencyLedger.swift (NEW, PM). The only file that names emergency.json or the mirror key.
@MainActor final class EmergencyLedger {
    struct Use: Codable, Equatable, Sendable { var prayer: Prayer; var athanAt: Date; var at: Date }
    struct File: Codable, Equatable, Sendable { var schemaVersion = 1; var used: [Use] = [] }
    init(directory: URL = StateStore.defaultDirectory(), mirror: EmergencyMirror = UserDefaultsMirror())
    var remaining: Int                       // total − max(file.used.count, mirror.usedCount), clamped 0…total
    func recordUse(_ use: Use) throws        // writes the file atomically FIRST, then the mirror; throws → caller refuses
}
protocol EmergencyMirror: AnyObject { var usedCount: Int { get }; func set(usedCount: Int) }
// Mac mirror: UserDefaults.standard integer "EmergencyExitsUsed" (prefs plist). Windows mirror: a second file, %APPDATA%\GoPray\emergency.json (Core stays registry-free, guard rule 12).

// BlockGate.swift
enum EndKind { case confirmed, emergency }
init(…, ledger: EmergencyLedger, defaultApps: Set<String>, …)
@discardableResult func requestEmergencyExit() -> Bool   // the SECOND and LAST caller of endBlock(.emergency)
private func endBlock(_ kind: EndKind)                   // .confirmed → lastConfirmed; .emergency → lastDropped, dismiss(kind: .emergency)
```
```csharp
// GoPray.Core — the slot BlockGate.cs:14-16 reserved
public enum EndKind { Confirmed, Emergency }               // exists; Emergency now writes LastDropped, not LastConfirmed (BlockGate.cs:372 changes)
public bool RequestEmergencyExit();                        // second caller; guard.ps1 $EndBlockCallers = @('RequestConfirm','RequestEmergencyExit')
public sealed class EmergencyLedger { public int Remaining { get; } public void RecordUse(Use use); }   // primary %LOCALAPPDATA%\GoPray\emergency.json, mirror %APPDATA%\GoPray\emergency.json
public static class EmergencyExitPolicy { public const int Total = 5; public const double HoldSeconds = 3; }
ShieldContext gains int EmergencyExitsLeft; IShieldDelegate gains ShieldDidRequestEmergencyExit().
```
`ShieldPresenting.dismiss` gains a `kind: EndKind` parameter (default `.confirmed` so existing fakes compile); `.emergency` → `GoPrayBridge.dismiss("emergency")` → fade only.

**emergency.json** (same bytes on both platforms, fractional ISO dates like state.json):
```json
{ "schemaVersion": 1,
  "used": [ { "prayer": "asr", "athanAt": "2026-10-24T20:05:00.000Z", "at": "2026-10-24T20:08:41.512Z" } ] }
```
Read rules: missing → 0 used; unreadable, wrong version, `used.count > 5`, or a use dated > 24 h in the future → **0 left** (fail *safe*; it cannot trap, the block still ends after the lock). Remaining is recomputed on every read; nothing is cached across launches.

**Bridge** (`BridgeMessage` gains `case emergency`; `BridgePayload` gains `emergencyExitsLeft` clamped 0…5; validation unchanged: `{type}` only, one key). `bridge.js` (app-only, in MANIFEST) adds the footer button, the hold, the confirm card, posts `{type:"emergency"}`; `GoPrayBridge.dismiss(kind)` skips the accept line for `"emergency"`. **`ui.js` stays byte-identical.** `shield.css` gets the footer/card styles. `sync-assets.sh` rewrites `MANIFEST.sha256`; the Windows build picks the same bytes up through `sync-assets.ps1` (the worker never edits them).

#### 2.4 Where the count lives, and the threat model (SEC pass)
| Threat | What happens | Verdict |
|---|---|---|
| Page sends `emergency` without a hold (tampered or buggy JS) | gate consumes one exit and ends the block, same as a real hold. The hold is UX. The page cannot send more than one per block, cannot change the count, cannot end a block at 0. | accepted (self-harm only; the bundle is signed, Gatekeeper catches a changed `bridge.js` at launch; `check-manifest.sh` at build) |
| Page sends `emergency` while idle / leaving / at 0 left | `requestEmergencyExit()` returns false, block untouched, page re-synced with the true count | built in, tested |
| Delete `state.json` between prayers | nothing: the count is not there | built in |
| Delete or edit `emergency.json` | remaining = `total − max(file, mirror)`; the mirror still says N used. Editing the file to `used: []` changes nothing while the mirror stands. Both places must be found and changed, which is not a casual poke. | accepted: two places, no crypto (a key in the binary would be theatre; the user owns the machine, §G) |
| `defaults delete com.ahmedelgazar.gopray` + delete `emergency.json` (Mac); delete both folders (Windows); `brew zap`; uninstall + reinstall | refill to 5 | **accepted, documented in the README** ("a full uninstall resets your exits; that is an admin action, not a reflex") |
| `emergency.json` says `used: 9` or a future date | 0 left | fail safe, cannot trap |
| Write fails (disk full, read-only folder) | exit refused, block continues, log line, page shows the retry copy | the user is not trapped; a free exit never happens |
| Debug hook in a Release build | `#if DEBUG` + `guard.sh` rule 9 + `--release` strings (`debugSetEmergencyExitsUsed`, `Emergency exits (debug)`) + `guard-selftest.sh` negative control | built in |
| Another local process, same user | can do all of the above; already accepted in §G | accepted |
| Third-party install (abuse) | exits make Go Pray *less* usable as a lockout tool; the count is per machine and visible in the menu | improves §G abuse section |
| Clock games | the ledger has no time logic (no reset), so there is nothing to game | built in |
| Crash during `requestEmergencyExit` after the ledger write, before `endBlock` | the use is recorded, the block resumes on relaunch; the person lost one exit and is still blocked ≤ lock. Press again → consumes another. | accepted; rare; "never trap" holds (lock still ends). Mitigation: write the ledger and `state.block = nil` in that order with no work in between. |

**Fail-open check:** nothing in this feature lengthens a block, and every failure in it leaves the block exactly as it was. The crash-loop, clamp and quarantine rules are untouched.

#### 2.5 UI copy (warm, short, no guilt)
- Shield footer (under Silence, ghost text, 60 % ink): **"Emergency exit · 5 left"** (… "1 left"). Absent at 0.
- While holding: **"Keep holding…"** with a 3 s fill bar. Released early: back to the label, nothing else.
- Confirm card (replaces the ring for a moment, two buttons, default = Not now): title **"Use an emergency exit?"**, body **"This ends the block now. {Prayer} will count as missed, not prayed. You'll have {n−1} left."** At 1 left the last sentence is **"This is your last one."** Buttons: **"Not now"** (default) · **"Use it"** (plain, not prominent).
- After: a plain fade, no line.
- Menu popover footer (idle): **"Emergency exits: 3 left"**; at 0: **"Emergency exits: none left"**. Settings → Block section, read-only caption: same line + help **"They don't come back."** (policy A) 
- Coding-apps notice panel (420×520): the same footer button, same flow, smaller type.
- README: one paragraph: what it is, 5 per install, counted as missed, a full uninstall resets it.

### 3. Build lanes

**Order:** PM contract first (lands + tests green) → the two Mac Sonnet lanes in parallel → PM wiring + Fable review → Mac 0.2.0. The Windows worker starts when the PM pushes the amended `PLAN.md` + `CONTRACT-NOTES.md` and the new `bridge.js`/`shield.css`/manifest to `main` (the worker reads them from the repo).

| Lane | Model | Owns | Lands |
|---|---|---|---|
| **PM (contract owner)** | Opus | `Core/Contracts.swift` (§1.2, §2.3), `Core/BlockState.swift` (`hiddenApps`), `Core/BlockGate.swift` (capture, `requestEmergencyExit`, `endBlock(kind)`, `defaultApps`, `ledger`), `Core/EmergencyLedger.swift` (new), `GoPrayApp.swift` wiring, `Debug/DebugMenu.swift` (set exits used), `scripts/guard.sh` + `guard-selftest.sh`, `GoPrayTests/Core/*`, `CONTRACT-NOTES.md` #49–#56, `design/spec-go-pray.md` addendum "§X Emergency exit on the shield" (placement, states, copy from §2.5; the design gate wants a spec before the shield lane) | **first** |
| **Lane E: apps list** | Sonnet | `Blocker/CodingApps.swift` (defaults with names), `Blocker/AppHider.swift` (`start(hiding:)`, never-block check as the last line of defence), `Prayer/Settings.swift` (sanitize: denylist, caps, dedupe; custom `init(from:)` lives in Contracts = PM), `UI/SettingsView.swift` + `SettingsViewModel.swift` (Blocked apps section, picker), `GoPrayTests/Blocker/*`, `GoPrayTests/Prayer/SettingsStoreTests.swift`, `GoPrayTests/UI/UIFlowTests.swift` | parallel |
| **Lane F: exit UI** | Sonnet | `Resources/scenes/bridge.js`, `shield.css`, `scripts/sync-assets.sh` run (manifest), `Shield/BridgeMessage.swift` (`emergency`, payload field), `Shield/SceneWebView.swift` + `ShieldController.swift` (route the message, `dismiss(kind:)`), `Shield/NativeFallbackShield.swift` (hold + card natively), `UI/MenuView.swift` footer line, `GoPrayTests/Shield/*` | parallel |
| **Windows worker** | its session | everything under `windows/` per §4 | after the PM push |

Two small Mac lanes, not one: the file sets are disjoint and each spec fits one head; one lane would hold `Settings` UI and shield JS in the same context for no reason. Every lane: `lane-watchdog.sh`, tests in the foreground, `guard.sh --strict` before hand-off.

### 4. Windows brief (paste to the worker with the amended `PLAN.md`)
1. Pull `main`; branch from `windows`. Read `CONTRACT-NOTES.md` #49–#56 and this section; diff `GoPray/Core/Contracts.swift`, `BlockGate.swift`, `BlockState.swift`, `EmergencyLedger.swift`, `scripts/guard.sh`.
2. **Core:** `Settings` + `DisabledDefaultApps`/`CustomApps` (`Encode` writes both keys in alphabetical position; `DecodeSettings` reads them with `Optional`, default `[]`); `BlockedApps` (§1.1 rule 4 Windows denylist, `Normalize` = lower-case, strip `.exe`); `BlockStateFile.Block.HiddenApps` (`IReadOnlyList<string>?`, written always, read with the denylist/200 cap); `BlockGate`: `DefaultApps` ctor arg, capture at `StartBlock`, `_hider.Start(set)` in `Present`, `RequestEmergencyExit()`, `EndBlock(EndKind.Emergency)` → `LastDropped`, `Dismiss(kind)`; `EmergencyLedger` (primary `%LOCALAPPDATA%\GoPray\emergency.json`, mirror `%APPDATA%\GoPray\emergency.json`, same read rules as §2.3); `ShieldContext.EmergencyExitsLeft`; `IShieldDelegate.ShieldDidRequestEmergencyExit`; `IAppHiding.Start(IReadOnlySet<string>)`.
3. **App:** `CodingApps.Names` is the defaults table (already has names); `AppHider` takes the set from `Start`; Settings window "Blocked apps" section + running-apps picker + Browse (§1.3); `SceneWebView` accepts the fifth message name `emergency`; `NativeFallbackShield` gets the hold + card; tray popover footer line; `DebugMenu` "Set emergency exits used…" under `#if DEBUG`.
4. **guard.ps1:** `$EndBlockCallers = @('RequestConfirm','RequestEmergencyExit')`; rule 1 expects 3 hits; new rule 14: `emergency.json|EmergencyExitsUsed` and `RecordUse(` only in `GoPray.Core/EmergencyLedger.cs` + the one call in `BlockGate.RequestEmergencyExit`; rule 10 + 13 add `DebugSetEmergencyExitsUsed` and the debug label strings. `guard-selftest.ps1`: a negative control per new rule (a gate copy that calls `EndBlock(` from `RequestSilence`; a `RecordUse(` call in `TrayIcon.cs`; the debug method outside `#if DEBUG`).
5. **Tests** (xUnit, same names as the Mac §5): all of §5 ported; plus `mac-settings-v2.json` fixture (the Mac's new settings.json) decodes and re-encodes byte-identical; the 0.1.x `mac-state.json` fixture resumes and writes `hiddenApps`.
6. Same rules as before: minimise only, listed names only, never kill; one choke point; fail open beats no escape; `bridge.js`/`shield.html`/scenes read-only (sync from `main`); escalate, don't guess. Hand-off = `dotnet test` + `guard.ps1 -Strict` + `guard-selftest.ps1` output + screenshots of its own desktop.
7. Release: §6.

### 5. Tests (Mac names; Windows mirrors them)

**Gate + ledger (PM, `FakeClock`, `FakeLedgerMirror`, temp dir):**
1. 5 left, mid-lock → `requestEmergencyExit()` true; `state.block == nil`; `lastDropped == {prayer, athanAt}`; `lastConfirmed` unchanged; `ledger.remaining == 4`; `emergency.json` has 1 use; mirror says 1; `shield.dismiss` called with `.emergency`; `audio.stop`, `hider.stop` called.
2. Same at `canConfirm` → true (allowed in both phases). Idle → false. Leaving → false.
3. 0 left → false; block untouched; `shield.update` called with `emergencyExitsLeft == 0`.
4. Ledger write throws → false; block untouched; `remaining` unchanged; nothing in the file.
5. Relaunch mid-block → same `remaining`; `shieldContext().emergencyExitsLeft` matches.
6. File missing, mirror 3 → 2 left. Mirror 0, file 3 → 2 left. Both missing → 5. File `used: 9` → 0. Corrupt file → 0. Use dated 2099 → 0. **Negative control:** delete `state.json` → `remaining` unchanged.
7. After an emergency exit the wake rule does not re-block that prayer (`reevaluate(.wake)` inside the same window → idle); the next Athan blocks normally.
8. `endBlock(.confirmed)` still sets `lastConfirmed` and never `lastDropped` (regression guard for test 1's inverse).
9. **Capture:** block starts with settings S1 → `hider.start(hiding:)` received `effective(S1)`; swap the settings closure to S2 (simulates a bypassed store) → `reevaluate(.settingsChanged)` → the hider is not restarted with S2; relaunch mid-block → `start(hiding:)` gets the *file's* `hiddenApps`, not `effective(S2)`.
10. A state.json whose `hiddenApps` contains `com.apple.finder` and 500 entries → the hider receives neither Finder nor more than 200 ids. A 0.1.x state.json (no `hiddenApps`) mid-block → resume computes from settings and writes the key.
11. DEBUG: `debugSetEmergencyExitsUsed(5)` → 0 left; Release binary: `strings` has no `debugSetEmergencyExitsUsed` (extend `guard.sh --release` list).

**Lane E:** 0.1.1 `settings.json` fixture decodes with both new fields `[]`; disabling `com.apple.Safari` removes it from `effective`; a custom Mac app is in `effective`, a custom Windows app is not but survives a save/load round-trip byte-for-byte; `sanitized()` drops every §1.1 denylist id from both fields, dedupes, caps at 50/200, trims names to 60; `mutate` during a block throws and the list is unchanged (existing test, extend); `AppHider` with a fake workspace hides exactly the passed set and nothing else, and refuses a denylisted id even if passed (last line of defence); `CodingApps.defaults` has no denylisted id and no duplicate; UI flow: toggle a default off → saved; add → picker result saved; refusal notice text for a CoreServices pick.

**Lane F:** `BridgeMessage.parse({"type":"emergency"}) == .emergency`; `{"type":"emergency","x":1}` → nil (one key only, existing rule); payload `emergencyExitsLeft` clamped 0…5 and present in `showScript()`; with a fake gate that returns false, the page gets `show` again with the count; the footer button is absent when `emergencyExitsLeft == 0` (DOM check via the test harness like `violations()`); a `pointerup` at 2.9 s sends nothing; at 3.0 s the card shows; "Not now" sends nothing; "Use it" sends exactly one `emergency`; `GoPrayBridge.dismiss("emergency")` does not render the accept line; `ui.js` unchanged (`check-manifest.sh` fails if it is); CSP violations 0 with the new CSS; native fallback: the same flow with a 3 s `onLongPressGesture`.

**guard.sh (PM) changes + negative controls in `guard-selftest.sh`:**
- Rule 1: `endBlock(` exactly **3** hits; callers set == `{requestConfirm, requestEmergencyExit}`; a copy with a call from `requestSilence` → FAIL; 4 hits → FAIL.
- New rule 12: `emergency.json`, `EmergencyExitsUsed`, `recordUse(` only in `Core/EmergencyLedger.swift` plus exactly one `recordUse(` call in `Core/BlockGate.swift` inside `requestEmergencyExit`; a `recordUse(` in `UI/MenuView.swift` → FAIL.
- Rule 9 + `--release`: add `debugSetEmergencyExitsUsed`, `Emergency exits (debug)`; the Debug .app must FAIL `--release` (already the shape of the selftest).
- New rule 13: `hide(` on `NSRunningApplication` only in `Blocker/AppHider.swift` (today implied; make it explicit now that the list is user data).

### 6. Release steps

**Mac 0.2.0** (after Fable "architecture run: review Go Pray v2" on `main`, findings fixed or accepted in writing):
1. `project.yml` `MARKETING_VERSION: "0.2.0"` → `xcodegen generate`; `scripts/guard.sh --strict`; full test run; `guard-selftest.sh`.
2. Ship-gate replay, Release build: the §H.2 bypass table **plus** the new rows: `emergency` via the debug inspector before the hold → consumes one (documents UX-only); 0 left → no button; delete `state.json` → count unchanged; delete `emergency.json` → count unchanged (mirror); a disabled default stays usable in a coding-apps block; a custom app is hidden; Finder cannot be added. One real coding-apps block with the edited list. One real emergency exit on Ahmed's Mac (he has 5; spending 1 is the test).
3. `scripts/release.sh` → notarize with the `se-notarize` profile → staple → `build/release/GoPray-0.2.0.dmg` + `GoPray.dmg`; `spctl --assess` on the clean account; `guard.sh --release "<Go Pray.app>"`.
4. `Casks/go-pray.rb`: version `0.2.0` + sha256; push to `simkinselgazar-rgb/homebrew-tap`.
5. Squash `main` onto `public` (never push `main`); `gh release create v0.2.0` with both DMGs; **README: update the Mac button to `/releases/download/v0.2.0/GoPray.dmg`** and add the emergency-exit paragraph + "Blocked apps" line; the Windows button keeps its own tag until §6b.
6. `Go Pray.md`: amend the locked "No escape" line (→ "5 emergency exits, never refilled; everything else unchanged") and tick the v2 items. `Marketing/`: nothing (no marketing folder yet).

**Windows win-v0.2.0:**
1. Worker finishes §4; PM runs `dotnet test`, `guard.ps1 -Strict`, `guard-selftest.ps1` on the branch output, then Fable review of `windows/` v2 diffs.
2. Merge `windows` → local `main`; squash onto `public`; push; tag `win-v0.2.0` on the public commit → the `Windows release` workflow runs tests, waits for **Ahmed's approval in the `release` environment**, signs with Artifact Signing (timestamped), creates the release **`--latest=false`** with `GoPray-Setup-0.2.0.exe`, `GoPray-Setup.exe`, `.sha256`.
3. **README: Windows button → `/releases/download/win-v0.2.0/GoPray-Setup.exe`** (both links are tag-pinned; update both on every release, per the 2026-10-24 rule).
4. Ahmed's Phase-6 style check on the PC: one coding-apps block with an edited list; one emergency exit; a fresh user account installs over 0.1.0 and the count survives the upgrade (both files stay).

### 7. Decisions for Ahmed
1. **Reset policy for the 5 exits.** **A (recommend): never.** It is literally Brick's rule ("they don't reset"), it is the simplest state (a list of uses, no date math), and the scarcity is the whole point: the number stays scary. A full uninstall refills them, and that is fine (admin, not reflex). **B:** 5 per calendar year (refill on 1 January). Kinder to a family member who burns them early, but it quietly turns the exit into "five snoozes a year" and needs a date rule that a clock change can game.
2. **A "turn off emergency exits" switch (Brick's Strict Mode) in Settings.** **Recommend: not in v2.** It adds a setting, a test row and copy for people who do not want the exit at all; today's behaviour for them is simply "never hold the button". Add it in v2.1 if anyone asks; it goes through the same `authorizeSettingsChange` choke point and needs nothing else.

### 8. Feature 3 — update check (PM addendum, Ahmed 2026-10-24: "check if there is a newer update to pull")

**Pick: a minimal check + verified download + open, same shape on both platforms. Not Sparkle.** Sparkle would add the app's second dependency (a framework with its own XPC services inside our hardened, notarized bundle), an EdDSA key to keep, and an appcast to host (Ahmed just declined hosting), and it is Mac-only, so Windows would need a second mechanism anyway. The minimal version is ~200 lines per platform, uses GitHub Releases that already exist, and gets one guard rule. Revisit Sparkle only if people complain about dragging to Applications.

#### 8.1 Rules
1. **Source of truth:** `GET https://api.github.com/repos/simkinselgazar-rgb/go-pray/releases?per_page=30` (`Accept: application/vnd.github+json`, `User-Agent: GoPray` — GitHub requires a UA; no version, no id, no cookies: **no telemetry**). Skip `draft` and `prerelease`. Keep tags with this platform's prefix (`v*` Mac, `win-v*` Windows), parse semver, take the highest. Never `releases/latest` (only one release can be Latest).
2. **Newer** = strictly greater than the running version (`CFBundleShortVersionString` / assembly version). Equal or lower → nothing.
3. **When:** 30 s after launch, then every 24 h, and on wake if the last check is older than 24 h; plus the menu item **"Check for updates…"** always. **Never while `gate.isBlocked`** (no request, no download, no open; the timer just tries again later). The automatic checks obey `Settings.checkForUpdates` (default on); the menu item works even when it is off.
4. **Asset:** Mac `GoPray-<ver>.dmg`; Windows `GoPray-Setup-<ver>.exe` + `GoPray-Setup-<ver>.exe.sha256`. The URL must be exactly `https://github.com/simkinselgazar-rgb/go-pray/releases/download/<tag>/<asset>`; anything else the API returns is rejected. Size cap 300 MB. Redirects only to `github.com` / `objects.githubusercontent.com`; 10 s connect timeout, 10 min download timeout, ephemeral session.
5. **Verify before open, or delete:** Mac: `SecStaticCodeCreateWithPath` on the DMG (release.sh signs it, `release.sh:61`) + `SecStaticCodeCheckValidity` against `anchor apple generic and certificate leaf[subject.OU] = "3BB4JMG8GR"`; Gatekeeper still assesses the notarization when the DMG mounts. Windows: sha256 must match the `.sha256` asset, then `WinVerifyTrust` (`WINTRUST_ACTION_GENERIC_VERIFY_V2`) must return 0, then the signer certificate's CN must equal the pinned constant (**UNKNOWN today:** read it once from the shipped 0.1.0 exe with `Get-AuthenticodeSignature` and pin it; expected "Ahmed Elgazar"). Any failure → file deleted, menu shows *"Couldn't verify the download. Get it from GitHub."* with a link to the releases page.
6. **Open:** Mac `NSWorkspace.shared.open(dmg)` (the person drags the app; if the app runs from a Homebrew Caskroom path the menu shows *"Installed with Homebrew: run `brew upgrade --cask go-pray`"* instead of downloading). Windows: `Process.Start(setup)` then quit (`gate.shouldAllowQuit()` is true because rule 3 already excluded blocks); Inno's `CloseApplications` covers a race.
7. **Memory:** `update.json` in the support folder (`{ "schemaVersion": 1, "lastCheckedAt": "...", "latest": { "tag": "v0.2.0", "version": "0.2.0", "assetURL": "...", "size": 0 } }`), owned by the checker. Corrupt → treated as never checked. Downloads go to `<support>/updates/`, cleared on every successful open and at launch.
8. **Settings:** `checkForUpdates: Bool` (JSON key `checkForUpdates`, absent → `true`; Windows `Encode` writes it right after `athanVolume`, alphabetical). Toggle in Settings → General: **"Check for updates automatically"**, help *"Once a day, from GitHub. Nothing about you is sent."* Changing it goes through `mutate` like everything else.

#### 8.2 Contract + files
```swift
// Contracts.swift (PM): Settings gains `var checkForUpdates: Bool` (decodeIfPresent, default true).
// GoPray/Update/UpdateChecker.swift (NEW, the one new network file; lane G)
@MainActor final class UpdateChecker {
    enum Status: Equatable { case idle, checking, upToDate, available(version: String), downloading, failed(String) }
    init(transport: UpdateTransport = URLSessionTransport(), verifier: UpdateVerifier = CodesignVerifier(),
         currentVersion: String, repo: String = "simkinselgazar-rgb/go-pray", tagPrefix: String = "v",
         directory: URL = StateStore.defaultDirectory(), isBlocked: @escaping @MainActor () -> Bool,
         automatic: @escaping @MainActor () -> Bool, clock: Clock)
    private(set) var status: Status
    func start()                         // 30 s after launch, then daily; wake re-check
    func checkNow()                      // the menu item
    func downloadAndOpen()               // the "Update available" click; verify or delete
}
protocol UpdateTransport { func get(_ url: URL) async throws -> (Data, URLResponse); func download(_ url: URL, to: URL) async throws }
protocol UpdateVerifier { func verify(_ file: URL) -> Bool }   // Mac: team 3BB4JMG8GR; Windows: sha256 + Authenticode + CN
```
Windows mirror: `GoPray.App/Update/UpdateChecker.cs` (same API, `IUpdateTransport`, `IUpdateVerifier`); Core stays network-free (guard rule 12). Menu (`MenuView.swift` / tray): a footer row *"Update available: 0.2.0 — Download"* when `.available`, *"Check for updates…"* in the menu, both disabled while blocked. Copy: *"You're up to date."*, *"Downloading…"*, *"Couldn't reach GitHub. Try later."*

#### 8.3 The amended network rule (one new file; `guard.sh` rule 4 / `guard.ps1` rule 4)
- `URLSession` only in `Prayer/Geocoder.swift` **and** `Update/UpdateChecker.swift`; `CLGeocoder` only in Geocoder (unchanged).
- `api.github.com|objects.githubusercontent.com|releases/download` only in `Update/UpdateChecker.swift`, and `simkinselgazar-rgb/go-pray` appears there exactly once (the pinned repo).
- `SecStaticCodeCheckValidity|SecRequirementCreateWithString` only in `Update/UpdateChecker.swift`; the requirement string contains `3BB4JMG8GR` (fail if absent).
- The `updates` folder string and `NSWorkspace.shared.open(` of a file URL only in `Update/UpdateChecker.swift`.
- Windows: `HttpClient|WebRequest|Socket` only in `Prayer/Geocoder.cs` and `Update/UpdateChecker.cs`; `WinVerifyTrust|CreateFromSignedFile|api.github.com|releases/download|GoPray-Setup` only in `Update/UpdateChecker.cs`; `Process.Start(` with the setup path only there.
- Negative controls (`guard-selftest.sh` / `.ps1`): a `URLSession` in `MenuView.swift` → FAIL; the requirement string without the team id → FAIL; a second `api.github.com` literal elsewhere → FAIL.

#### 8.4 Threat model (short)
| Threat | Outcome |
|---|---|
| GitHub account or API response tampered, MITM | TLS + the signature/team check on the file itself: an unsigned or differently signed binary is deleted, never opened. Worst case is a false "update available" nag. |
| Downgrade or sideways "update" | only strictly greater versions are offered; URL pinned to our repo path. |
| Huge or endless download | 300 MB cap, timeouts, one download at a time. |
| Check during a block, or opening an installer mid-block | rule 3: no network and no open while `isBlocked`; tested with a fake transport that asserts zero calls. |
| Telemetry | one anonymous GET per day to GitHub, UA `GoPray`, no identifiers. The toggle stops even that. |
| Supply chain | no new dependency; Security.framework / WinTrust are OS APIs. |

#### 8.5 Tests (lane G, fake transport + fake verifier)
Releases fixture with `v0.1.1`, `v0.2.0`, `win-v0.2.0`, a draft `v0.3.0`, a prerelease `v0.3.0-beta`: Mac picks `0.2.0`, Windows `win-v0.2.0`; current `0.2.0` → `.upToDate`; asset URL off the repo path → rejected; size over cap → rejected; `isBlocked` true → zero transport calls on start and on `checkNow`; `checkForUpdates` false → no automatic call, `checkNow` still works; `lastCheckedAt` 23 h ago → no call, 25 h → call; corrupt `update.json` → one call; verifier false → file gone, `.failed`, open not called; verifier true → open called once, `updates/` emptied; redirect to another host → cancelled; Homebrew path → no download, the brew line shown. Live, once per release: the Release app on a clean account sees the new version and opens a verified DMG.

#### 8.6 Lane + release changes
- **Lane G (Sonnet, small): `Update/*`, `UI/MenuView.swift` (moved here from lane F; F keeps Shield + bridge only), Settings → General toggle row, `GoPrayTests/Update/*`.** PM adds the `checkForUpdates` field and the guard rules with the other contract work. Windows: one more item in the §4 brief (`Update/UpdateChecker.cs`, tray row, General toggle, guard rule 4 + selftest; pin the Authenticode CN after reading it from the shipped 0.1.0 exe).
- Release steps: asset names stay exactly `GoPray-<ver>.dmg` and `GoPray-Setup-<ver>.exe` (+ `.sha256`) forever; `release.sh` keeps signing the DMG; tags keep their prefixes. Mac 0.2.0 is the first version that can see 0.2.1.

#### 8.7 Decision 3 for Ahmed
**Sparkle (auto-install in place, Mac only) vs the minimal check + verified download + open (both platforms).** **Recommend minimal**: no new dependency, nothing to host, one guard rule, same code shape on the PC, and the Mac user does one drag. Pick Sparkle only if the drag turns out to be a real complaint; it can be added later without touching the gate.

### 10. PM note (2026-10-24) — read WITH Fable's §9 right after this note. Where they differ, **Fable's §9 wins on details** (setting key is `emergencyExitsEnabled`, absent → true; the Mac mirror is a UserDefaults JSON string). This note only adds the updater approval and the lean-build rule.
1. **Emergency exits: 5 per calendar year** (not "never"). `remaining = 5 − count(uses whose timestamp falls in the current local calendar year)`; a use dated in the future (clock moved back) still counts as used (fail safe); moving the clock forward into next year refills — accepted as a deliberate act (add to the SEC table). Mirror rule unchanged (remaining = 5 − max(ledger, mirror) per year). Copy: "N of 5 emergency exits left this year".
2. **Strict mode IN v2:** Settings → General → "Allow emergency exits" (JSON key `emergencyExitsEnabled` per §9, absent → **true**, i.e. on by default; UI label "Allow emergency exits"). Changed only between prayers via `authorizeSettingsChange`; **captured into `state.block` at block start** (like the app list and lockMinutes), so a mid-block flip cannot add or remove the button. Off → the hold button never renders and the gate refuses `requestEmergencyExit()`.
3. **Updater: the minimal check + verified download (§8), not Sparkle.** Windows signer CN is known: **"Ahmed Elgazar"** (verified on the shipped win-v0.1.0 installer).
4. **Lean build (Ahmed: "take it easy on the usage"):** Mac = ONE Sonnet lane doing the PM contract then features 1 → 2 → 3 in order (not lanes E/F/G in parallel); the PM verifies once. Windows = the worker's own brief after the Mac contract + bridge.js land on main.

### 9. Amendments after Ahmed's decisions (2026-10-24, PM relay) — these override §2 and §7 where they differ

**Decision 1 → 5 per calendar year.** **Decision 2 → "Allow emergency exits" switch in v2, ON by default.** Decision 3 (minimal updater, §8) stands. Feature 3 (§8) is part of v2.

#### 9.1 Ledger rule (replaces §2.2 rule 1 and the `remaining` line in §2.3)
- `remaining = max(0, total − counted)`, where `counted` = uses whose `at` falls in the **current local calendar year** (`Calendar.autoupdatingCurrent`, `TimeZone.autoupdatingCurrent`; Windows `TimeZoneInfo.Local`), **plus every use dated after `now`** (clock moved back: still counts, fail safe). Computed at read time, every time; nothing cached across launches. Uses from earlier years stay in the file (history) and simply stop counting.
- The mirror must carry dates too, so the Mac mirror becomes `UserDefaults.standard` **string** `EmergencyExitsUsed` holding the same `used[]` JSON (not an int); Windows mirror stays the second file. `remaining` is computed from **each** store with the year rule and the **smaller** remaining wins (= the larger count).
- `EmergencyExitPolicy` gains `static let period = "calendar year"`; `EmergencyLedger.remaining(at now: Date) -> Int` takes the clock (tests use `FakeClock`).

#### 9.2 Settings switch (new; both platforms)
```swift
// Contracts.swift: Settings gains
var emergencyExitsEnabled: Bool          // JSON "emergencyExitsEnabled", absent → true (decodeIfPresent)
// BlockState.swift: Block gains
var emergencyExitsEnabled: Bool          // captured at block start; absent in a 0.1.x file → true
```
Windows `Encode` writes `emergencyExitsEnabled` between `disabledDefaultApps` and `highLatitudeRule`; `Block` encode writes it after `blockStartedAt` (alphabetical, `SwiftJson` order). Changing the switch goes through `SettingsStore.mutate` → `authorizeSettingsChange()`, so it is refused during a block; and because the gate reads the **captured** `block.emergencyExitsEnabled`, a flip that slipped past the store still cannot touch the running block (same shape as `hiddenApps`, §1.1 rule 3). `requestEmergencyExit()` requires `block.emergencyExitsEnabled && remaining > 0`; `shieldContext().emergencyExitsLeft` is `0` whenever the captured flag is false, so the page draws no button.

Settings → Block: **Toggle "Allow emergency exits"**, help *"Up to 5 a year, for the days you truly can't stop. Off means no exit button at all. Changes start at the next prayer."*

#### 9.3 Copy changes (replace in §2.5)
- Shield footer: **"Emergency exit · 3 of 5 left this year"**. Absent at 0 or when the captured flag is off.
- Confirm card last line: **"You'll have 2 of 5 left this year."**; at the last one: **"This is your last one this year."**
- Menu footer / Settings caption: **"Emergency exits: 3 of 5 left this year"**; at 0: **"Emergency exits: none left until 1 January"**; switch off: **"Emergency exits: off"**.
- README: "5 a year; they come back on 1 January; you can turn them off in Settings."

#### 9.4 SEC table additions (append to §2.4)
| Threat | What happens | Verdict |
|---|---|---|
| Set the clock forward into next year, use exits, set it back | the year rule refills them while the clock is forward; set back, those uses are "in the future" and count against this year again (so the refill is spent, not free). Net: a person can get at most one extra batch per deliberate clock trip. | **accepted as a deliberate act** (Ahmed 2026-10-24); same class as `ssh` + `launchctl bootout`. Noted in the README. |
| Set the clock back within the year | future-dated uses still count | built in (fail safe) |
| Time zone change around New Year | the local year flips a few hours early or late | accepted (hours, not a refill) |
| Flip "Allow emergency exits" mid-block | refused by `authorizeSettingsChange`; if bypassed, the captured flag rules the running block | built in, tested |
| Turn the switch off, then on again, to dodge a block | both changes need an idle gate; nothing about the count changes | built in |

#### 9.5 Tests (add to §5)
- Year rule: 5 uses dated last year → 5 left; 3 this year → 2 left; 2 this year + 2 dated tomorrow → 1 left; 6 this year → 0; a use at 23:59:59 on 31 Dec counts for that year, 00:00:00 on 1 Jan for the next (local time, `FakeClock` + a fixed `TimeZone`); the mirror and the file each with 3 different uses this year → the larger count (3, not 6, not the sum — unless they disagree: file 2, mirror 4 → 1 left).
- Switch: block starts with `emergencyExitsEnabled == false` → `shieldContext().emergencyExitsLeft == 0`, `requestEmergencyExit()` false, ledger untouched; `mutate { $0.emergencyExitsEnabled = true }` during a block throws (file unchanged); swapping the settings closure mid-block does not change the captured flag; 0.1.x `state.json` resumes with the flag `true`; `settings.json` without the key decodes `true`; Windows round-trip of the new keys is byte-identical to the Mac fixture.
- Guard: no new rule; `emergencyExitsEnabled` is read in the gate only from `state.block` (a unit test asserts the gate never consults `settings().emergencyExitsEnabled` after block start, via the closure-swap test above).

#### 9.6 Decisions, final
1. Exits: **5 per calendar year** (Ahmed). 2. **Switch in v2, on by default** (Ahmed). 3. **Minimal updater, not Sparkle** (recommended; §8.7, awaiting Ahmed).
