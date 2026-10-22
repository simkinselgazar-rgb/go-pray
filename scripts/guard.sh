#!/bin/bash
# guard.sh — grep guards for Go Pray (Architecture Plan §C.7 + §G). Owner: PM.
# Runs as an Xcode build phase and before every merge. Any failure fails the build.
#
#   scripts/guard.sh                 check GoPray/ (pre-ship rules)
#   scripts/guard.sh --strict        also require the ship-time "exactly one" hits
#   scripts/guard.sh --release APP   also check a Release .app has no debug strings
#   scripts/guard.sh [...] DIR       check DIR instead of GoPray/ (negative controls)
#
# Line comments (// …) are stripped before matching, so docs may name the symbols.
set -u

here="$(cd "$(dirname "$0")/.." && pwd)"
src="$here/GoPray"
strict=0
release_app=""
while [ $# -gt 0 ]; do
  case "$1" in
    --strict) strict=1 ;;
    --release) shift; release_app="${1:-}" ;;
    *) src="$1" ;;
  esac
  shift
done
[ -d "$src" ] || { echo "guard: no source dir $src"; exit 2; }

fail=0
bad() { echo "guard FAIL: $*"; fail=1; }

# file:line:code, comments stripped, paths relative to $src.
code="$(mktemp -t gopray-guard)"
trap 'rm -f "$code"' EXIT
( cd "$src" && find . -name '*.swift' -print0 | sort -z | xargs -0 awk '
    { line=$0; sub(/\/\/.*$/, "", line); f=FILENAME; sub(/^\.\//, "", f); print f ":" FNR ":" line }
' ) > "$code"

hits()  { grep -E -- "$1" "$code" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*$' || true; }
count() { hits "$1" | grep -c . || true; }
files() { hits "$1" | cut -d: -f1 | sort -u; }

# Every hit of $1 must be in file $2.
only_in() {
  local pat="$1" allowed="$2" f
  for f in $(files "$pat"); do
    [ "$f" = "$allowed" ] || bad "'$pat' outside $allowed: $(hits "$pat" | grep "^$f:" | head -3 | tr '\n' ' ')"
  done
}

# 1. endBlock( : exactly 2 (private declaration + one call), both in BlockGate, the call inside requestConfirm.
n=$(count 'endBlock\(')
[ "$n" -eq 2 ] || bad "endBlock( appears $n times (want 2: declaration + the call in requestConfirm)"
only_in 'endBlock\(' 'Core/BlockGate.swift'
hits 'func endBlock\(' | grep -qE 'private func endBlock\(' || bad "endBlock must be declared private"
callers=$(awk -F: '
  { rest=$0; sub(/^[^:]+:[0-9]+:/, "", rest) }
  match(rest, /func [A-Za-z_][A-Za-z0-9_]*/) { fn=substr(rest, RSTART+5, RLENGTH-5) }
  rest ~ /endBlock\(/ && rest !~ /func endBlock\(/ { print fn }
' <(grep '^Core/BlockGate.swift:' "$code") | sort -u)
[ "$callers" = "requestConfirm" ] || bad "endBlock( called from '${callers:-nothing}', want only requestConfirm"

# 2. failOpen( : only in BlockGate, declared private.
only_in 'failOpen\(' 'Core/BlockGate.swift'
if [ "$(count 'failOpen\(')" -gt 0 ]; then
  hits 'func failOpen\(' | grep -qE 'private func failOpen\(' || bad "failOpen must be declared private"
fi

# 3. Never kill anything.
for p in 'forceTerminate' '\.terminate\(\)' '(^|[^A-Za-z0-9_])kill\(' 'SIGKILL'; do
  n=$(count "$p"); [ "$n" -eq 0 ] || bad "'$p' must not appear ($n hits): $(hits "$p" | head -3 | tr '\n' ' ')"
done

# 4. Network: only the geocoder file.
only_in 'URLSession' 'Prayer/Geocoder.swift'
only_in 'CLGeocoder' 'Prayer/Geocoder.swift'

# 5. JS bridge: only the scene web view.
only_in 'evaluateJavaScript' 'Shield/SceneWebView.swift'
only_in 'WKUserContentController' 'Shield/SceneWebView.swift'
# 5b. Every web view is built and loaded in the one locked-down file (a raw one elsewhere skips the lockdown).
only_in 'WKWebView\(' 'Shield/SceneWebView.swift'
only_in 'WKWebViewConfiguration' 'Shield/SceneWebView.swift'
only_in 'loadFileURL|loadHTMLString|load\(URLRequest' 'Shield/SceneWebView.swift'

# 6. allowingReadAccessTo: one hit (ship), in SceneWebView, pointing at the scenes directory.
n=$(count 'allowingReadAccessTo')
only_in 'allowingReadAccessTo' 'Shield/SceneWebView.swift'
[ "$n" -le 1 ] || bad "allowingReadAccessTo appears $n times (want exactly 1)"
[ "$strict" -eq 0 ] || [ "$n" -eq 1 ] || bad "--strict: allowingReadAccessTo appears $n times (want exactly 1)"
if [ "$n" -eq 1 ]; then
  hits 'allowingReadAccessTo' | grep -qi 'scenes' || bad "allowingReadAccessTo must point at the scenes directory"
fi

# 7. isInspectable = true only inside #if DEBUG.
leaks=$(awk -F: '
  { f=$1; rest=$0; sub(/^[^:]+:[0-9]+:/, "", rest) }
  f != last { depth=0; dbg=0; last=f }
  rest ~ /^[[:space:]]*#if/ { depth++; if (rest ~ /#if[[:space:]]+DEBUG/) dbgat[depth]=1; else dbgat[depth]=0 }
  rest ~ /^[[:space:]]*#else/ { if (dbgat[depth]==1) dbgat[depth]=0 }
  rest ~ /^[[:space:]]*#endif/ { dbgat[depth]=0; depth-- }
  rest ~ /isInspectable[[:space:]]*=[[:space:]]*true/ {
    inside=0; for (i=1;i<=depth;i++) if (dbgat[i]==1) inside=1
    if (!inside) print $1 ":" $2
  }
' "$code")
[ -z "$leaks" ] || bad "isInspectable = true outside #if DEBUG: $leaks"

# 8. No Accessibility, input injection, screen capture, key logging, session blocking.
for p in 'CGEvent' 'AXUIElement' 'CGWindowListCreateImage' 'addGlobalMonitorForEvents' 'disableSessionTermination'; do
  n=$(count "$p"); [ "$n" -eq 0 ] || bad "'$p' must not appear ($n hits): $(hits "$p" | head -3 | tr '\n' ' ')"
done

# 9. Debug-only entry points stay behind #if DEBUG (DebugMenu.swift is wrapped whole).
dbg_leaks=$(awk -F: '
  { f=$1; rest=$0; sub(/^[^:]+:[0-9]+:/, "", rest) }
  f != last { depth=0; last=f }
  rest ~ /^[[:space:]]*#if/ { depth++; dbgat[depth]=(rest ~ /#if[[:space:]]+DEBUG/) ? 1 : 0 }
  rest ~ /^[[:space:]]*#else/ { if (dbgat[depth]==1) dbgat[depth]=0 }
  rest ~ /^[[:space:]]*#endif/ { dbgat[depth]=0; depth-- }
  rest ~ /debugTriggerAthan|debugWipeState|debugWindowEnd|DebugMenu\(/ {
    inside=0; for (i=1;i<=depth;i++) if (dbgat[i]==1) inside=1
    if (!inside) print $1 ":" $2
  }
' "$code")
[ -z "$dbg_leaks" ] || bad "debug entry point outside #if DEBUG: $dbg_leaks"

# 11. Private MediaRemote: only MediaPauser.swift may dlopen/dlsym, and it sends exactly one command (kMRPause = 1).
only_in 'dlopen\(|dlsym\(|unsafeBitCast' 'Audio/MediaPauser.swift'
only_in 'MRMediaRemote|PrivateFrameworks' 'Audio/MediaPauser.swift'
n=$(count 'MRMediaRemoteSendCommand'); [ "$n" -le 1 ] || bad "MRMediaRemoteSendCommand resolved $n times (want 1)"
[ "$strict" -eq 0 ] || [ "$n" -eq 1 ] || bad "--strict: MRMediaRemoteSendCommand appears $n times (want exactly 1)"
n=$(count 'MRMediaRemoteGet|MRMediaRemoteRegister|kMRPlay|kMRTogglePlayPause'); [ "$n" -eq 0 ] || bad "only kMRPause may be used"

# 10. Release binary: no debug strings.
if [ -n "$release_app" ]; then
  bin="$release_app/Contents/MacOS/$(defaults read "$release_app/Contents/Info" CFBundleExecutable 2>/dev/null)"
  [ -f "$bin" ] || bad "--release: no executable in $release_app"
  # Every binary in Contents/MacOS, not only the executable: a Debug build keeps its code
  # in "<name>.debug.dylib" (this is what makes the Debug .app a working negative control).
  while IFS= read -r -d '' f; do
    for s in 'Trigger Athan' 'debugTriggerAthan' 'I prayed (stub' 'Wipe state' 'GoPrayDebugHideOnly' 'GoPrayDebugSeed' 'debugWindowEnd'; do
      strings -a "$f" | grep -qF "$s" && bad "--release: '$s' found in $f"
    done
  done < <(find "$release_app/Contents/MacOS" -type f -print0 2>/dev/null)
fi

if [ "$fail" -eq 0 ]; then echo "guard: OK ($src)"; fi
exit "$fail"
