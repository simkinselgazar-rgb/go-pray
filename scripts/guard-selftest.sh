#!/bin/bash
# guard-selftest.sh — negative controls for scripts/guard.sh. Owner: PM.
# Each case mutates a throwaway copy of GoPray/ and expects guard.sh to FAIL
# (or pass, for the positive controls). Run after any change to guard.sh.
REPO="$(cd "$(dirname "$0")/.." && pwd)"; SP="$(mktemp -d -t gopray-guard-selftest)"; G="$REPO/scripts/guard.sh"
pass=0; failn=0
run() { # name expect(FAIL|OK) mutation-shell
  local name="$1" expect="$2" mut="$3" d="$SP/nc-src"
  rm -rf "$d"; cp -R "$REPO/GoPray" "$d"; mkdir -p "$d/Shield" "$d/Prayer"
  ( cd "$d" && eval "$mut" )
  out="$("$G" "$d" 2>&1)"; rc=$?
  if { [ "$expect" = FAIL ] && [ $rc -ne 0 ]; } || { [ "$expect" = OK ] && [ $rc -eq 0 ]; }; then
    pass=$((pass+1)); printf 'ok   %-42s %s\n' "$name" "$(echo "$out" | head -1)"
  else
    failn=$((failn+1)); printf 'BAD  %-42s rc=%s %s\n' "$name" "$rc" "$(echo "$out" | head -2 | tr '\n' ' ')"
  fi
}
run "baseline copy"                OK   ':'
run "extra endBlock call"          FAIL "sed -i '' 's/        audio.stop()\n        if !b.silenced/&/; /func requestSilence/a\\
        endBlock()
' Core/BlockGate.swift"
run "endBlock called from failOpen only" FAIL "sed -i '' 's/^        endBlock(\.[a-z]*)\$/        _ = 0/' Core/BlockGate.swift; sed -i '' '/private func failOpen/a\\
        endBlock()
' Core/BlockGate.swift"
run "emergency exit's endBlock moved to requestSilence" FAIL "sed -i '' 's/^        endBlock(\.emergency)\$/        _ = 0/' Core/BlockGate.swift; sed -i '' '/func requestSilence/a\\
        endBlock(.emergency)
' Core/BlockGate.swift"
run "recordUse( in MenuView"       FAIL "echo 'func x(l: EmergencyLedger) { try? l.recordUse(.init(prayer: .asr, athanAt: Date(), at: Date()), now: Date()) }' >> UI/MenuView.swift"
run "second recordUse( in BlockGate" FAIL "sed -i '' '/func requestSilence/a\\
        try? ledger.recordUse(.init(prayer: .asr, athanAt: Date(), at: Date()), now: Date())
' Core/BlockGate.swift"
run "emergency.json named elsewhere" FAIL "echo 'let f = \"emergency.json\"' >> Core/Scheduler.swift"
run "EmergencyExitsUsed elsewhere" FAIL "echo 'let k = \"EmergencyExitsUsed\"' >> UI/MenuView.swift"
run "debugSetEmergencyExitsUsed outside DEBUG" FAIL "echo 'func x(l: EmergencyLedger) { l.debugSetEmergencyExitsUsed(5, now: Date()) }' >> GoPrayApp.swift"
run ".hide() outside AppHider"     FAIL "echo 'func x(a: NSRunningApplication) { a.hide() }' >> Core/Scheduler.swift"
run "endBlock not private"         FAIL "sed -i '' 's/private func endBlock/func endBlock/' Core/BlockGate.swift"
run "failOpen outside BlockGate"   FAIL "echo 'func x(g: Any) { failOpen(.crashLoop) }' >> GoPrayApp.swift"
run "forceTerminate"               FAIL "echo 'func x(a: NSRunningApplication) { a.forceTerminate() }' >> Core/Stubs.swift"
run ".terminate()"                 FAIL "echo 'func x(a: NSRunningApplication) { a.terminate() }' >> Core/Stubs.swift"
run "kill("                        FAIL "echo 'func x() { kill(1, 9) }' >> Core/Stubs.swift"
run "SIGKILL"                      FAIL "echo 'let s = SIGKILL' >> Core/Stubs.swift"
run "URLSession outside Geocoder"  FAIL "echo 'let u = URLSession.shared' >> Core/Scheduler.swift"
run "CLGeocoder outside Geocoder"  FAIL "echo 'let g = CLGeocoder()' >> Core/Scheduler.swift"
run "URLSession in Geocoder (pos)" OK   "echo 'let u = URLSession.shared' > Prayer/Geocoder.swift"
run "URLSession in MenuView"       FAIL "echo 'let u = URLSession.shared' >> UI/MenuView.swift"
run "URLSession in UpdateChecker (pos)" OK "echo 'let u2 = URLSession.shared' >> Update/UpdateChecker.swift"
run "signature requirement without the team id" FAIL "sed -i '' 's/3BB4JMG8GR/XXXXXXXXXX/' Update/UpdateChecker.swift"
run "second api.github.com literal elsewhere" FAIL "echo 'let h = \"api.github.com\"' >> UI/MenuView.swift"
run "releases/download literal elsewhere" FAIL "echo 'let h = \"releases/download\"' >> Core/Scheduler.swift"
run "pinned repo literal twice"    FAIL "echo 'let r = \"simkinselgazar-rgb/go-pray\"' >> Update/UpdateChecker.swift"
run "pinned repo literal elsewhere" FAIL "echo 'let r = \"simkinselgazar-rgb/go-pray\"' >> UI/MenuView.swift"
run "SecStaticCodeCheckValidity elsewhere" FAIL "echo 'func x() { _ = SecStaticCodeCheckValidity }' >> Core/Scheduler.swift"
run "NSWorkspace.shared.open elsewhere" FAIL "echo 'func x(u: URL) { NSWorkspace.shared.open(u) }' >> UI/MenuView.swift"
run "updates folder string elsewhere" FAIL "echo 'let d = \"updates\"' >> Core/StateStore.swift"
run "evaluateJavaScript elsewhere" FAIL "echo 'func x(w: WKWebView) { w.evaluateJavaScript(\"1\") }' >> Core/Stubs.swift"
run "WKUserContentController elsewhere" FAIL "echo 'let c = WKUserContentController()' >> Core/Stubs.swift"
run "WKWebView( elsewhere"         FAIL "echo 'let w = WKWebView(frame: .zero)' >> Core/Stubs.swift"
run "WKWebViewConfiguration elsewhere" FAIL "echo 'let c = WKWebViewConfiguration()' >> Core/Stubs.swift"
run "loadFileURL elsewhere"        FAIL "echo 'func x(w: WKWebView, u: URL) { w.loadFileURL(u, allowingReadAccessTo: u) }' >> Core/Stubs.swift"
run "loadHTMLString elsewhere"     FAIL "echo 'func x(w: WKWebView) { w.loadHTMLString(\"<p>\", baseURL: nil) }' >> Core/Stubs.swift"
run "load(URLRequest elsewhere"    FAIL "echo 'func x(w: WKWebView, r: URLRequest) { w.load(URLRequest(url: r.url!)) }' >> Core/Stubs.swift"
run "WKWebView( in SceneWebView (pos)" OK "echo 'let w = WKWebView(frame: .zero)' >> Shield/SceneWebView.swift"
run "allowingReadAccessTo once (pos)" OK "echo 'func x(w: WKWebView, u: URL) { w.loadFileURL(u, allowingReadAccessTo: scenesDir) }' > Shield/SceneWebView.swift"
run "allowingReadAccessTo twice"   FAIL "printf 'func x(w: WKWebView, u: URL) { w.loadFileURL(u, allowingReadAccessTo: scenesDir) }\nfunc y(w: WKWebView, u: URL) { w.loadFileURL(u, allowingReadAccessTo: scenesDir) }\n' > Shield/SceneWebView.swift"
run "allowingReadAccessTo wrong file" FAIL "echo 'func x(w: WKWebView, u: URL) { w.loadFileURL(u, allowingReadAccessTo: scenesDir) }' >> Core/Stubs.swift"
run "allowingReadAccessTo not scenes" FAIL "echo 'func x(w: WKWebView, u: URL) { w.loadFileURL(u, allowingReadAccessTo: URL(fileURLWithPath: \"/\")) }' > Shield/SceneWebView.swift"
run "isInspectable outside DEBUG"  FAIL "echo 'func x(w: WKWebView) { w.isInspectable = true }' >> Core/Stubs.swift"
run "isInspectable in #else of DEBUG" FAIL "printf '#if DEBUG\nlet a = 1\n#else\nfunc x(w: WKWebView) { w.isInspectable = true }\n#endif\n' >> Core/Stubs.swift"
run "isInspectable inside DEBUG (pos)" OK "printf '#if DEBUG\nfunc x(w: WKWebView) { w.isInspectable = true }\n#endif\n' >> Core/Stubs.swift"
run "CGEvent"                      FAIL "echo 'let e = CGEvent(source: nil)' >> Core/Stubs.swift"
run "AXUIElement"                  FAIL "echo 'let e = AXUIElementCreateSystemWide()' >> Core/Stubs.swift"
run "CGWindowListCreateImage"      FAIL "echo 'let i = CGWindowListCreateImage(.null, [], 0, [])' >> Core/Stubs.swift"
run "addGlobalMonitorForEvents"    FAIL "echo 'let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { _ in }' >> Core/Stubs.swift"
run "disableSessionTermination"    FAIL "echo 'let o: NSApplication.PresentationOptions = [.disableSessionTermination]' >> Core/Stubs.swift"
run "debugTriggerAthan outside DEBUG" FAIL "echo 'func x(g: BlockGate) { g.debugTriggerAthan(.asr, lockSeconds: 1) }' >> GoPrayApp.swift"
run "dlopen outside MediaPauser"   FAIL "echo 'let h = dlopen(\"/x\", RTLD_NOW)' >> Core/Stubs.swift"
run "MRMediaRemoteGetNowPlayingInfo in MediaPauser" FAIL "echo 'let s = \"MRMediaRemoteGetNowPlayingInfo\"' >> Audio/MediaPauser.swift"
run "second MRMediaRemoteSendCommand" FAIL "echo 'let s = \"MRMediaRemoteSendCommand\"' >> Audio/MediaPauser.swift"
run "comment naming emergency.json (pos)" OK "echo '// the ledger writes emergency.json and calls recordUse(' >> UI/MenuView.swift"
run "comment naming forceTerminate (pos)" OK "echo '// we never call forceTerminate() or kill(' >> Core/Stubs.swift"
rm -rf "$SP"
echo "negative controls: $pass as expected, $failn wrong"
[ $failn -eq 0 ]
