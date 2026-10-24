<#
guard-selftest.ps1 — proves every guard.ps1 rule fires (negative controls) and that allowed shapes
pass (positive controls). Each case copies windows\src to a temp dir, plants one change, runs
guard.ps1 -Src <copy>, and checks the exit code and the message. Also checks -Release on a Debug
build of GoPray.Core (must fail) and a Release build (must pass).

  scripts\guard-selftest.ps1 [-Dotnet <path to dotnet.exe>] [-SkipRelease]
#>
[CmdletBinding()]
param([string]$Dotnet = 'dotnet', [switch]$SkipRelease)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$guard = Join-Path $here 'guard.ps1'
$src = Join-Path (Split-Path -Parent $here) 'src'
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("gopray-guard-selftest-" + [guid]::NewGuid().ToString('N'))
$results = New-Object System.Collections.Generic.List[object]

function Copy-Src([string]$dest) {
    New-Item -ItemType Directory -Force $dest | Out-Null
    Get-ChildItem -LiteralPath $src -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/](bin|obj)[\\/]' } | ForEach-Object {
        $rel = $_.FullName.Substring($src.Length).TrimStart('\', '/')
        $to = Join-Path $dest $rel
        New-Item -ItemType Directory -Force (Split-Path -Parent $to) | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $to
    }
}
function Put([string]$root, [string]$rel, [string]$text) {
    $p = Join-Path $root $rel
    New-Item -ItemType Directory -Force (Split-Path -Parent $p) | Out-Null
    [IO.File]::WriteAllText($p, $text)
}
function Edit-File([string]$root, [string]$rel, [string]$old, [string]$new) {
    # The anchors are written with LF. A CRLF checkout (core.autocrlf=true, as on GitHub's Windows runners) is
    # matched as LF and written back with CRLF, so the planted change looks like the rest of the file.
    $p = Join-Path $root $rel
    $raw = [IO.File]::ReadAllText($p)
    $crlf = $raw.Contains("`r`n")
    $c = $raw.Replace("`r`n", "`n")
    $old = $old.Replace("`r`n", "`n"); $new = $new.Replace("`r`n", "`n")
    if (-not $c.Contains($old)) { throw "selftest setup: '$old' not found in $rel" }
    $c = $c.Replace($old, $new)
    if ($crlf) { $c = $c.Replace("`n", "`r`n") }
    [IO.File]::WriteAllText($p, $c)
}
function Run-Guard([string]$dir, [string[]]$extra = @()) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $guard -Src $dir @extra 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out }
}

# A minimal, allowed App tree: the files that own each pinned API, written the allowed way.
$okApp = @{
    'GoPray.App/Shield/SceneWebView.cs' = "class SceneWebView { void Load() { core.SetVirtualHostNameToFolderMapping(""gopray.invalid"", scenesFolder, CoreWebView2HostResourceAccessKind.Deny); core.ExecuteScriptAsync(""x""); } }"
    'GoPray.App/Audio/MediaPauser.cs'   = "class MediaPauser { async void P() { var m = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync(); await s.TryPauseAsync(); } }"
    'GoPray.App/Shield/KeyboardGuard.cs' = "class KeyboardGuard { void I() { h = SetWindowsHookEx(WH_KEYBOARD_LL, p, m, 0); } }"
    'GoPray.App/Blocker/AppHider.cs'    = "class AppHider { void M() { ShowWindow(h, SW_MINIMIZE); } }"
    'GoPray.App/Prayer/Geocoder.cs'     = "class Geocoder { static readonly HttpClient c = new(); }"
}

# name, expect (OK|FAIL), message regex, setup { param($d) ... }
$cases = @(
    @{ N = 'clean tree passes'; E = 'OK'; M = 'guard: OK'; S = { param($d) } }
    @{ N = 'allowed App files pass'; E = 'OK'; M = 'guard: OK'; S = { param($d) foreach ($k in $okApp.Keys) { Put $d $k $okApp[$k] } } }
    @{ N = 'allowed App files pass -Strict'; E = 'OK'; M = 'guard: OK'; X = @('-Strict'); S = { param($d) foreach ($k in $okApp.Keys) { Put $d $k $okApp[$k] } } }
    @{ N = 'commented-out violations pass'; E = 'OK'; M = 'guard: OK'; S = { param($d) Put $d 'GoPray.App/X.cs' "// p.Kill(); SendInput(...)`n/* TerminateProcess(h, 1);`n   WM_CLOSE */ class X {}" } }
    @{ N = 'rule 1: second EndBlock caller'; E = 'FAIL'; M = 'EndBlock\( (appears|called from)'; S = { param($d) Edit-File $d 'GoPray.Core/BlockGate.cs' '    public void RequestSilence()' "    public void Sneak() { EndBlock(EndKind.Confirmed); }`n    public void RequestSilence()" } }
    @{ N = 'rule 1: EndBlock moved to another method'; E = 'FAIL'; M = 'called from'; S = { param($d) Edit-File $d 'GoPray.Core/BlockGate.cs' "        EndBlock(EndKind.Confirmed);`n        return true;" "        return Other();`n    }`n    private bool Other() {`n        EndBlock(EndKind.Confirmed);`n        return true;" } }
    @{ N = 'rule 1: EndBlock made public'; E = 'FAIL'; M = "private void EndBlock"; S = { param($d) Edit-File $d 'GoPray.Core/BlockGate.cs' 'private void EndBlock(' 'public void EndBlock(' } }
    @{ N = 'rule 1: EndBlock called outside the gate'; E = 'FAIL'; M = 'EndBlock\('; S = { param($d) Put $d 'GoPray.App/Tray.cs' 'class T { void Q() { gate.EndBlock(x); } }' } }
    @{ N = 'rule 2: FailOpen outside the gate'; E = 'FAIL'; M = "FailOpen\\\(' outside"; S = { param($d) Put $d 'GoPray.App/Tray.cs' 'class T { void Q() { FailOpen(r); } }' } }
    @{ N = 'rule 2: FailOpen made internal'; E = 'FAIL'; M = 'private void FailOpen'; S = { param($d) Edit-File $d 'GoPray.Core/BlockGate.cs' 'private void FailOpen(' 'internal void FailOpen(' } }
    @{ N = 'rule 3: Process.Kill'; E = 'FAIL'; M = "Kill"; S = { param($d) Put $d 'GoPray.App/X.cs' 'class X { void K(System.Diagnostics.Process p) { p.Kill(); } }' } }
    @{ N = 'rule 3: TerminateProcess'; E = 'FAIL'; M = 'TerminateProcess'; S = { param($d) Put $d 'GoPray.App/X.cs' 'class X { [DllImport("kernel32")] static extern bool TerminateProcess(nint h, uint c); }' } }
    @{ N = 'rule 3: SW_HIDE'; E = 'FAIL'; M = 'SW_HIDE'; S = { param($d) Put $d 'GoPray.App/Blocker/AppHider.cs' 'class A { const int SW_HIDE = 0; void M() { ShowWindow(h, SW_HIDE); } }' } }
    @{ N = 'rule 3: WM_CLOSE'; E = 'FAIL'; M = 'WM_CLOSE'; S = { param($d) Put $d 'GoPray.App/X.cs' 'class X { const int WM_CLOSE = 0x10; }' } }
    @{ N = 'rule 3: SendInput'; E = 'FAIL'; M = 'SendInput'; S = { param($d) Put $d 'GoPray.App/X.cs' 'class X { static extern uint SendInput(uint n, nint i, int s); }' } }
    @{ N = 'rule 3: GetAsyncKeyState'; E = 'FAIL'; M = 'GetAsyncKeyState'; S = { param($d) Put $d 'GoPray.App/Shield/KeyboardGuard.cs' 'class K { static extern short GetAsyncKeyState(int v); }' } }
    @{ N = 'rule 3: policy key'; E = 'FAIL'; M = 'DisableLockWorkstation'; S = { param($d) Put $d 'GoPray.App/X.cs' 'class X { string k = "DisableLockWorkstation"; }' } }
    @{ N = 'rule 3: TryPlayAsync'; E = 'FAIL'; M = 'TryPlayAsync'; S = { param($d) Put $d 'GoPray.App/Audio/MediaPauser.cs' 'class M { void R() { s.TryPlayAsync(); } }' } }
    @{ N = 'rule 3: requireAdministrator manifest'; E = 'FAIL'; M = 'elevation|requireAdministrator'; S = { param($d) Put $d 'GoPray.App/app.manifest' '<requestedExecutionLevel level="requireAdministrator" />' } }
    @{ N = 'rule 4: HttpClient outside geocoder'; E = 'FAIL'; M = 'HttpClient'; S = { param($d) Put $d 'GoPray.App/UI/Credits.cs' 'class C { HttpClient c; }' } }
    @{ N = 'rule 5: ExecuteScriptAsync outside SceneWebView'; E = 'FAIL'; M = 'outside GoPray.App/Shield/SceneWebView.cs'; S = { param($d) Put $d 'GoPray.App/Shield/ShieldWindow.cs' 'class W { void J() { core.ExecuteScriptAsync("1"); } }' } }
    @{ N = 'rule 5: second virtual host'; E = 'FAIL'; M = 'appears 2 times'; S = { param($d) Put $d 'GoPray.App/Shield/SceneWebView.cs' ($okApp['GoPray.App/Shield/SceneWebView.cs'] + "`nclass Y { void L() { core.SetVirtualHostNameToFolderMapping(""b"", scenesFolder, CoreWebView2HostResourceAccessKind.Deny); } }") } }
    @{ N = 'rule 5: virtual host with Allow'; E = 'FAIL'; M = 'Deny'; S = { param($d) Put $d 'GoPray.App/Shield/SceneWebView.cs' 'class S { void L() { core.SetVirtualHostNameToFolderMapping("h", scenesFolder, CoreWebView2HostResourceAccessKind.Allow); } }' } }
    @{ N = 'rule 5: virtual host not on scenes'; E = 'FAIL'; M = 'scenes folder'; S = { param($d) Put $d 'GoPray.App/Shield/SceneWebView.cs' 'class S { void L() { core.SetVirtualHostNameToFolderMapping("h", @"C:\", CoreWebView2HostResourceAccessKind.Deny); } }' } }
    @{ N = 'rule 6: DevTools outside DEBUG'; E = 'FAIL'; M = 'AreDevToolsEnabled'; S = { param($d) Put $d 'GoPray.App/Shield/SceneWebView.cs' 'class S { void L() { s.AreDevToolsEnabled = true; } }' } }
    @{ N = 'rule 6: DevTools inside #if DEBUG passes'; E = 'OK'; M = 'guard: OK'; S = { param($d) Put $d 'GoPray.App/Shield/SceneWebView.cs' "class S { void L() {`n#if DEBUG`n s.AreDevToolsEnabled = true;`n#endif`n } }" } }
    @{ N = 'rule 6: DevTools in #if DEBUG #else branch'; E = 'FAIL'; M = 'AreDevToolsEnabled'; S = { param($d) Put $d 'GoPray.App/Shield/SceneWebView.cs' "class S { void L() {`n#if DEBUG`n x();`n#else`n s.AreDevToolsEnabled = true;`n#endif`n } }" } }
    @{ N = 'rule 7: hook outside KeyboardGuard'; E = 'FAIL'; M = 'SetWindowsHookEx'; S = { param($d) Put $d 'GoPray.App/Shield/ShieldWindow.cs' 'class W { void H() { SetWindowsHookEx(13, p, m, 0); } }' } }
    @{ N = 'rule 7: KeyboardGuard writes a file'; E = 'FAIL'; M = 'may not store'; S = { param($d) Put $d 'GoPray.App/Shield/KeyboardGuard.cs' ($okApp['GoPray.App/Shield/KeyboardGuard.cs'] + "`nclass L { void W(int vk) { File.AppendAllText(""k"", vk.ToString()); } }") } }
    @{ N = 'rule 7: KeyboardGuard keeps a list'; E = 'FAIL'; M = 'may not store'; S = { param($d) Put $d 'GoPray.App/Shield/KeyboardGuard.cs' ($okApp['GoPray.App/Shield/KeyboardGuard.cs'] + "`nclass L { List<int> keys = new(); }") } }
    @{ N = 'rule 8: GSMTC outside MediaPauser'; E = 'FAIL'; M = 'GlobalSystemMediaTransportControls'; S = { param($d) Put $d 'GoPray.App/Audio/AthanPlayer.cs' 'class A { object m = GlobalSystemMediaTransportControlsSessionManager.RequestAsync(); }' } }
    @{ N = 'rule 8: two TryPauseAsync'; E = 'FAIL'; M = 'TryPauseAsync appears 2'; S = { param($d) Put $d 'GoPray.App/Audio/MediaPauser.cs' 'class M { void P() { a.TryPauseAsync(); b.TryPauseAsync(); } }' } }
    @{ N = 'rule 9: ShowWindow outside AppHider'; E = 'FAIL'; M = 'ShowWindow'; S = { param($d) Put $d 'GoPray.App/Shield/ShieldWindow.cs' 'class W { void M() { ShowWindow(h, 6); } }' } }
    @{ N = 'rule 10: debug entry outside #if DEBUG'; E = 'FAIL'; M = 'debug entry point'; S = { param($d) Put $d 'GoPray.App/Tray/TrayIcon.cs' 'class T { void M() { gate.DebugTriggerAthan(p, 20); } }' } }
    @{ N = 'rule 10: debug entry inside #if DEBUG passes'; E = 'OK'; M = 'guard: OK'; S = { param($d) Put $d 'GoPray.App/Tray/TrayIcon.cs' "#if DEBUG`nclass T { void M() { gate.DebugTriggerAthan(p, 20); } }`n#endif" } }
    @{ N = 'rule 10: debug state field outside #if DEBUG'; E = 'FAIL'; M = 'debug entry point'; S = { param($d) Edit-File $d 'GoPray.Core/BlockState.cs' "#if DEBUG`n            if (b.DebugWindowEnd" "#if RELEASE_PROBE`n#endif`n            if (b.DebugWindowEnd" } }
    @{ N = 'rule 10: debug harness outside #if DEBUG'; E = 'FAIL'; M = 'debug entry point'; S = { param($d) Put $d 'GoPray.App/App/Extra.cs' 'class E { void M(string[] a) { Debug.DebugHarness.Run(a); } }' } }
    @{ N = 'rule 11: one flipped byte in the shipped scenes'; E = 'FAIL'; M = 'ui.js differs'; S = { param($d) $p = Join-Path $d 'GoPray.App/Resources/scenes/ui.js'; if (-not (Test-Path $p)) { throw 'selftest setup: build the app first (no synced scenes)' }; $b = [IO.File]::ReadAllBytes($p); $b[[int]($b.Length / 2)] = $b[[int]($b.Length / 2)] -bxor 1; [IO.File]::WriteAllBytes($p, $b) } }
    @{ N = 'rule 11: an unlisted file in the shipped scenes'; E = 'FAIL'; M = 'not in the manifest'; S = { param($d) Put $d 'GoPray.App/Resources/scenes/evil.js' 'fetch(1)' } }
    @{ N = 'rule 12: Core uses WPF'; E = 'FAIL'; M = 'GoPray.Core must not'; S = { param($d) Put $d 'GoPray.Core/Ui.cs' 'using System.Windows.Threading; class U {}' } }
    @{ N = 'rule 12: Core P/Invoke'; E = 'FAIL'; M = 'GoPray.Core must not'; S = { param($d) Put $d 'GoPray.Core/Native.cs' 'class N { [DllImport("user32")] static extern int GetForegroundWindow(); }' } }
    @{ N = 'rule 12: Core project turns on WPF'; E = 'FAIL'; M = 'plain net10.0'; S = { param($d) Edit-File $d 'GoPray.Core/GoPray.Core.csproj' '<TargetFramework>net10.0</TargetFramework>' '<TargetFramework>net10.0-windows</TargetFramework><UseWPF>true</UseWPF>' } }
)

$pass = 0; $failed = 0
try {
    $i = 0
    foreach ($c in $cases) {
        $i++
        $d = Join-Path $tmpRoot ("case{0:00}" -f $i)
        Copy-Src $d
        & $c.S $d
        $extra = @(); if ($c.ContainsKey('X')) { $extra = $c.X }
        $r = Run-Guard $d $extra
        $gotFail = $r.Code -ne 0
        $wantFail = $c.E -eq 'FAIL'
        $ok = ($gotFail -eq $wantFail) -and ($r.Out -match $c.M)
        if ($ok) { $pass++; Write-Output ("PASS  {0}" -f $c.N) }
        else { $failed++; Write-Output ("FAIL  {0}  (exit {1}, want {2}, /{3}/)`n{4}" -f $c.N, $r.Code, $c.E, $c.M, $r.Out.Trim()) }
    }

    if (-not $SkipRelease) {
        $proj = Join-Path $src 'GoPray.Core/GoPray.Core.csproj'
        foreach ($cfg in 'Debug', 'Release') {
            $out = Join-Path $tmpRoot "core-$cfg"
            & $Dotnet build $proj -c $cfg -o $out --nologo -v q 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { $failed++; Write-Output "FAIL  build GoPray.Core -c $cfg"; continue }
            $r = Run-Guard $src @('-Release', $out)
            $wantFail = $cfg -eq 'Debug'
            $ok = (($r.Code -ne 0) -eq $wantFail) -and ($r.Out -match $(if ($wantFail) { "-Release: '.*' found in GoPray.Core.dll" } else { 'guard: OK' }))
            if ($ok) { $pass++; Write-Output ("PASS  -Release on a {0} build {1}" -f $cfg, $(if ($wantFail) { 'fails (negative control)' } else { 'passes' })) }
            else { $failed++; Write-Output ("FAIL  -Release on {0} build`n{1}" -f $cfg, $r.Out.Trim()) }
        }
    }
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $tmpRoot -ErrorAction SilentlyContinue
}

Write-Output ("guard-selftest: {0} passed, {1} failed" -f $pass, $failed)
if ($failed) { exit 1 } else { exit 0 }
