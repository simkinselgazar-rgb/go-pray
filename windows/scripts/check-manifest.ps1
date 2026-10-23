<#
check-manifest.ps1 — fails if any file in the scenes folder differs from MANIFEST.sha256, is missing,
or is not listed (translation of scripts/check-manifest.sh; guard rule 11). Run by the build.

  scripts\check-manifest.ps1 [-Dir <scenes dir>]
#>
param([string]$Dir = '')
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Dir) { $Dir = Join-Path $here '..\src\GoPray.App\Resources\scenes' }
$man = Join-Path $Dir 'MANIFEST.sha256'
if (-not (Test-Path -LiteralPath $man)) { Write-Output "check-manifest FAIL: no $man (run scripts\sync-assets.ps1)"; exit 1 }
$Dir = (Resolve-Path -LiteralPath $Dir).Path
$fail = $false
$listed = New-Object System.Collections.Generic.HashSet[string]
$sha = [System.Security.Cryptography.SHA256]::Create()
foreach ($line in [IO.File]::ReadAllLines($man)) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    $parts = $t -split '\s+', 2
    $hash = $parts[0].ToLowerInvariant(); $path = $parts[1].Trim()
    [void]$listed.Add($path)
    $full = Join-Path $Dir $path
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { Write-Output "check-manifest FAIL: missing $path"; $fail = $true; continue }
    $got = -join ($sha.ComputeHash([IO.File]::ReadAllBytes($full)) | ForEach-Object { $_.ToString('x2') })
    if ($got -ne $hash) { Write-Output "check-manifest FAIL: $path differs from the manifest"; $fail = $true }
}
$extra = @(Get-ChildItem -LiteralPath $Dir -Recurse -File | ForEach-Object { $_.FullName.Substring($Dir.Length).TrimStart('\', '/').Replace('\', '/') } |
    Where-Object { $_ -ne 'MANIFEST.sha256' -and $_ -ne '.gitkeep' -and $_ -ne '.DS_Store' -and -not $listed.Contains($_) } | Sort-Object)
if ($extra.Count) { Write-Output "check-manifest FAIL: not in the manifest:"; $extra | ForEach-Object { Write-Output "  $_" }; $fail = $true }
if ($fail) { exit 1 }
Write-Output "check-manifest: OK ($($listed.Count) files)"
exit 0
