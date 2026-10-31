# Go Pray: Athan — Samsung (Tizen) TV app

Launched by the Go Pray Mac app: shows the prayer still, plays one Athan (all 28 voices + Fajr are bundled, no network), exits 30 s after it ends. Back (Return) exits. Plan: `Projects/Go Pray/Samsung TV Plan.md`.

## Build
```
scripts/build-tizen.sh      # -> build/tizen/GoPray.wgt (about 7.9 MB, signed with the gopray profile)
scripts/guard-tizen.sh      # no privileges, no <access>, no URLs, CSP verbatim, every media file present
node tv/tizen/test/params.test.mjs
```
The author-cert password is in the macOS Keychain (`gopray-tizen-author` / `gopray`); the script reads it from there on first run to create the `gopray` Tizen profile. Needs the Tizen CLI at `~/tizen-studio`.

## Install (TV in developer mode, plan §2 step 4)
```
~/tizen-studio/tools/sdb connect <tv-ip>:26101 && ~/tizen-studio/tools/sdb devices
~/tizen-studio/tools/ide/bin/tizen install -n build/tizen/GoPray.wgt -t <serial>
```
App id: `GoPrayAth1.GoPray`.

## Launch
```
curl -s -X POST http://<tv-ip>:8001/api/v2/applications/GoPrayAth1.GoPray      # no params: hour-band prayer + last voice
```
With params (WebSocket `ed.apps.launch`, DEEP_LINK metaTag): `prayer=<fajr|dhuhr|asr|maghrib|isha>&voice=<sunni|shia>.<stem>[&test=1]`.
Every AppControl data value (and `location.search`) is scanned for that query string. A small debug line (raw AppControl data) shows bottom-left only for `test=1` or when no valid prayer arrived.

## Local check in a desktop browser
Serve a staged copy (tv/tizen + images/ + audio/) and open `index.html?prayer=asr&voice=sunni.Minshawi&test=1`.
