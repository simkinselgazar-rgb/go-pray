# Go Pray: Athan & Adhan — Roku channel

Opened with a prayer (from the Go Pray app): shows the prayer still, plays one Athan, exits to Home 30 s after it ends.
Opened by hand (no valid `prayer`): a welcome screen with the app link and a QR code; stays until Back. Back exits any time.

## Build
```
scripts/render-tv-stills.sh     # only if the scenes change (Chrome + python3 Pillow)
scripts/build-roku.sh           # -> build/roku/GoPray-roku.zip (about 2.8 MB; the store limit is reported as 4 MB)
scripts/stage-tv-audio.sh       # -> build/tv-audio/ : the voice files, flat names, to upload to the release
```
Audio: Fajr (from 9.0 s) and the default `sunni.Adhan-Makkah` are bundled in `tv/roku/athan-fallback/` (Fajr is 64 kbps mono, made with `ffmpeg -ac 1 -ar 32000 -b:a 64k`). Every other voice streams from
`https://github.com/simkinselgazar-rgb/go-pray/releases/download/tv-audio-v1/<sunni|shia>.<stem>.mp3`.
If a stream fails (offline, 404, error, nothing in 8 s) the bundled default plays.

## Sideload (dev mode on the Roku)
```
export ROKU_DEV_PASSWORD=...    # your shell only, never a file
scripts/build-roku.sh --install <roku-ip>
```
Test streaming from this Mac (DEBUG build, never submit it):
```
scripts/stage-tv-audio.sh && (cd build/tv-audio && python3 -m http.server 8000)
scripts/build-roku.sh --audio-base http://<mac-ip>:8000/ --install <roku-ip>
```

## Launch
```
curl -d '' "http://<roku-ip>:8060/launch/dev?prayer=asr&voice=sunni.Minshawi"
```
- `prayer`: `fajr` `dhuhr` `asr` `maghrib` `isha`. Missing or unknown: the welcome screen.
- `voice`: `sunni.<stem>` or `shia.<stem>` (a file name in `GoPray/Resources/athan/`). Unknown or missing: `sunni.Adhan-Makkah`.
- Fajr ignores `voice`.
- Already open? The new launch restarts with the new params.
- Stop: `curl -d '' http://<roku-ip>:8060/keypress/Back`
- A store build launches by channel id instead of `dev`.

Store listing text and images: `store/`.
