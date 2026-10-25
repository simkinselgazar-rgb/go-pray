<#
test-installer-upgrade.ps1 — proves the 0.2.1 installer's PrepareToInstall (GoPray.iss) on this PC without touching the
real Go Pray: a test build of the installer (/DTestRun, its own AppId, mutex, quit message and task name, no shortcuts,
no uninstall entry) runs silently over a stand-in "running copy": a hidden window that holds the test mutex and, like
the app, quits on the quit broadcast only "between prayers".

  A. upgrade over a running copy: the copy quits, the files are installed, exit 0, the test task is paused during the
     copy and enabled again after.
  B. a prayer block (the copy refuses to quit): Setup stops with the block line, exit 7, nothing installed, task enabled.

The test task is created and removed here (proved with schtasks /query). Needs a publish folder (build-installer.ps1).

  scripts\test-installer-upgrade.ps1 [-Publish <dir>] [-Iscc <ISCC.exe>]
#>
param(
    [string]$Publish = (Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'out\publish'),
    [string]$Iscc = (Join-Path $env:USERPROFILE 'dev\tools\tools.innosetup.6.7.3\tools\ISCC.exe')
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$id = [guid]::NewGuid().ToString('N').Substring(0, 8)
$tmp = Join-Path ([IO.Path]::GetTempPath()) "gopray-installer-test-$id"
$mutex = "Local\GoPray.InstallerTest.$id"
$quit = "GoPray.InstallerTest.Quit.$id"
$task = "GoPrayInstallerTest-$id"
New-Item -ItemType Directory -Force $tmp | Out-Null
if (-not (Test-Path (Join-Path $Publish 'GoPray.exe'))) { throw "no publish folder at $Publish (run build-installer.ps1 first)" }

$results = New-Object System.Collections.Generic.List[string]
$failed = 0
function Check([bool]$ok, [string]$what) { if ($ok) { $results.Add("PASS  $what") } else { $results.Add("FAIL  $what"); $script:failed++ } }

# The stand-in running copy: holds the mutex; on the quit broadcast it exits unless told to refuse (a block). It always
# exits by itself after 25 s, so nothing is left behind even if a step fails.
$holderSrc = @"
using System; using System.Threading; using System.Windows.Forms; using System.Runtime.InteropServices;
public static class Holder {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterWindowMessage(string s);
  sealed class W : NativeWindow {
    readonly uint _quit; readonly bool _refuse;
    public W(uint q, bool r) { _quit = q; _refuse = r; CreateHandle(new CreateParams { Caption = "GoPrayInstallerTestHolder" }); }
    protected override void WndProc(ref Message m) { if ((uint)m.Msg == _quit && !_refuse) Application.ExitThread(); base.WndProc(ref m); }
  }
  public static void Run(string mutex, string quit, bool refuse) {
    using (var mx = new Mutex(true, mutex)) {
      var w = new W(RegisterWindowMessage(quit), refuse);
      var t = new System.Windows.Forms.Timer { Interval = 25000 }; t.Tick += (s, e) => Application.ExitThread(); t.Start();
      Application.Run();
      w.DestroyHandle();
    }
  }
}
"@
$holderScript = Join-Path $tmp 'holder.ps1'
@"
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
$holderSrc
'@
[Holder]::Run('$mutex', '$quit', `$args[0] -eq 'refuse')
"@ | Set-Content -Encoding utf8 $holderScript

function Start-Holder([bool]$refuse) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $holderScript)
    if ($refuse) { $a += 'refuse' }
    $p = Start-Process powershell -ArgumentList $a -WindowStyle Hidden -PassThru
    for ($i = 0; $i -lt 60; $i++) {                         # wait until it holds the mutex
        $m = $null
        if ([Threading.Mutex]::TryOpenExisting($mutex, [ref]$m)) { $m.Dispose(); return $p }
        Start-Sleep -Milliseconds 250
    }
    throw 'holder did not start'
}

function TaskState { (schtasks /query /tn $task /fo csv /nh 2>$null | ConvertFrom-Csv -Header Name, Next, Status).Status }

try {
    # The test installer.
    $appId = '{{' + [guid]::NewGuid().ToString().ToUpperInvariant() + '}'
    & $Iscc /Q "/DTestRun" "/DAppIdValue=$appId" "/DMutexName=$mutex" "/DQuitMessage=$quit" "/DTaskName=$task" `
        "/DAppVersion=0.3.1" "/DPublishDir=$Publish" "/DOutDir=$tmp" (Join-Path $root 'installer\GoPray.iss')
    if ($LASTEXITCODE -ne 0) { throw 'ISCC failed' }
    $setup = Join-Path $tmp 'GoPray-Setup-0.3.1.exe'
    schtasks /create /tn $task /tr "cmd /c exit" /sc once /st 23:59 /f | Out-Null

    # A. upgrade over a running copy
    $h = Start-Holder $false
    $dirA = Join-Path $tmp 'appA'; $logA = Join-Path $tmp 'a.log'
    $p = Start-Process $setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=$dirA", "/LOG=$logA" -PassThru -Wait
    $la = Get-Content $logA -Raw
    Check ($p.ExitCode -eq 0) "A: Setup exit 0 (got $($p.ExitCode))"
    Check ($h.HasExited) 'A: the running copy quit on the broadcast'
    Check ($la -match 'the running copy quit') 'A: log says the running copy quit'
    Check (Test-Path (Join-Path $dirA 'GoPray.exe')) 'A: GoPray.exe installed'
    Check ($la -match '/DISABLE: exit 0') 'A: the task was paused before the copy'
    Check ($la -match '/ENABLE: exit 0') 'A: the task was resumed after the copy'
    Check ((TaskState) -ne 'Disabled') "A: task enabled at the end ($(TaskState))"

    # B. a prayer block: the copy refuses to quit
    $h = Start-Holder $true
    $dirB = Join-Path $tmp 'appB'; $logB = Join-Path $tmp 'b.log'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process $setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=$dirB", "/LOG=$logB" -PassThru -Wait
    $lb = Get-Content $logB -Raw
    Check ($p.ExitCode -eq 7) "B: Setup stopped, exit 7 = PrepareToInstall failed (got $($p.ExitCode))"
    Check ($lb -match [regex]::Escape('Go Pray is in a prayer block. Run Setup again after the block ends.')) 'B: the block line is shown'
    Check (-not $h.HasExited) 'B: the copy was left running (no kill)'
    Check (-not (Test-Path (Join-Path $dirB 'GoPray.exe'))) 'B: nothing installed'
    Check ($sw.Elapsed.TotalSeconds -lt 20) "B: gave up after the 10 s wait ($([int]$sw.Elapsed.TotalSeconds) s)"
    Check ((TaskState) -ne 'Disabled') "B: task enabled again ($(TaskState))"
    $h.WaitForExit(30000) | Out-Null                           # its own 25 s timer ends it
}
finally {
    schtasks /delete /tn $task /f 2>$null | Out-Null
    $left = @(schtasks /query /fo csv 2>$null | Select-String -SimpleMatch $task).Count
    $results.Add("cleanup: test tasks matching '$task' = $left")
    if ($left) { $failed++ }
    Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
}
$results | ForEach-Object { Write-Output $_ }
Write-Output ("test-installer-upgrade: {0} failed" -f $failed)
if ($failed) { exit 1 } else { exit 0 }
