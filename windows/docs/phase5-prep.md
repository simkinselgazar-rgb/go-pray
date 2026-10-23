# Phase 5 prep: unsigned installer + signing readiness (2026-10-23)

## Installer (unsigned)

`scripts\build-installer.ps1` runs: self-contained publish (Release, win-x64) → delete every `.pdb` →
`guard.ps1 -Strict -Release` → (sign `GoPray.exe`, off) → Inno Setup (`installer\GoPray.iss`) → (sign setup, off) → SHA256.

| | |
|---|---|
| Installer | `out\GoPray-Setup-0.1.0.exe`, **62.8 MB** (LZMA2/ultra64, solid); installed size 213 MB |
| Install | per user, `PrivilegesRequired=lowest`: `%LOCALAPPDATA%\Programs\Go Pray`, **no UAC**; Start menu shortcut; desktop shortcut optional (unchecked); "Launch Go Pray" at the end; licences in `{app}\licenses` (repo LICENSE + `audio/LICENSES.md`); no `.pdb` |
| Task | the installer never creates it; the app does when Setup finishes with "Launch at login" on |
| Uninstall | `[UninstallRun] GoPray.exe --uninstall-task`: removes the task, broadcasts `GoPray.Quit` (the running copy quits **only between prayers**), waits ≤ 10 s; then files go. `%LOCALAPPDATA%\GoPray` is removed only if the person says yes (default No; a silent uninstall never asks and keeps it). During a block the running exe stays, so uninstalling is never a quicker way out than the block |

**Live test on Ahmed's PC** (outside my sandboxed shell, like a real run): clean before → `GoPray-Setup-0.1.0.exe /SILENT` exit 0 in 8 s, no UAC → opened from the
Start menu shortcut through Explorer → "Set up Go Pray" showed, log `launch ByHand mutex=True → Wire`, no task yet → `unins000.exe /SILENT` while it ran:
`--uninstall-task` exit 0, the app logged "quit: asked by the uninstaller", files, shortcut and uninstall entry removed, no task, no process →
data folder kept (silent) and then removed by hand. **Not exercised live:** the "Also remove your Go Pray settings and data?" Yes path (needs a click;
it is three lines of `[Code]`, `DelTree` of exactly `{localappdata}\GoPray`).

## Tools (no admin, nothing installed system-wide)

| Tool | Where | Version / signer |
|---|---|---|
| Inno Setup compiler | NuGet `Tools.InnoSetup` 6.7.3 → `%USERPROFILE%\dev\tools\tools.innosetup.6.7.3\tools\ISCC.exe` | "Inno Setup 6", Authenticode valid, signed by Pyrsys B.V. |
| signtool | NuGet `Microsoft.Windows.SDK.BuildTools` → `…\bin\10.0.28000.0\x64\signtool.exe` | **10.0.28000.2705** (≥ 10.0.22621.755 that Artifact Signing needs), signed by Microsoft |
| Artifact Signing dlib | already on the PC: `%USERPROFILE%\.trusted-signing-cli\lib\bin\x64\Azure.CodeSigning.Dlib.dll` (package `Microsoft.ArtifactSigning.Client` 1.0.128, from 2026-10-15) | needs the .NET 8 runtime, which is installed |

## Which Azure signing exists? (read-only)

- `az` (Azure CLI) is installed but **not logged in** ("Please run 'az login'"), so no account or resource could be listed.
- `%USERPROFILE%\.trusted-signing-cli\metadata.json` exists with **placeholder** values only: Endpoint `https://eus.codesigning.azure.net/`
  (East US), `CodeSigningAccountName = x`, `CertificateProfileName = y`. Something (probably a Tauri signing setup) installed the client but no real account is configured.
- Morrow on this PC: only QA hand-off folders on the Desktop; no build script there (or in `dev`, `Documents`, `source`, `repos`) mentions signtool, AzureSignTool, the dlib or a code-signing account.
- Conclusion: **unknown until Ahmed logs in**. Nothing secret was read or printed.

## What Ahmed does for signing (plain steps)

1. On https://portal.azure.com search **"Artifact Signing accounts"** (older name "Trusted Signing").
   - **One exists:** open it and note three things: the **account name**, its **region** (e.g. East US), and under *Certificate profiles* the **profile name** (type must be *Public Trust*).
   - **None exists:** create one (Basic SKU) in a supported region, then *Identity validation*: as an individual, that needs a US or Canada billing account of type *Individual* plus a government ID; as an organisation, the legal business details (can take 1–20 business days). Then create a *Public Trust* certificate profile.
2. On that account: **Access control (IAM) → Add role assignment → "Artifact Signing Certificate Profile Signer"** (older name "Trusted Signing Certificate Profile Signer") → your own user.
3. On this PC, type `! az login` in the Claude prompt and sign in in the browser that opens (the signing tool uses this login; no key or password goes into any file).
4. Send me (or the PM) the three names from step 1. I write them into a `metadata.json` **outside the repo** and run
   `scripts\build-installer.ps1 -Sign -Metadata <that file>`: it signs `GoPray.exe` and the installer with a timestamp (`http://timestamp.acs.microsoft.com`; the certificates live only 3 days, so the timestamp is what keeps a signature valid), then checks both with `signtool verify /pa`.
   - If it's a **Key Vault certificate** instead: send the vault URL and certificate name, and give your user *Key Vault Certificate User* + *Key Vault Crypto User*; I then sign with `AzureSignTool`.
5. Expect Windows SmartScreen to still say "Windows protected your PC" for the first downloads; reputation builds with downloads (README line, PLAN §5).
