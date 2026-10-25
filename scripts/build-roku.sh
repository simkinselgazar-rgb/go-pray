#!/bin/bash
# Builds build/roku/GoPray-roku.zip (the store package: tv/roku/ only, under 4 MB; Athan voices stream from the
# GitHub release, Fajr + the default voice are bundled in tv/roku/athan-fallback/).
#   --audio-base <url>   DEBUG build: stream voices from <url> (e.g. http://<mac-ip>:8000/) instead of GitHub.
#                        Writes build/roku/GoPray-roku-DEBUG.zip. Never submit that one.
#   --install <roku-ip>  sideload the zip it just built.
# The dev password comes ONLY from the ROKU_DEV_PASSWORD env var; it is never written to a file.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IP=""; BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --install) IP="${2:?--install needs an IP}"; shift 2;;
    --audio-base) BASE="${2:?--audio-base needs a URL}"; shift 2;;
    *) echo "usage: build-roku.sh [--audio-base <url>] [--install <roku-ip>]" >&2; exit 1;;
  esac
done

STAGE="$ROOT/build/roku/stage"
ZIP="$ROOT/build/roku/GoPray-roku.zip"
[ -n "$BASE" ] && ZIP="$ROOT/build/roku/GoPray-roku-DEBUG.zip"
rm -rf "$STAGE" "$ZIP"
mkdir -p "$STAGE"
cp -R "$ROOT/tv/roku/." "$STAGE/"
rm -rf "$STAGE/README.md" "$STAGE/store"
find "$STAGE" -name .DS_Store -delete

# every MP3 stem must be in the channel's voice list
for f in "$ROOT"/GoPray/Resources/athan/{sunni,shia}/*.mp3; do
  s="$(basename "$f" .mp3)"
  grep -q "\"$s\"" "$ROOT/tv/roku/components/AthanScene.brs" || { echo "voice $s missing from AthanScene.brs KnownVoices" >&2; exit 1; }
done
if [ -n "$BASE" ]; then
  sed -i '' "s#return \".*\" ' AUDIO_BASE#return \"$BASE\" ' AUDIO_BASE#" "$STAGE/components/AthanScene.brs"
fi

(cd "$STAGE" && zip -q -r -X "$ZIP" .)
rm -rf "$STAGE"
bytes=$(stat -f %z "$ZIP")
echo "built $ZIP ($bytes bytes)"
if [ -z "$BASE" ] && [ "$bytes" -gt 3670016 ]; then echo "WARNING: over 3.5 MB (limit is 4 MB)" >&2; fi

if [ -n "$IP" ]; then
  : "${ROKU_DEV_PASSWORD:?set ROKU_DEV_PASSWORD in your shell first}"
  curl -sS --digest -u "rokudev:$ROKU_DEV_PASSWORD" \
    -F "mysubmit=Install" -F "archive=@$ZIP" "http://$IP/plugin_install" \
    | grep -oE "Install Success|Identical to previous version|Application Received|Failed[^<]*" | head -3
fi
