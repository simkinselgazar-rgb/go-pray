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

# Every hit of $1 must be in file $2 or file $3.
only_in2() {
  local pat="$1" a="$2" b="$3" f
  for f in $(files "$pat"); do
    [ "$f" = "$a" ] || [ "$f" = "$b" ] || bad "'$pat' outside $a and $b: $(hits "$pat" | grep "^$f:" | head -3 | tr '\n' ' ')"
  done
}

# 1. endBlock( : exactly 3 (private declaration + two calls), all in BlockGate, the calls inside
#    requestConfirm and requestEmergencyExit (v2) and nowhere else.
n=$(count 'endBlock\(')
[ "$n" -eq 3 ] || bad "endBlock( appears $n times (want 3: declaration + the calls in requestConfirm and requestEmergencyExit)"
only_in 'endBlock\(' 'Core/BlockGate.swift'
hits 'func endBlock\(' | grep -qE 'private func endBlock\(' || bad "endBlock must be declared private"
callers=$(awk -F: '
  { rest=$0; sub(/^[^:]+:[0-9]+:/, "", rest) }
  match(rest, /func [A-Za-z_][A-Za-z0-9_]*/) { fn=substr(rest, RSTART+5, RLENGTH-5) }
  rest ~ /endBlock\(/ && rest !~ /func endBlock\(/ { print fn }
' <(grep '^Core/BlockGate.swift:' "$code") | sort -u | tr '\n' ' ')
[ "$callers" = "requestConfirm requestEmergencyExit " ] || bad "endBlock( called from '${callers:-nothing}', want only requestConfirm and requestEmergencyExit"

# 2. failOpen( : only in BlockGate, declared private.
only_in 'failOpen\(' 'Core/BlockGate.swift'
if [ "$(count 'failOpen\(')" -gt 0 ]; then
  hits 'func failOpen\(' | grep -qE 'private func failOpen\(' || bad "failOpen must be declared private"
fi

# 3. Never kill anything.
for p in 'forceTerminate' '\.terminate\(\)' '(^|[^A-Za-z0-9_])kill\(' 'SIGKILL'; do
  n=$(count "$p"); [ "$n" -eq 0 ] || bad "'$p' must not appear ($n hits): $(hits "$p" | head -3 | tr '\n' ' ')"
done

# 4. Network: the geocoder file, the one update-check file (v2) and the one TV file (TV Plan §3). Nothing else.
for f in $(files 'URLSession'); do
  [ "$f" = "Prayer/Geocoder.swift" ] || [ "$f" = "Update/UpdateChecker.swift" ] || [ "$f" = "TV/TVController.swift" ] || [ "$f" = "TV/SamsungTV.swift" ] \
    || bad "'URLSession' outside the geocoder, the update checker and the TV files: $f"
done
# 4c. TV control (CONTRACT-NOTES #56): raw sockets (SSDP) and Network.framework only in the TV file, and that file holds
#     no hostname, URL or IP literal inside a string (hosts come from Settings only). The one allowed IP literal is
#     the SSDP multicast group. ":8060" and "/launch" path pieces are fine: they are not hosts.
TVF='TV/TVController.swift'
only_in '(^|[^A-Za-z0-9_.])(socket|sendto|recvfrom|bind|connect)\(' "$TVF"
only_in 'CFSocket|CFStream' "$TVF"
# Google TV (Google TV Plan §6): Network.framework lives in exactly the two files that speak a TV protocol; the one
# listener is the in-app video server, bound to the one local address; the Cast app id is written in one file.
CAST='TV/CastTV.swift'; REMOTE='TV/AndroidRemote.swift'; CSERVER='TV/CastServer.swift'
# Outbound (constructing a connection, browsing) only in the two protocol files. The server names the NWConnection
# type for the connections its listener ACCEPTS, but never constructs one.
only_in2 'NWConnection\(|NWBrowser' "$CAST" "$REMOTE"
for f in $(files 'NWConnection'); do
  [ "$f" = "$CAST" ] || [ "$f" = "$REMOTE" ] || [ "$f" = "$CSERVER" ] || bad "'NWConnection' outside $CAST, $REMOTE and $CSERVER: $f"
done
only_in 'NWListener' "$CSERVER"
n=$(count 'NWListener'); [ "$n" -le 1 ] || bad "NWListener appears $n times (want at most 1, in $CSERVER)"
[ "$strict" -eq 0 ] || [ ! -f "$src/$CSERVER" ] || [ "$n" -eq 1 ] || bad "--strict: NWListener appears $n times in $CSERVER (want exactly 1)"
if [ "$n" -ge 1 ]; then
  [ "$(hits 'requiredLocalEndpoint' | grep -c "^$CSERVER:" || true)" -ge 1 ] || bad "the listener in $CSERVER must set requiredLocalEndpoint (bound to the one local address)"
fi
only_in '"CC1AD845"' 'TV/TVDevice.swift'
# Samsung (Samsung TV Plan §6): the WebSocket task lives in the one Samsung file.
only_in 'URLSessionWebSocketTask|webSocketTask\(' 'TV/SamsungTV.swift'
# (comments, and so anything after "//", are stripped before matching: an "http:" inside a string is enough)
for TVF in 'TV/TVController.swift' 'TV/SamsungTV.swift' "$CAST" "$CSERVER" 'TV/CastVideo.swift' "$REMOTE"; do
  tvbad=$(hits '"[^"]*(https?|wss?):|"([^"]*[^A-Za-z0-9])?(www\.|localhost)|"([^"]*[^A-Za-z0-9.-])?[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.(com|net|org|io|tv|app|dev|local|lan|home|arpa|co|ca|me|us|uk)([^A-Za-z0-9][^"]*)?"' | grep "^$TVF:" || true)
  [ -z "$tvbad" ] || bad "a hostname or URL literal in $TVF (hosts come from Settings only): $(echo "$tvbad" | head -3 | tr '\n' ' ')"
  tvip=$(hits '"([^"]*[^0-9.])?[0-9]{1,3}(\.[0-9]{1,3}){3}([^0-9.][^"]*)?"' | grep "^$TVF:" | grep -v '239\.255\.255\.250' || true)
  [ -z "$tvip" ] || bad "an IP literal in $TVF (only the SSDP group 239.255.255.250 is allowed): $(echo "$tvip" | head -3 | tr '\n' ' ')"
done
# 4d. Samsung credentials and TLS (Samsung TV Plan §6/§7): Keychain only in the token file; trust handling only in the
#     Samsung file, and its single trust exception (useCredential) appears at most once (exactly once under --strict).
only_in 'SecItem|kSecClass|kSecAttr' 'TV/TVToken.swift'
only_in 'didReceive challenge|serverTrust|SecTrust' 'TV/SamsungTV.swift'
only_in 'cancelAuthenticationChallenge|useCredential' 'TV/SamsungTV.swift'
n=$(count 'useCredential'); [ "$n" -le 1 ] || bad "useCredential appears $n times (want at most 1)"
if [ "$strict" -eq 1 ] && [ -f "$src/TV/SamsungTV.swift" ]; then
  [ "$n" -eq 1 ] || bad "--strict: useCredential appears $n times in TV/SamsungTV.swift (want exactly 1)"
fi

# 4d-2. The Android TV remote identity lives in a keychain file the app owns (Google TV Keychain Review §3): the identity
#     class is never named, the one item delete is the Samsung token's, every identity query is scoped to our file, and
#     nothing puts that file in a search list.
n=$(count 'kSecClassIdentity'); [ "$n" -eq 0 ] || bad "kSecClassIdentity appears $n times (want 0: its label filter is ignored and a query matches the person's own signing identities)"
n=$(count 'SecItemDelete\('); [ "$n" -le 1 ] || bad "SecItemDelete( appears $n times (want one: the Samsung token, in TV/TVToken.swift)"
[ "$(hits 'SecItemDelete\(' | grep -vc '^TV/TVToken.swift:[0-9]*:.*query(' || true)" -eq 0 ] || bad "SecItemDelete( outside the generic-password query( in TV/TVToken.swift: $(hits 'SecItemDelete\(' | head -3 | tr '\n' ' ')"
only_in 'SecKeychainSetSearchList|SecKeychainSetDefault|SecKeychainCopyDefault|SecKeychainCopySearchList' 'NONE'
only_in 'SecKeychainCreate|SecKeychainOpen|SecKeychainDelete|SecKeychainUnlock' 'TV/TVToken.swift'
if [ -f "$src/TV/TVToken.swift" ]; then
  # the identity section = TVToken.swift from the "Android TV Remote client identity" marker to the end (comment-stripped)
  idmark=$(grep -n 'MARK: - The Android TV Remote client identity' "$src/TV/TVToken.swift" | head -1 | cut -d: -f1)
  idsec=$(grep -E '^TV/TVToken.swift:' "$code" | awk -F: -v m="${idmark:-0}" '$2+0 > m+0')
  if [ -z "${idmark:-}" ]; then
    bad "TV/TVToken.swift: no 'MARK: - The Android TV Remote client identity' marker (guard 4d-2 needs it)"
  else
    nc=$(printf '%s\n' "$idsec" | grep -c 'SecItemCopyMatching(' || true)
    nsl=$(printf '%s\n' "$idsec" | grep -c 'kSecMatchSearchList' || true)
    [ "$nc" -eq "$nsl" ] || bad "TV/TVToken.swift identity section: SecItemCopyMatching( x$nc but kSecMatchSearchList x$nsl (every query must carry our file as its search list)"
    plain=$(printf '%s\n' "$idsec" | grep 'SecItemCopyMatching(' | grep -v 'scoped(' || true)
    [ -z "$plain" ] || bad "TV/TVToken.swift identity section: a SecItemCopyMatching( not built by scoped( : $(echo "$plain" | head -2 | tr '\n' ' ')"
    addbad=$(printf '%s\n' "$idsec" | grep 'SecItemAdd(' | grep -v 'kSecUseKeychain' || true)
    [ -z "$addbad" ] || bad "TV/TVToken.swift identity section: a SecItemAdd( without kSecUseKeychain (it would land in login): $(echo "$addbad" | head -2 | tr '\n' ' ')"
    nuk=$(printf '%s\n' "$idsec" | grep -c 'kSecUseKeychain' || true)
    if [ "$strict" -eq 1 ]; then
      [ "$nsl" -ge 1 ] || bad "--strict: TV/TVToken.swift identity section has no kSecMatchSearchList"
      [ "$nuk" -ge 2 ] || bad "--strict: TV/TVToken.swift identity section must carry kSecUseKeychain on the key and on the certificate add (found $nuk)"
    fi
  fi
fi

# 4e. Google TV TLS, keys and encoders (Google TV Plan §6/§7): the two TLS trust exceptions (one per protocol file, each
#     scoped to one host), the remote's client identity and key material, and the video encoder, each in one place.
only_in2 'sec_protocol_options_set_verify_block|sec_protocol_verify_complete' "$CAST" "$REMOTE"
n=$(count 'sec_protocol_options_set_verify_block|sec_protocol_verify_complete'); [ "$n" -le 2 ] || bad "TLS verify exceptions appear $n times (want at most 2: one in $CAST, one in $REMOTE)"
if [ "$strict" -eq 1 ] && [ -f "$src/$CAST" ] && [ -f "$src/$REMOTE" ]; then
  [ "$n" -eq 2 ] || bad "--strict: TLS verify exceptions appear $n times (want exactly 2, one in each of $CAST and $REMOTE)"
  for f in "$CAST" "$REMOTE"; do
    [ "$(hits 'sec_protocol_options_set_verify_block|sec_protocol_verify_complete' | grep -c "^$f:" || true)" -ge 1 ] \
      && [ "$(hits 'sec_protocol_options_set_verify_block' | grep -c "^$f:" || true)" -eq 1 ] || bad "--strict: $f must hold exactly one sec_protocol_options_set_verify_block"
  done
fi
only_in 'sec_protocol_options_set_local_identity|sec_identity_create' "$REMOTE"
only_in 'SecKeyCreateRandomKey|SecKeyCreateSignature|SecCertificateCreateWithData' "$REMOTE"
only_in 'AVAssetWriter|AVAssetReader' 'TV/CastVideo.swift'

# 4f. The power allow-list (Google TV Plan §6, one choke point): the TV remote's key injection exists only in
#     AndroidRemote.swift; RemoteKey has exactly one case (power = 26), RemoteDirection exactly one (short = 3); and
#     turnOff( is called from exactly one line, in CastTV.swift, behind wasOff.
only_in 'remote_key_inject|keyInject|RemoteKey([^A-Za-z0-9_]|$)' "$REMOTE"
if [ -f "$src/$REMOTE" ]; then
  # one-case enums: the body up to the first "}" must hold exactly one `case`, spelled `<name> = <n>`
  one_case() {   # enum name, expected case line
    local en="$1" want="$2" body
    body=$(sed -E 's,//.*$,,' "$src/$REMOTE" | perl -0777 -ne "print \$1 if /\\benum\\s+$en\\b[^{]*\\{([^}]*)\\}/s")
    if [ -z "$body" ]; then
      [ "$strict" -eq 0 ] || bad "--strict: no enum $en in $REMOTE"
      return
    fi
    [ "$(printf '%s' "$body" | grep -oE '\bcase\b' | grep -c . || true)" -eq 1 ] || bad "enum $en must have exactly one case (found: $(printf '%s' "$body" | tr '\n' ' ' | tr -s ' '))"
    printf '%s' "$body" | grep -qE "^[[:space:]]*case[[:space:]]+$want[[:space:]]*$" || bad "enum $en's one case must be '$want'"
  }
  one_case RemoteKey 'power = 26'
  one_case RemoteDirection 'short = 3'
fi
tn=$(hits 'turnOff\(' | grep -vE 'func turnOff\(' | grep -c . || true)
[ "$tn" -le 1 ] || bad "turnOff( called $tn times (want exactly 1, in $CAST behind wasOff)"
if [ "$tn" -ge 1 ]; then
  hits 'turnOff\(' | grep -vE 'func turnOff\(' | cut -d: -f1 | sort -u | grep -qxv "$CAST" && bad "turnOff( called outside $CAST"
  hits 'turnOff\(' | grep -vE 'func turnOff\(' | grep -q 'wasOff' || bad "turnOff( must be called on a line that checks wasOff"
fi
[ "$strict" -eq 0 ] || [ ! -f "$src/$CAST" ] || [ "$tn" -eq 1 ] || bad "--strict: turnOff( called $tn times (want exactly 1, in $CAST)"

only_in 'CLGeocoder' 'Prayer/Geocoder.swift'
# 4b. The update checker (v2 §8.3): the GitHub hosts, the pinned repo (exactly once), the signature check with
#     our team id, the downloads folder and opening a file all live in Update/UpdateChecker.swift only.
UC='Update/UpdateChecker.swift'
only_in 'api\.github\.com|objects\.githubusercontent\.com|release-assets\.githubusercontent\.com|releases/download' "$UC"
only_in 'simkinselgazar-rgb/go-pray' "$UC"
n=$(count 'simkinselgazar-rgb/go-pray'); [ "$n" -le 1 ] || bad "the pinned repo appears $n times (want exactly 1)"
[ "$strict" -eq 0 ] || [ "$n" -eq 1 ] || bad "--strict: the pinned repo appears $n times in $UC (want exactly 1)"
only_in 'SecStaticCodeCheckValidity|SecRequirementCreateWithString|SecStaticCodeCreateWithPath' "$UC"
if [ "$(count 'SecRequirementCreateWithString')" -gt 0 ]; then
  [ "$(count '3BB4JMG8GR')" -ge 1 ] || bad "the signature requirement in $UC must name team 3BB4JMG8GR"
fi
only_in '"updates"' "$UC"
only_in 'NSWorkspace\.shared\.open\(' "$UC"

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
  rest ~ /debugTriggerAthan|debugWipeState|debugWindowEnd|debugSetEmergencyExitsUsed|DebugMenu\(/ {
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

# 12. The emergency ledger (v2): its file and prefs keys only in Core/EmergencyLedger.swift; recordUse( is
#     declared there and called exactly once elsewhere, in BlockGate.swift inside requestEmergencyExit.
only_in 'emergency\.json|(^|[^A-Za-z])EmergencyExitsUsed|(^|[^A-Za-z])EmergencyExitsYear' 'Core/EmergencyLedger.swift'
for f in $(files 'recordUse\('); do
  [ "$f" = "Core/EmergencyLedger.swift" ] || [ "$f" = "Core/BlockGate.swift" ] || bad "recordUse( outside the ledger and the gate: $f"
done
n=$(grep '^Core/BlockGate.swift:' "$code" | grep -cE 'recordUse\(' || true)
[ "$n" -le 1 ] || bad "recordUse( appears $n times in BlockGate (want 1)"
if [ "$n" -eq 1 ]; then
  rc=$(awk -F: '
    { rest=$0; sub(/^[^:]+:[0-9]+:/, "", rest) }
    match(rest, /func [A-Za-z_][A-Za-z0-9_]*/) { fn=substr(rest, RSTART+5, RLENGTH-5) }
    rest ~ /recordUse\(/ { print fn }
  ' <(grep '^Core/BlockGate.swift:' "$code") | sort -u | tr '\n' ' ')
  [ "$rc" = "requestEmergencyExit " ] || bad "recordUse( called from '$rc', want only requestEmergencyExit"
fi
[ "$strict" -eq 0 ] || [ "$n" -eq 1 ] || bad "--strict: recordUse( appears $n times in BlockGate (want exactly 1)"

# 13. Hiding a running app (the list is user data now): only the one hider file.
only_in '\.hide\(' 'Blocker/AppHider.swift'

# 14. The TV hears about an Athan from exactly one place: athanStarted( (not its declarations) appears once, in
#     Core/BlockGate.swift inside present. A late wake never reaches present with a fresh Athan, so it never wakes the TV.
n=$(hits 'athanStarted\(' | grep -vE 'func athanStarted\(' | grep -c . || true)
[ "$n" -eq 1 ] || bad "athanStarted( called $n times (want exactly 1, in BlockGate present)"
only_in_calls=$(hits 'athanStarted\(' | grep -vE 'func athanStarted\(' | cut -d: -f1 | sort -u | grep -v '^Core/BlockGate.swift$' || true)
[ -z "$only_in_calls" ] || bad "athanStarted( called outside Core/BlockGate.swift: $only_in_calls"
ac=$(awk -F: '
  { rest=$0; sub(/^[^:]+:[0-9]+:/, "", rest) }
  match(rest, /func [A-Za-z_][A-Za-z0-9_]*/) { fn=substr(rest, RSTART+5, RLENGTH-5) }
  rest ~ /athanStarted\(/ && rest !~ /func athanStarted\(/ { print fn }
' <(grep '^Core/BlockGate.swift:' "$code") | sort -u | tr '\n' ' ')
[ "$n" -eq 0 ] || [ "$ac" = "present " ] || bad "athanStarted( called from '${ac:-nothing}', want only present"

# 10. Release binary: no debug strings.
if [ -n "$release_app" ]; then
  bin="$release_app/Contents/MacOS/$(defaults read "$release_app/Contents/Info" CFBundleExecutable 2>/dev/null)"
  [ -f "$bin" ] || bad "--release: no executable in $release_app"
  # Every binary in Contents/MacOS, not only the executable: a Debug build keeps its code
  # in "<name>.debug.dylib" (this is what makes the Debug .app a working negative control).
  while IFS= read -r -d '' f; do
    for s in 'Trigger Athan' 'debugTriggerAthan' 'I prayed (stub' 'Wipe state' 'GoPrayDebugHideOnly' 'GoPrayDebugSeed' 'debugWindowEnd' 'debugSetEmergencyExitsUsed' 'Emergency exits (debug)'; do
      strings -a "$f" | grep -qF "$s" && bad "--release: '$s' found in $f"
    done
  done < <(find "$release_app/Contents/MacOS" -type f -print0 2>/dev/null)
fi

if [ "$fail" -eq 0 ]; then echo "guard: OK ($src)"; fi
exit "$fail"
