#!/bin/bash
# Builds build/tizen/GoPray.wgt: the Samsung (Tizen) TV app. Samsung TV Plan §4.
# Stages tv/tizen/ + the Roku stills + all 29 bundled voices, runs guard-tizen.sh, then `tizen package`.
# The author-cert password lives ONLY in the macOS Keychain (service gopray-tizen-author, account gopray); never printed or written.
#   scripts/build-tizen.sh [--profile <name>]   default profile: gopray (Tizen non-Samsung author cert; created on first run)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="gopray"
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:?--profile needs a name}"; shift 2;;
    *) echo "usage: build-tizen.sh [--profile <name>]" >&2; exit 1;;
  esac
done
TIZEN="$HOME/tizen-studio/tools/ide/bin/tizen"
[ -x "$TIZEN" ] || { echo "Tizen CLI not found at $TIZEN" >&2; exit 1; }

OUT="$ROOT/build/tizen"
STAGE="$OUT/stage"
WGT="$OUT/GoPray.wgt"
rm -rf "$OUT"
mkdir -p "$STAGE/images" "$STAGE/audio"

# the app (not its tests or README)
for f in config.xml index.html app.js logic.js style.css icon.png; do cp "$ROOT/tv/tizen/$f" "$STAGE/$f"; done
# stills: the Roku ones, unchanged
for p in fajr dhuhr asr maghrib isha; do cp "$ROOT/tv/roku/images/still-$p.jpg" "$STAGE/images/"; done
# audio: Fajr (Roku's trimmed copy, plays from 9.0 s) + every voice as <group>.<stem>.mp3
cp "$ROOT/tv/roku/athan-fallback/fajr.mp3" "$STAGE/audio/fajr.mp3"
n=0
for g in sunni shia; do
  for f in "$ROOT"/GoPray/Resources/athan/$g/*.mp3; do
    s="$(basename "$f" .mp3)"
    grep -q "'$s'" "$ROOT/tv/tizen/logic.js" || { echo "voice $g.$s missing from logic.js KNOWN_VOICES" >&2; exit 1; }
    cp "$f" "$STAGE/audio/$g.$s.mp3"; n=$((n+1))
  done
done
find "$STAGE" -name .DS_Store -delete
echo "staged $n voices + fajr"

"$ROOT/scripts/guard-tizen.sh" "$STAGE"

# signing profile: create the author cert + profile once, password from the Keychain
if ! "$TIZEN" security-profiles list 2>/dev/null | grep -qE "^$PROFILE[[:space:]]"; then
  [ "$PROFILE" = "gopray" ] || { echo "profile $PROFILE does not exist" >&2; exit 1; }
  PW="$(security find-generic-password -s gopray-tizen-author -a gopray -w)"
  "$TIZEN" certificate -a GoPray -p "$PW" -f gopray-author >/dev/null
  "$TIZEN" security-profiles add -n gopray -a "$HOME/tizen-studio-data/keystore/author/gopray-author.p12" -p "$PW" >/dev/null
  unset PW
  echo "created signing profile gopray"
fi

"$TIZEN" package -t wgt -s "$PROFILE" -o "$OUT" -- "$STAGE"
# tizen names the file after the widget (Go Pray: Athan -> GoPray.wgt is not guaranteed)
built="$(ls "$OUT"/*.wgt 2>/dev/null | head -1 || true)"
[ -n "$built" ] || { echo "tizen package produced no .wgt" >&2; exit 1; }
[ "$built" = "$WGT" ] || mv "$built" "$WGT"
rm -rf "$STAGE"
echo "built $WGT ($(stat -f %z "$WGT") bytes)"
