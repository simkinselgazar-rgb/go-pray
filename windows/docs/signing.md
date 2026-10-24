# Signing the Windows installer

Go Pray for Windows is signed with **Azure Artifact Signing** (formerly Trusted Signing). It reuses the
account that already signs Krono: `krono-signing`, East US. The signing runs only in GitHub Actions
(`.github/workflows/windows-release.yml`; the source copy lives at `windows/ci/windows-release.yml` on the `windows` branch and the PM moves it to main, because a workflow runs only from `.github/workflows` in the tagged commit). The signing secret never sits on a PC.

## How a release happens

1. Push a tag `win-v<major>.<minor>.<patch>`, for example `git tag win-v0.1.0 && git push origin win-v0.1.0`.
2. The **test** job runs: all xUnit tests, then guard `-Strict` and its self-test.
3. The **release** job waits for Ahmed's approval (GitHub environment `release`). Approve it under
   Actions → the run → "Review deployments".
4. The job runs `scripts/build-installer.ps1 -Sign`:
   - publish (self-contained);
   - guard `-Strict -Release`;
   - sign `GoPray.exe`;
   - Inno Setup;
   - sign the setup.
   Signing uses signtool with the Artifact Signing dlib, SHA256, timestamped at `http://timestamp.acs.microsoft.com`.
5. `signtool verify /pa` runs on `GoPray.exe` and on the setup. Then the SHA256 files are written.
6. A GitHub release named after the tag gets these files:
   - `GoPray-Setup-<version>.exe`, the installer;
   - `GoPray-Setup.exe`, the same file under a stable name for a README button;
   - the `.sha256` file for each.
   The installer is also kept as a workflow artifact.

The workflow runs **only** on `win-v*` tags. It never runs on `pull_request`, because the repo is public and
a fork's code must never get near the secret. It has no `workflow_dispatch` either, because the environment's
policy allows deployments only from `win-v*` tags. The secret goes to the one build-and-sign step only.

## What Ahmed sets (names only)

All of these go on the **`release` environment**: repo Settings → Environments → `release`. The PM already
created that environment, with Ahmed as the required reviewer and deployments limited to tags `win-v*`.

| Kind | Name | Value |
|---|---|---|
| Environment variable | `AZURE_TENANT_ID` | Same tenant as Krono's service principal |
| Environment variable | `AZURE_CLIENT_ID` | Same as Krono's service principal (app) ID |
| Environment variable | `SIGNING_ACCOUNT` | `krono-signing` |
| Environment variable | `SIGNING_ENDPOINT` | `https://eus.codesigning.azure.net/` |
| Environment variable | `SIGNING_PROFILE_NAME` | `krono-public-trust` (PublicTrust) |
| Environment **secret** | `AZURE_CLIENT_SECRET` | Client secret "GoPray-CI-Signing" on the service principal `krono-ci-signing` (expires 2028-10-24). Lives only in GitHub. |

The service principal already has the **Artifact Signing Certificate Profile Signer** role on
`krono-signing` (Krono's docs still call it "Trusted Signing"). Nothing changes in Azure.

The certificate subject is `CN=Ahmed Elgazar, O=Ahmed Elgazar, L=Manassas, ST=va, C=US`. Windows shows "Ahmed Elgazar" as the
publisher (the UAC prompt and the file properties). The verify step fails the job if the signer CN is anything else.

## Tool versions (pinned, from nuget.org)

These are the same tools as the local build (`docs/phase5-prep.md`):
- `Tools.InnoSetup` 6.7.3;
- `Microsoft.Windows.SDK.BuildTools` 10.0.28000.2705 (signtool);
- `Microsoft.ArtifactSigning.Client` 1.0.128 (the dlib).

## Not yet proven

The workflow has not run yet. Its first real run is the first `win-v*` tag. Things to check on that run:
- The App tests need a desktop session and the WebView2 runtime on `windows-latest`. If they fail there for
  that reason alone, the fix is to install the runtime in the test job. Skipping the tests is not the fix.
- The dlib picks up the credential from `AZURE_TENANT_ID`, `AZURE_CLIENT_ID` and `AZURE_CLIENT_SECRET`
  (EnvironmentCredential). If signing fails with an auth error, first check the secret's expiry date in Entra ID.
