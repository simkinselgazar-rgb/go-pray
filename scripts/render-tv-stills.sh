#!/bin/bash
# Needs Google Chrome and python3 with Pillow. Renders the 5 prayer scenes to 1920x1080 for the Roku channel (tv/roku/images/still-<prayer>.jpg (JPEG q85: the Roku package must stay small)).
# Uses headless Chrome on the real scene files (shield.html?layout=art, Reduce Motion = a painted still),
# then adds the prayer name (Latin + Arabic) in the shield's own type, sized for a TV across the room.
# The scenes are copied to a temp dir first, so nothing under GoPray/Resources is touched.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
OUT="$ROOT/tv/roku/images"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
[ -x "$CHROME" ] || { echo "Chrome not found at: $CHROME (set CHROME=...)" >&2; exit 1; }

cp -R "$ROOT/GoPray/Resources/scenes/." "$TMP/"
cat > "$TMP/tv-name.js" <<'JS'
(function () {
  var p = new URLSearchParams(location.search).get('prayer');
  if (new URLSearchParams(location.search).has('noname')) return;
  var N = (window.GoPray && GoPray.NAMES && GoPray.NAMES[p]) || ['Dhuhr', 'الظهر'];
  document.documentElement.style.setProperty('--fs-name', '88px');
  var s = document.getElementById('shield');
  var b = document.createElement('section');
  b.className = 'block';
  b.style.width = '40vw';
  b.classList.add('is-in');
  b.innerHTML = '<h1 class="name"><span class="name-latin"></span><span class="name-ar"></span></h1><div class="rule"></div>';
  b.querySelector('.name-latin').textContent = N[0];
  b.querySelector('.name-ar').textContent = N[1];
  s.appendChild(b);
})();
JS
sed -i '' 's#</body>#<script src="tv-name.js"></script></body>#' "$TMP/shield.html"

for p in fajr dhuhr asr maghrib isha; do
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --window-size=1920,1080 \
    --force-device-scale-factor=1 --virtual-time-budget=8000 \
    --screenshot="$TMP/still-$p.png" \
    "file://$TMP/shield.html?prayer=$p&layout=art&reduce=1" >/dev/null 2>&1
  python3 -c 'import sys; from PIL import Image; Image.open(sys.argv[1]).convert("RGB").save(sys.argv[2], quality=85, optimize=True)' "$TMP/still-$p.png" "$OUT/still-$p.jpg"
  echo "rendered $OUT/still-$p.jpg"
done
# the welcome screen's background: the Fajr scene without the name
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --window-size=1920,1080 \
  --force-device-scale-factor=1 --virtual-time-budget=8000 --screenshot="$TMP/welcome-bg.png" \
  "file://$TMP/shield.html?prayer=fajr&layout=art&reduce=1&noname=1" >/dev/null 2>&1
python3 -c 'import sys; from PIL import Image; Image.open(sys.argv[1]).convert("RGB").save(sys.argv[2], quality=80, optimize=True)' "$TMP/welcome-bg.png" "$OUT/welcome-bg.jpg"
sips -g pixelWidth -g pixelHeight "$OUT"/still-*.jpg | grep -E "pixel|still"
