#!/bin/bash
# sync-assets.sh — copy the approved scenes byte-for-byte into the app and rewrite the manifest.
# Owner: lane B. Run by hand after the design scenes change (or after editing shield.html /
# bridge.js / shield.css), then commit the result. The build only CHECKS (check-manifest.sh).
#
#   scripts/sync-assets.sh [DESIGN_SCENES_DIR]
#
# DESIGN_SCENES_DIR defaults to ../design/scenes, then ../../design/scenes (worktree layout).
# The eight approved scene files (everything shield.html loads) and fonts/ are copied unchanged. shield.html, bridge.js and
# shield.css are app-only: they live in Resources/scenes and are hashed in place, never copied.
set -eu

here="$(cd "$(dirname "$0")/.." && pwd)"
dest="$here/GoPray/Resources/scenes"
src="${1:-}"
if [ -z "$src" ]; then
  for c in "$here/../design/scenes" "$here/../../design/scenes"; do
    [ -d "$c" ] && src="$c" && break
  done
fi
[ -d "$src" ] || { echo "sync-assets: no design scenes dir (pass one as the first argument)"; exit 2; }

approved="asr.js dhuhr.js fajr.js isha.js maghrib.js styles.css ui.js watercolor.js"
fonts="CormorantGaramond-VF.woff Amiri-Regular.woff OFL-Amiri.txt OFL-CormorantGaramond.txt"
apponly="shield.html bridge.js shield.css"

mkdir -p "$dest/fonts"
for f in $approved; do cp -p "$src/$f" "$dest/$f"; done
for f in $fonts; do cp -p "$src/fonts/$f" "$dest/fonts/$f"; done
for f in $apponly; do [ -f "$dest/$f" ] || { echo "sync-assets: missing app-only file $dest/$f"; exit 2; }; done
rm -f "$dest/.gitkeep"

# index.html (the preview page, with chips and key handlers) is NOT shipped; shield.html replaces it.
rm -f "$dest/index.html"
out="$dest/MANIFEST.sha256"
{
  echo "# Go Pray scene manifest. Written by scripts/sync-assets.sh, checked by scripts/check-manifest.sh."
  echo "# Format: <sha256>  <path relative to Resources/scenes>. Any file in scenes/ not listed here fails the build."
  echo "# --- approved by Ahmed, copied byte-for-byte from design/scenes (do not edit) ---"
  for f in $approved; do ( cd "$dest" && shasum -a 256 "$f" ); done
  for f in $fonts; do ( cd "$dest" && shasum -a 256 "fonts/$f" ); done
  echo "# --- app-only (edit, then re-run sync-assets.sh) ---"
  for f in $apponly; do ( cd "$dest" && shasum -a 256 "$f" ); done
} > "$out"
echo "sync-assets: copied from $src, wrote $(grep -vc '^#' "$out") hashes to $out"
