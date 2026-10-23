<#
sync-assets.ps1 — copy the scenes byte for byte from the Mac tree into the Windows app (PLAN.md §4).
The Mac tree (GoPray/Resources/scenes, with its MANIFEST.sha256) is the single source of truth; the
Windows tree never holds a second copy in git (Resources/scenes is in .gitignore). Runs before every
build; check-manifest.ps1 then verifies the copy.

Bytes come from git, not from the working tree: Git for Windows (core.autocrlf=true) checks text files
out with CRLF, which would make every .js/.css/.html differ from the approved LF bytes. So for a source
inside a git work tree each tracked file is read with `git cat-file blob HEAD:<path>` (the committed,
approved bytes). A source outside git (tests, the negative control) is copied as is.

  scripts\sync-assets.ps1 [-Source <scenes dir>] [-Dest <dir>]
#>
param([string]$Source = '', [string]$Dest = '', [switch]$NoManifest, [switch]$Incremental)
# -NoManifest: for audio and fonts (no MANIFEST.sha256; they are byte-copied from git all the same).
# -Incremental: do not wipe the destination; rewrite a file only when its bytes differ (the 29 MP3s).
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Source) { $Source = Join-Path $here '..\..\GoPray\Resources\scenes' }
if (-not $Dest) { $Dest = Join-Path $here '..\src\GoPray.App\Resources\scenes' }
if (-not $NoManifest -and -not (Test-Path -LiteralPath (Join-Path $Source 'MANIFEST.sha256'))) { Write-Output "sync-assets FAIL: no MANIFEST.sha256 in $Source"; exit 1 }
$Source = (Resolve-Path -LiteralPath $Source).Path

function Git([string[]]$a) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo 'git'
    $psi.Arguments = ($a | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $Source
    $p = [System.Diagnostics.Process]::Start($psi)
    $ms = New-Object System.IO.MemoryStream
    $p.StandardOutput.BaseStream.CopyTo($ms)
    $p.WaitForExit()
    return @{ Code = $p.ExitCode; Bytes = $ms.ToArray() }
}

$top = $null
try { $r = Git @('rev-parse', '--show-prefix'); if ($r.Code -eq 0) { $top = [Text.Encoding]::UTF8.GetString($r.Bytes).Trim() } } catch { $top = $null }

if ((Test-Path -LiteralPath $Dest) -and -not $Incremental) { Remove-Item -LiteralPath $Dest -Recurse -Force }
New-Item -ItemType Directory -Force $Dest | Out-Null
$n = 0; $fromGit = 0
Get-ChildItem -LiteralPath $Source -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($Source.Length).TrimStart('\', '/').Replace('\', '/')
    $to = Join-Path $Dest $rel
    New-Item -ItemType Directory -Force (Split-Path -Parent $to) | Out-Null
    $done = $false
    if ($null -ne $top) {
        $b = Git @('cat-file', 'blob', "HEAD:$top$rel")
        if ($b.Code -eq 0) {
            $same = $Incremental -and (Test-Path -LiteralPath $to) -and ((Get-Item -LiteralPath $to).Length -eq $b.Bytes.Length) -and ([Convert]::ToBase64String([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($to))) -eq [Convert]::ToBase64String([Security.Cryptography.SHA256]::Create().ComputeHash($b.Bytes)))
            if (-not $same) { [IO.File]::WriteAllBytes($to, $b.Bytes) }
            $done = $true; $fromGit++
        }
    }
    if (-not $done) { Copy-Item -LiteralPath $_.FullName -Destination $to }
    $n++
}
Write-Output "sync-assets: copied $n files ($fromGit from git HEAD) from $Source"
