#!/bin/bash
# guard-tizen.sh — grep guards for the Samsung (Tizen) TV app (Samsung TV Plan §6, §7). Owner: lane A, PM reviews.
#   scripts/guard-tizen.sh [DIR]     check DIR (default app/tv/tizen; with audio/ images/ present, also checks the files exist)
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
dir="${1:-$here/tv/tizen}"
[ -d "$dir" ] || { echo "guard-tizen: no dir $dir"; exit 2; }
fail=0
bad() { echo "guard-tizen FAIL: $*"; fail=1; }

cfg="$dir/config.xml"
[ -f "$cfg" ] || { bad "no config.xml"; exit 1; }
grep -q '<tizen:privilege' "$cfg" && bad "config.xml has a <tizen:privilege> (the app needs none)"
grep -q '<access' "$cfg" && bad "config.xml has an <access> element (no network)"
grep -q 'background-support="disable"' "$cfg" || bad "config.xml must set background-support=\"disable\""
grep -q 'id="GoPrayAth1.GoPray"' "$cfg" || bad "config.xml app id must be GoPrayAth1.GoPray"

# no URL schemes in the app code
for f in "$dir"/*.js "$dir"/*.html; do
  [ -f "$f" ] || continue
  if grep -qE '(https?|wss?)://' "$f"; then bad "URL string in $(basename "$f"): $(grep -nE '(https?|wss?)://' "$f" | head -2 | tr '\n' ' ')"; fi
done

# no dynamic code / HTML injection in app code
for f in "$dir/app.js" "$dir/logic.js"; do
  [ -f "$f" ] || { bad "missing $(basename "$f")"; continue; }
  grep -nE 'eval\(|new Function|innerHTML|outerHTML|insertAdjacentHTML|document\.write|XMLHttpRequest|fetch\(|WebSocket|sendBeacon' "$f" \
    | sed "s#^#$(basename "$f"):#" | grep . && bad "forbidden call in $(basename "$f")"
done

# CSP meta present verbatim
csp="<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'self'; img-src 'self'; media-src 'self'; script-src 'self'; style-src 'self'\">"
grep -qF "$csp" "$dir/index.html" || bad "index.html CSP meta missing or changed"
grep -qE '<script[^>]*>[^<]+' "$dir/index.html" && bad "inline <script> in index.html"
grep -qE ' style=|<style' "$dir/index.html" && bad "inline style in index.html"

# every media file the code can point at exists (only once the build step has copied them in)
if [ -d "$dir/audio" ] && [ -d "$dir/images" ]; then
  for p in fajr dhuhr asr maghrib isha; do
    [ -f "$dir/images/still-$p.jpg" ] || bad "missing images/still-$p.jpg"
  done
  [ -f "$dir/audio/fajr.mp3" ] || bad "missing audio/fajr.mp3"
  [ -f "$dir/audio/sunni.Adhan-Makkah.mp3" ] || bad "missing audio/sunni.Adhan-Makkah.mp3 (the fallback)"
  node -e '
    const L=require(process.argv[1]); const fs=require("fs"); let n=0;
    for (const g of Object.keys(L.KNOWN_VOICES)) for (const s of L.KNOWN_VOICES[g]) { n++; const f=process.argv[2]+"/audio/"+g+"."+s+".mp3"; if(!fs.existsSync(f)){console.log("guard-tizen FAIL: missing "+f);process.exitCode=1} }
    console.log("guard-tizen: "+n+" voice files checked");
  ' "$dir/logic.js" "$dir" || fail=1
fi

[ "$fail" -eq 0 ] && echo "guard-tizen OK" || echo "guard-tizen: FAILED"
exit "$fail"
