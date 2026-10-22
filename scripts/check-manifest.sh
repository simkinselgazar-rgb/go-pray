#!/bin/bash
# check-manifest.sh — build phase. Fails if any file in Resources/scenes differs from
# MANIFEST.sha256, is missing, or is not listed. Owner: lane B.
#
#   scripts/check-manifest.sh [SCENES_DIR]     (SCENES_DIR is for the negative control)
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
dir="${1:-$here/GoPray/Resources/scenes}"
man="$dir/MANIFEST.sha256"
[ -f "$man" ] || { echo "check-manifest FAIL: no $man (run scripts/sync-assets.sh)"; exit 1; }

fail=0
listed="$(mktemp -t gopray-listed)"; present="$(mktemp -t gopray-present)"
trap 'rm -f "$listed" "$present"' EXIT

while read -r hash path; do
  case "$hash" in ''|\#*) continue ;; esac
  echo "$path" >> "$listed"
  if [ ! -f "$dir/$path" ]; then echo "check-manifest FAIL: missing $path"; fail=1; continue; fi
  got="$(shasum -a 256 "$dir/$path" | cut -d' ' -f1)"
  [ "$got" = "$hash" ] || { echo "check-manifest FAIL: $path differs from the manifest"; fail=1; }
done < "$man"

( cd "$dir" && find . -type f ! -name MANIFEST.sha256 ! -name .gitkeep ! -name .DS_Store | sed 's|^\./||' | sort ) > "$present"
sort -o "$listed" "$listed"
extra="$(comm -13 "$listed" "$present")"
[ -z "$extra" ] || { echo "check-manifest FAIL: not in the manifest:"; echo "$extra" | sed 's/^/  /'; fail=1; }

[ "$fail" -eq 0 ] && echo "check-manifest: OK ($(wc -l < "$listed" | tr -d ' ') files)"
exit "$fail"
