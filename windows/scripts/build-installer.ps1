<#
build-installer.ps1 — publish → guard -Release → (sign exe) → Inno → (sign setup) → SHA256 (PLAN.md §7 Phase 5).
Signing is OFF until Ahmed's Artifact Signing account exists; pass -Sign -Metadata <metadata.json> then.

  scripts\build-installer.ps1 [-Version 0.1.0] [-Dotnet <dotnet.exe>] [-Iscc <ISCC.exe>] [-Sign -Signtool <signtool.exe> -Dlib <Azure.CodeSigning.Dlib.dll> -Metadata <metadata.json>]
#>
param(
    [string]$Version = '0.3.0',
    [string]$Dotnet = 'dotnet',
    [string]$Iscc = (Join-Path $env:USERPROFILE 'dev\tools\tools.innosetup.6.7.3\tools\ISCC.exe'),
    [switch]$Sign,
    [string]$Signtool = (Join-Path $env:USERPROFILE 'dev\tools\microsoft.windows.sdk.buildtools.10.0.28000.2705\bin\10.0.28000.0\x64\signtool.exe'),
    [string]$Dlib = (Join-Path $env:USERPROFILE '.trusted-signing-cli\lib\bin\x64\Azure.CodeSigning.Dlib.dll'),
    [string]$Metadata = ''
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$out = Join-Path $root 'out'
$pub = Join-Path $out 'publish'
if (Test-Path $pub) { Remove-Item -Recurse -Force $pub }
New-Item -ItemType Directory -Force $out | Out-Null

function SignFile([string]$f) {
    if (-not $Sign) { return }
    if (-not (Test-Path $Metadata)) { throw "-Sign needs -Metadata (Endpoint, CodeSigningAccountName, CertificateProfileName)" }
    # Artifact Signing certificates live 3 days: the timestamp is what keeps the signature valid.
    & $Signtool sign /v /fd SHA256 /tr http://timestamp.acs.microsoft.com /td SHA256 /dlib $Dlib /dmdf $Metadata $f
    if ($LASTEXITCODE -ne 0) { throw "signtool failed on $f" }
    & $Signtool verify /pa /v $f | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "signtool verify failed on $f" }
}

Write-Output "1/5 publish (self-contained, win-x64, Release)"
& $Dotnet publish (Join-Path $root 'src\GoPray.App\GoPray.App.csproj') -c Release -r win-x64 --self-contained -p:Version=$Version -o $pub --nologo -v q
if ($LASTEXITCODE -ne 0) { throw 'publish failed' }
Get-ChildItem $pub -Recurse -Filter *.pdb | Remove-Item -Force          # never ship symbols

Write-Output "2/5 guard -Release"
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'guard.ps1') -Strict -Release $pub
if ($LASTEXITCODE -ne 0) { throw 'guard failed' }

Write-Output "3/5 sign GoPray.exe$(if (-not $Sign) { ' (skipped: unsigned build)' })"
SignFile (Join-Path $pub 'GoPray.exe')

Write-Output "4/5 Inno Setup"
& $Iscc /Q "/DAppVersion=$Version" "/DPublishDir=$pub" "/DOutDir=$out" (Join-Path $root 'installer\GoPray.iss')
if ($LASTEXITCODE -ne 0) { throw 'ISCC failed' }
$setup = Join-Path $out "GoPray-Setup-$Version.exe"
SignFile $setup

Write-Output "5/5 SHA256"
$hash = (Get-FileHash $setup -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  GoPray-Setup-$Version.exe" | Set-Content -Encoding ascii (Join-Path $out "GoPray-Setup-$Version.exe.sha256")
$pubMb = (Get-ChildItem $pub -Recurse -File | Measure-Object Length -Sum).Sum / 1MB
Write-Output ("installer: {0} ({1:0.0} MB; installed {2:0} MB); sha256 {3}; signed={4}" -f $setup, ((Get-Item $setup).Length / 1MB), $pubMb, $hash, [bool]$Sign)
