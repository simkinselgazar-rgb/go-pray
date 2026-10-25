#!/bin/bash
# Copies the 28 streamed voices into build/tv-audio/ with flat names (<sunni|shia>.<stem>.mp3), ready to upload
# as assets of the GitHub release tv-audio-v1. Fajr and sunni.Adhan-Makkah are bundled in the channel, but
# Makkah is staged too so the release is complete (29 files). Uploads nothing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/tv-audio"
rm -rf "$OUT"; mkdir -p "$OUT"
for g in sunni shia; do
  for f in "$ROOT/GoPray/Resources/athan/$g"/*.mp3; do
    cp "$f" "$OUT/$g.$(basename "$f")"
  done
done
n=$(ls "$OUT" | wc -l | tr -d ' ')
echo "staged $n files ($(du -sh "$OUT" | cut -f1)) in $OUT"
