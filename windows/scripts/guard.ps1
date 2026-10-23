<#
guard.ps1 — grep guards for Go Pray for Windows. Translation of scripts/guard.sh (PLAN.md §6).
Runs before every merge (and, from Phase 2, as a build target). Any failure exits 1.

  scripts\guard.ps1                      check windows\src (pre-ship rules)
  scripts\guard.ps1 -Strict              also require the ship-time "exactly one" hits
  scripts\guard.ps1 -Release <dir>       also scan a Release publish dir's .exe/.dll for debug strings
  scripts\guard.ps1 -Src <dir>           check <dir> instead (negative controls; guard-selftest.ps1)

Line comments (// …, /// …) and block comments are stripped before matching, so docs may name
the symbols. Paths are relative to the source dir, with forward slashes ("GoPray.Core/BlockGate.cs").
#>
[CmdletBinding()]
param(
    [string]$Src = '',
    [switch]$Strict,
    [string]$Release = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# The methods allowed to call EndBlock(. One today. The PM-approved emergency exit (not built) would
# add its method name here, and nowhere else (BlockGate.cs header).
$EndBlockCallers = @('RequestConfirm')

$GateFile    = 'GoPray.Core/BlockGate.cs'
$Geocoder    = 'GoPray.App/Prayer/Geocoder.cs'
$SceneWeb    = 'GoPray.App/Shield/SceneWebView.cs'
$KeyGuard    = 'GoPray.App/Shield/KeyboardGuard.cs'
$MediaPauser = 'GoPray.App/Audio/MediaPauser.cs'
$AppHider    = 'GoPray.App/Blocker/AppHider.cs'

if (-not $Src) { $Src = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'src' }
if (-not (Test-Path -LiteralPath $Src -PathType Container)) { Write-Output "guard: no source dir $Src"; exit 2 }
$Src = (Resolve-Path -LiteralPath $Src).Path

$script:fail = $false
function Bad([string]$m) { Write-Output "guard FAIL: $m"; $script:fail = $true }

# --- Index every .cs line: file, line number, code with comments removed, and #if DEBUG depth. ---
$lines = New-Object System.Collections.Generic.List[object]
$files = Get-ChildItem -LiteralPath $Src -Recurse -File -Filter *.cs |
    Where-Object { $_.FullName -notmatch '[\\/](bin|obj)[\\/]' } | Sort-Object FullName
foreach ($f in $files) {
    $rel = $f.FullName.Substring($Src.Length).TrimStart('\', '/').Replace('\', '/')
    $inBlock = $false
    $stack = New-Object System.Collections.Generic.List[bool]    # per #if level: is this branch DEBUG-only?
    $conds = New-Object System.Collections.Generic.List[string]
    $n = 0
    foreach ($raw in [IO.File]::ReadAllLines($f.FullName)) {
        $n++
        $code = $raw
        if ($inBlock) {
            $end = $code.IndexOf('*/')
            if ($end -lt 0) { $code = '' } else { $code = $code.Substring($end + 2); $inBlock = $false }
        }
        while ($true) {
            $start = $code.IndexOf('/*')
            if ($start -lt 0) { break }
            $end = $code.IndexOf('*/', $start + 2)
            if ($end -lt 0) { $code = $code.Substring(0, $start); $inBlock = $true; break }
            $code = $code.Substring(0, $start) + ' ' + $code.Substring($end + 2)
        }
        $sl = $code.IndexOf('//')
        if ($sl -ge 0) { $code = $code.Substring(0, $sl) }

        $t = $code.Trim()
        # Each #if level remembers its condition; a branch is DEBUG-only for "#if DEBUG" (if-branch)
        # and for "#if !DEBUG" (else-branch). Any other condition or an #elif branch is not.
        if ($t -match '^#if\s+(.+)$') { $conds.Add($Matches[1].Trim()); $stack.Add(($Matches[1].Trim() -eq 'DEBUG')) }
        elseif ($t -match '^#elif\b') { if ($stack.Count) { $conds[$conds.Count - 1] = '?'; $stack[$stack.Count - 1] = $false } }
        elseif ($t -match '^#else\b') { if ($stack.Count) { $stack[$stack.Count - 1] = ($conds[$conds.Count - 1] -eq '!DEBUG') } }
        elseif ($t -match '^#endif\b') { if ($stack.Count) { $stack.RemoveAt($stack.Count - 1); $conds.RemoveAt($conds.Count - 1) } }
        $inDebug = $stack -contains $true
        if ($t -ne '') { $lines.Add([pscustomobject]@{ File = $rel; Line = $n; Code = $code; Debug = $inDebug }) }
    }
}

function Hits([string]$pat) { @($lines | Where-Object { $_.Code -match $pat }) }
# Occurrences, not lines: two calls on one line count twice.
function Count([string]$pat) { $n = 0; foreach ($l in $lines) { $n += [regex]::Matches($l.Code, $pat).Count }; $n }
function Show($h) { (@($h) | Select-Object -First 3 | ForEach-Object { "$($_.File):$($_.Line)" }) -join ' ' }
function OnlyIn([string]$pat, [string]$allowed) {
    $out = @(Hits $pat | Where-Object { $_.File -ne $allowed })
    if ($out.Count) { Bad "'$pat' outside ${allowed}: $(Show $out)" }
}
function Zero([string]$pat) {
    $h = @(Hits $pat)
    if ($h.Count) { Bad "'$pat' must not appear ($($h.Count) hits): $(Show $h)" }
}

# 1. EndBlock( : exactly 2 (private declaration + one call), both in BlockGate.cs, the call(s) only
#    inside the allowed methods.
$eb = @(Hits 'EndBlock\(')
$ebn = Count 'EndBlock\('
if ($ebn -ne (1 + $EndBlockCallers.Count)) { Bad "EndBlock( appears $ebn times (want $(1 + $EndBlockCallers.Count): declaration + the call in $($EndBlockCallers -join ', '))" }
OnlyIn 'EndBlock\(' $GateFile
$decl = @($eb | Where-Object { $_.Code -match '\bvoid\s+EndBlock\(' })
if ($decl.Count -ne 1 -or $decl[0].Code -notmatch '^\s*private\s+void\s+EndBlock\(') { Bad "EndBlock must be declared exactly once, 'private void EndBlock('" }
# Enclosing member = the last member declaration (4-space indent, access modifier) above the call.
$gate = @($lines | Where-Object { $_.File -eq $GateFile })
$current = ''
$callers = New-Object System.Collections.Generic.List[string]
foreach ($l in $gate) {
    if ($l.Code -match '^ {4}(public|private|internal|protected)\b[^=;]*?\b([A-Za-z_]\w*)\s*\(') { $current = $Matches[2] }
    if ($l.Code -match 'EndBlock\(' -and $l.Code -notmatch '\bvoid\s+EndBlock\(') { $callers.Add($current) }
}
$bad = @($callers | Where-Object { $EndBlockCallers -notcontains $_ } | Sort-Object -Unique)
if ($bad.Count -or $callers.Count -eq 0) { Bad "EndBlock( called from '$((@($callers) | Sort-Object -Unique) -join ',')', want only $($EndBlockCallers -join ', ')" }

# 2. FailOpen( : only in BlockGate.cs, declared private.
OnlyIn 'FailOpen\(' $GateFile
$fo = @(Hits '\bvoid\s+FailOpen\(')
if ((Hits 'FailOpen\(').Count -gt 0 -and ($fo.Count -ne 1 -or $fo[0].Code -notmatch '^\s*private\s+void\s+FailOpen\(')) { Bad "FailOpen must be declared exactly once, 'private void FailOpen('" }

# 3. Never kill, close, hide, inject input, read key state, change policy, elevate, or resume media.
foreach ($p in @('\.Kill\(', 'TerminateProcess', 'taskkill', 'SW_HIDE', 'WM_CLOSE', 'WM_QUIT', 'SendInput', 'keybd_event',
                 'mouse_event', 'GetAsyncKeyState', 'GetKeyboardState', 'DisableLockWorkstation', 'DisableTaskMgr',
                 'DisableChangePassword', 'NoLogoff', 'HideFastUserSwitching', 'Policies\\\\?System', 'requireAdministrator',
                 'TryPlayAsync', 'TryTogglePlayPauseAsync', 'TrySkipNextAsync', 'TrySkipPreviousAsync', 'TryStopAsync')) { Zero $p }
$manifests = @(Get-ChildItem -LiteralPath $Src -Recurse -File -Include *.manifest, *.csproj -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '[\\/](bin|obj)[\\/]' } | Select-String -Pattern 'requireAdministrator|highestAvailable')
if ($manifests.Count) { Bad "manifest/project asks for elevation: $(($manifests | Select-Object -First 3 | ForEach-Object { $_.Filename + ':' + $_.LineNumber }) -join ' ')" }

# 4. Network: only the geocoder file.
OnlyIn '\bHttpClient\b|\bWebRequest\b|\bWebClient\b|\bSocket\b|\bTcpClient\b|\bUdpClient\b' $Geocoder

# 5. WebView2: built, loaded and bridged only in the one locked-down file.
OnlyIn 'new\s+WebView2\b|CoreWebView2Environment|EnsureCoreWebView2|ExecuteScriptAsync|AddScriptToExecuteOnDocumentCreatedAsync|WebMessageReceived|NavigateToString|\.Navigate\(' $SceneWeb
$vh = @(Hits 'SetVirtualHostNameToFolderMapping')
OnlyIn 'SetVirtualHostNameToFolderMapping' $SceneWeb
$vhn = Count 'SetVirtualHostNameToFolderMapping'
if ($vhn -gt 1) { Bad "SetVirtualHostNameToFolderMapping appears $vhn times (want exactly 1)" }
if ($Strict -and $vhn -ne 1) { Bad "-Strict: SetVirtualHostNameToFolderMapping appears $vhn times (want exactly 1)" }
foreach ($h in $vh) {
    if ($h.Code -notmatch 'CoreWebView2HostResourceAccessKind\.Deny') { Bad "SetVirtualHostNameToFolderMapping must use access kind Deny: $($h.File):$($h.Line)" }
    if ($h.Code -notmatch '(?i)scenes') { Bad "SetVirtualHostNameToFolderMapping must point at the scenes folder: $($h.File):$($h.Line)" }
}

# 6. DevTools only inside #if DEBUG.
$dev = @(Hits 'AreDevToolsEnabled\s*=\s*true' | Where-Object { -not $_.Debug })
if ($dev.Count) { Bad "AreDevToolsEnabled = true outside #if DEBUG: $(Show $dev)" }

# 7. The keyboard hook lives in one file, and that file cannot store, log or write anything.
OnlyIn 'SetWindowsHookEx|WH_KEYBOARD_LL|UnhookWindowsHookEx' $KeyGuard
$kg = @($lines | Where-Object { $_.File -eq $KeyGuard -and $_.Code -match 'File\.|Console\.|Debug\.Write|Trace\.|ILogger|StringBuilder|List<|Dictionary<|HashSet<|Queue<|\.Append|CoreLog|Stream\b|Log\.' })
if ($kg.Count) { Bad "$KeyGuard may not store, log or write anything: $(Show $kg)" }

# 8. Media: one file, one pause call.
OnlyIn 'GlobalSystemMediaTransportControls' $MediaPauser
$tpn = Count 'TryPauseAsync'
if ($tpn -gt 1) { Bad "TryPauseAsync appears $tpn times (want at most 1)" }
if ($Strict -and $tpn -ne 1) { Bad "-Strict: TryPauseAsync appears $tpn times (want exactly 1)" }

# 9. Minimise only in the hider.
OnlyIn '\bShowWindow(Async)?\s*\(' $AppHider

# 10. Debug entry points stay behind #if DEBUG.
$dbg = @(Hits 'DebugTriggerAthan|DebugWipeState|DebugWindowEnd|GOPRAY_DEBUG_HIDE_ONLY|--debug-|\bDebugMenu\b|\bDebugHarness\b|DebugCrashRenderer' | Where-Object { -not $_.Debug })
if ($dbg.Count) { Bad "debug entry point outside #if DEBUG: $(Show $dbg)" }

# 12. Core is pure: no Windows UI, registry or native calls (so the law is testable anywhere).
$core = @($lines | Where-Object { $_.File -like 'GoPray.Core/*' -and $_.Code -match 'System\.Windows|Microsoft\.Win32|\bWindows\.(Media|UI|Foundation|System)\b|DllImport|LibraryImport|WinForms' })
if ($core.Count) { Bad "GoPray.Core must not use Windows UI/registry/native APIs: $(Show $core)" }
$coreProj = @(Get-ChildItem -LiteralPath $Src -Recurse -File -Filter GoPray.Core.csproj -ErrorAction SilentlyContinue | Select-String -Pattern 'UseWPF|UseWindowsForms|-windows')
if ($coreProj.Count) { Bad "GoPray.Core.csproj must target plain net10.0 (no WPF/WinForms/-windows TFM)" }

# 11. The scenes the app ships match MANIFEST.sha256 byte for byte (the build runs it too).
$scenes = Join-Path (Split-Path -Parent $Src) '..\GoPray\Resources\scenes'
$appScenes = Join-Path $Src 'GoPray.App\Resources\scenes'
if ((Test-Path -LiteralPath $appScenes) -and (Test-Path -LiteralPath (Join-Path $appScenes 'MANIFEST.sha256'))) {
    $cm = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'check-manifest.ps1') -Dir $appScenes 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Bad "check-manifest: $($cm.Trim())" }
}

# 13. Release publish dir: no debug strings in any binary (ASCII or UTF-16, as .NET stores literals).
if ($Release) {
    if (-not (Test-Path -LiteralPath $Release -PathType Container)) { Bad "-Release: no directory $Release" }
    else {
        # .exe/.dll only (PowerShell 5.1 ignores -Include with -LiteralPath, so filter by extension). Symbols (.pdb)
        # name source files such as DebugHarness.cs; release.ps1 must not ship them (Phase 5).
        $bins = @(Get-ChildItem -LiteralPath $Release -Recurse -File | Where-Object { $_.Name -like 'GoPray*' -and @('.exe', '.dll') -contains $_.Extension.ToLowerInvariant() })
        if (-not $bins.Count) { Bad "-Release: no GoPray*.exe/.dll in $Release" }
        $needles = @('Trigger Athan', 'DebugTriggerAthan', 'DebugWipeState', 'DebugWindowEnd', 'debugWindowEnd', 'GOPRAY_DEBUG_HIDE_ONLY', '--debug-seed', '--debug-shield', 'DebugHarness', 'Page.crash')
        foreach ($b in $bins) {
            $bytes = [IO.File]::ReadAllBytes($b.FullName)
            $ascii = [Text.Encoding]::ASCII.GetString($bytes)
            $utf16 = [Text.Encoding]::Unicode.GetString($bytes)
            $utf16b = if ($bytes.Length -gt 1) { [Text.Encoding]::Unicode.GetString($bytes, 1, $bytes.Length - 1) } else { '' }
            foreach ($s in $needles) {
                if ($ascii.Contains($s) -or $utf16.Contains($s) -or $utf16b.Contains($s)) { Bad "-Release: '$s' found in $($b.Name)" }
            }
        }
    }
}

if (-not $script:fail) { Write-Output "guard: OK ($Src)$(if ($Strict) { ' -Strict' })$(if ($Release) { " -Release $Release" })"; exit 0 }
exit 1
