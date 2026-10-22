// Go Pray Phase 0 spike. One binary, many modes (argv[1]). Throwaway code: answers questions, ships nothing.
import AppKit
import WebKit
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement
import CoreAudio

// MARK: helpers

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "help"
func opt(_ n: String) -> String? {
    guard let i = args.firstIndex(of: "--" + n), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func flag(_ n: String) -> Bool { args.contains("--" + n) }

let t0 = Date()
let logPath = opt("log")
func log(_ s: String) {
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    let line = String(format: "[%7d ms] ", ms) + s
    print(line); fflush(stdout)
    if let p = logPath, let d = (line + "\n").data(using: .utf8) {
        if let h = FileHandle(forWritingAtPath: p) { h.seekToEndOfFile(); h.write(d); try? h.close() }
        else { FileManager.default.createFile(atPath: p, contents: d) }
    }
}

func hardExit(after sec: Double) {
    // watchdog on a background queue: works even if the main thread is stuck
    DispatchQueue.global().asyncAfter(deadline: .now() + sec) { log("WATCHDOG exit"); exit(0) }
}

func dumpWindows(tag: String) {
    guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return }
    let me = ProcessInfo.processInfo.processIdentifier
    for w in list {
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let pid = w[kCGWindowOwnerPID as String] as? Int32 ?? 0
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        let on = w[kCGWindowIsOnscreen as String] as? Bool ?? false
        let name = w[kCGWindowName as String] as? String ?? ""
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let w_ = b["Width"] as? Double ?? 0, h_ = b["Height"] as? Double ?? 0
        let interesting = pid == me || ["Spotlight", "Dock", "Window Server", "Mission Control", "Force Quit", "loginwindow", "Control Center", "SystemUIServer"].contains(owner) || owner.contains("Spotlight")
        if interesting && (on || pid == me) && w_ > 20 && h_ > 20 {
            log("\(tag) CGWindow owner=\(owner) pid=\(pid) layer=\(layer) onscreen=\(on) size=\(Int(w_))x\(Int(h_)) name=\(name)")
        }
    }
}

// MARK: shield panel

final class ShieldPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class MsgHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        log("WEB message received: \(m.body)")
    }
}

func parseOpts(_ s: String) -> NSApplication.PresentationOptions {
    var o: NSApplication.PresentationOptions = []
    for p in s.split(separator: ",") {
        switch p {
        case "hideDock": o.insert(.hideDock)
        case "hideMenuBar": o.insert(.hideMenuBar)
        case "disableProcessSwitching": o.insert(.disableProcessSwitching)
        case "disableForceQuit": o.insert(.disableForceQuit)
        case "disableHideApplication": o.insert(.disableHideApplication)
        default: log("unknown opt \(p)")
        }
    }
    return o
}

final class ShieldApp: NSObject, NSApplicationDelegate {
    var panels: [ShieldPanel] = []
    var webViews: [WKWebView] = []
    let handler = MsgHandler()
    var navLogger: NavLogger?
    var resigns = 0
    var hotKeyRef: EventHotKeyRef?
    let isCpu = mode == "webcpu"

    func applicationDidFinishLaunching(_ n: Notification) {
        let seconds = isCpu ? (Double(opt("seconds") ?? "60")) ?? 60 : min(Double(opt("seconds") ?? "15") ?? 15, 15)
        hardExit(after: seconds + 3)
        installHotKey()
        let levelName = opt("level") ?? "screensaver"
        let level: Int = levelName == "shielding" ? Int(CGShieldingWindowLevel()) : NSWindow.Level.screenSaver.rawValue
        log("mode=\(mode) level=\(levelName)(\(level)) activate=\(flag("activate")) opts=\(opt("opts") ?? "none") web=\(opt("web") ?? "none") seconds=\(seconds)")
        log("screens=\(NSScreen.screens.count) frames=\(NSScreen.screens.map { NSStringFromRect($0.frame) })")

        let screens: [NSScreen]
        if isCpu {
            // Not a shield: a mouse-transparent 1280x720 window in the bottom-right of the smallest display.
            screens = [NSScreen.screens.min(by: { $0.frame.width < $1.frame.width })!]
        } else { screens = NSScreen.screens }

        for (i, s) in screens.enumerated() {
            let rect: NSRect = isCpu ? NSRect(x: s.frame.maxX - 1280, y: s.frame.minY, width: 1280, height: 720) : s.frame
            let p = ShieldPanel(contentRect: rect, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false, screen: s)
            p.level = NSWindow.Level(rawValue: isCpu ? NSWindow.Level.normal.rawValue : level)
            p.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary]
            p.hidesOnDeactivate = false
            p.isOpaque = true
            p.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.2, alpha: 1)
            p.ignoresMouseEvents = isCpu
            let useWeb = (opt("web") != nil) && (i == 0 || isCpu)
            if useWeb { p.contentView = makeWebView(rect: NSRect(origin: .zero, size: rect.size)) }
            else {
                let label = NSTextField(labelWithString: "GO PRAY SPIKE SHIELD  level=\(level)  screen \(i)")
                label.font = .systemFont(ofSize: 48, weight: .bold); label.textColor = .white
                label.frame = NSRect(x: 60, y: rect.height / 2, width: rect.width - 120, height: 70)
                let v = NSView(frame: NSRect(origin: .zero, size: rect.size)); v.addSubview(label); p.contentView = v
            }
            p.setFrame(rect, display: true)   // init(contentRect:screen:) treats rect as screen-relative; set global frame explicitly
            p.orderFrontRegardless()
            panels.append(p)
            log("panel \(i) shown level=\(p.level.rawValue) frame=\(NSStringFromRect(p.frame))")
        }

        if flag("activate") {
            NSApp.activate(ignoringOtherApps: true)
            panels.first?.makeKey()
            log("activated; isActive=\(NSApp.isActive) keyWindow=\(NSApp.keyWindow != nil)")
        }
        if let o = opt("opts") {
            // presentationOptions only take effect while we are the active app
            let po = parseOpts(o)
            NSApp.presentationOptions = po
            log("set presentationOptions raw=\(po.rawValue); readback raw=\(NSApp.presentationOptions.rawValue); menuBarVisible=\(NSMenu.menuBarVisible())")
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.resigns += 1
            log("didResignActive #\(self.resigns); front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
            if flag("reactivate") { NSApp.activate(ignoringOtherApps: true); self.panels.first?.makeKey(); log("re-activated; isActive=\(NSApp.isActive); options=\(NSApp.presentationOptions.rawValue)") }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in log("activeSpaceDidChange") }

        for t in [1.0, 4.0, 8.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self else { return }
                log("status isActive=\(NSApp.isActive) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") options=\(NSApp.presentationOptions.rawValue) menuBarVisible=\(NSMenu.menuBarVisible()) resigns=\(self.resigns)")
                if t == 1.0 { dumpWindows(tag: "t+1") }
                if t == 4.0, self.webViews.count > 0 { self.webRoundTrip() }
            }
        }
        if flag("poll") {
            var seen = Set<String>()
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return }
                let me = ProcessInfo.processInfo.processIdentifier
                var top: [String] = []
                for w in list {
                    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
                    let pid = w[kCGWindowOwnerPID as String] as? Int32 ?? 0
                    let layer = w[kCGWindowLayer as String] as? Int ?? 0
                    let name = w[kCGWindowName as String] as? String ?? ""
                    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
                    let sz = "\(Int(b["Width"] as? Double ?? 0))x\(Int(b["Height"] as? Double ?? 0))"
                    if pid == me || layer < 0 || owner == "Window Server" || owner == "Control Center" { continue }
                    let k = "\(owner)|\(layer)|\(name)|\(sz)"
                    if seen.insert(k).inserted { top.append(k) }
                }
                for k in top { log("POLL new onscreen window: \(k)") }
                log("POLL front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") active=\(NSApp.isActive) opts=\(NSApp.presentationOptions.rawValue)")
            }
        }
        if opt("web") != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.logWebPids() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            log("auto-dismiss timer fired; closing \(self.panels.count) panels")
            NSApp.presentationOptions = []
            self.panels.forEach { $0.orderOut(nil) }
            exit(0)
        }
    }

    func makeWebView(rect: NSRect) -> WKWebView {
        log("mk: cfg"); let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(handler, name: "gopray")
        log("mk: before WKWebView init"); let wv = WKWebView(frame: rect, configuration: cfg); log("mk: after WKWebView init")
        log("mk: a"); let scenes = Bundle.main.resourceURL!.appendingPathComponent("scenes", isDirectory: true)
        log("mk: b \(scenes.path)")
        let page = opt("web")!
        // NB: URLComponents(url:) on a file URL gives a RELATIVE url and loadFileURL then hangs the main thread. Build the absolute string instead.
        let indexURL = scenes.appendingPathComponent("index.html")
        let pageURL = URL(string: indexURL.absoluteString + "?prayer=\(page)&demo=0&chrome=0")!
        let t = Date()
        navLogger = NavLogger(t)
        wv.navigationDelegate = navLogger
        log("mk: d"); wv.loadFileURL(pageURL, allowingReadAccessTo: scenes); log("mk: e")
        log("loadFileURL \(pageURL.absoluteString) readAccess=\(scenes.path)")
        webViews.append(wv)
        return wv
    }

    func webRoundTrip() {
        let js = """
        (function(){
          var res = performance.getEntriesByType('resource').map(function(e){return e.name.replace(/^file:\\/\\/.*\\/scenes\\//,'scenes/');});
          var nonFile = res.filter(function(n){return n.indexOf('http')===0;});
          window.webkit.messageHandlers.gopray.postMessage('prayed');
          return JSON.stringify({resources:res, nonFileRequests:nonFile, title:document.title, fontsReady:document.fonts.status, sceneChildren:document.getElementById('scene').children.length, w:innerWidth, h:innerHeight});
        })()
        """
        let t = Date()
        webViews[0].evaluateJavaScript(js) { r, e in
            log("WEB eval round-trip \(Int(Date().timeIntervalSince(t) * 1000)) ms result=\(String(describing: r)) err=\(String(describing: e))")
        }
    }

    func logWebPids() {
        if let wv = webViews.first {
            let pid = wv.value(forKey: "_webProcessIdentifier") as? Int32 ?? -1
            log("WEBCONTENT_PID=\(pid) APP_PID=\(ProcessInfo.processInfo.processIdentifier)")
        }
    }

    func installHotKey() {
        // Ctrl-Opt-Cmd-Q, Carbon hotkey: global, needs no permission, still works with presentationOptions
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            log("HOTKEY pressed -> exit")
            NSApp.presentationOptions = []
            exit(0)
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x47505359), id: 1)
        let st = RegisterEventHotKey(UInt32(kVK_ANSI_Q), UInt32(controlKey | optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
        log("hotkey Ctrl-Opt-Cmd-Q registered status=\(st)")
    }
}

final class NavLogger: NSObject, WKNavigationDelegate {
    let t: Date
    init(_ t: Date) { self.t = t }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { log("WEB didFinish after \(Int(Date().timeIntervalSince(t) * 1000)) ms") }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { log("WEB didFail \(e)") }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { log("WEB didFailProvisional \(e)") }
}

// MARK: full-screen test app (stands in for "a full-screen app of Ahmed's")

final class FSApp: NSObject, NSApplicationDelegate {
    var win: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        let secs = Double(opt("seconds") ?? "90") ?? 90
        hardExit(after: secs + 3)
        win = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "GoPraySpike FS test"
        win.backgroundColor = NSColor(calibratedRed: 0.8, green: 0.1, blue: 0.1, alpha: 1)
        let label = NSTextField(labelWithString: "FULL-SCREEN TEST APP (red). Shield should cover this.")
        label.font = .systemFont(ofSize: 40, weight: .bold); label.textColor = .white; label.frame = NSRect(x: 40, y: 280, width: 1400, height: 60)
        win.contentView?.addSubview(label)
        win.collectionBehavior = [.fullScreenPrimary]
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("gopray.spike.quit"), object: nil, queue: .main) { _ in log("quit notification"); exit(0) }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            log("FS activeSpaceDidChange; myWindowOnActiveSpace=\(self?.win.isOnActiveSpace ?? false)")
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in log("FS didResignActive") }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in log("FS didBecomeActive") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.win.toggleFullScreen(nil); log("toggleFullScreen requested") }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            log("FS tick fullscreen=\(self.win.styleMask.contains(.fullScreen)) onActiveSpace=\(self.win.isOnActiveSpace) visible=\(self.win.occlusionState.contains(.visible)) active=\(NSApp.isActive) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        }
    }
}

// MARK: hide() test

final class HideApp: NSObject, NSApplicationDelegate {
    var ids: [String] = []
    // hide() then poll isHidden on the run loop (a blocking poll starves the KVO update and lies)
    func hideAndMeasure(_ a: NSRunningApplication, tag: String) {
        let t = Date(); let bid = a.bundleIdentifier ?? "?"
        let ok = a.hide()
        log("\(tag) \(bid) hide() returned \(ok)")
        Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { timer in
            let ms = Int(Date().timeIntervalSince(t) * 1000)
            if a.isHidden { log("\(tag) \(bid) isHidden=true after \(ms) ms"); timer.invalidate() }
            else if ms > 3000 { log("\(tag) \(bid) STILL NOT HIDDEN after \(ms) ms"); timer.invalidate() }
        }
    }
    func applicationDidFinishLaunching(_ n: Notification) {
        ids = (opt("ids") ?? "").split(separator: ",").map(String.init)
        let secs = Double(opt("seconds") ?? "30") ?? 30
        hardExit(after: secs + 3)
        for id in ids { for a in NSRunningApplication.runningApplications(withBundleIdentifier: id) { log("target \(id): isHidden=\(a.isHidden) activationPolicy=\(a.activationPolicy.rawValue)"); hideAndMeasure(a, tag: "initial") } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let a = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, let bid = a.bundleIdentifier else { return }
            guard self.ids.contains(bid) else { log("activate (not on list): \(bid)"); return }
            log("didActivate \(bid) isHidden(at notification)=\(a.isHidden)")
            self.hideAndMeasure(a, tag: "RE-HIDE")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { exit(0) }
    }
}

// MARK: audio

func coreAudioState() {
    var dev = AudioObjectID(0); var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
    var mute = UInt32(0); size = UInt32(MemoryLayout<UInt32>.size)
    var a2 = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    let st = AudioObjectGetPropertyData(dev, &a2, 0, nil, &size, &mute)
    var vol = Float32(0); var s3 = UInt32(MemoryLayout<Float32>.size)
    var a3 = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    let st3 = AudioObjectGetPropertyData(dev, &a3, 0, nil, &s3, &vol)
    log("CoreAudio defaultOutputDevice=\(dev) muteStatus=\(st) mute=\(mute) volStatus=\(st3) volume=\(vol)")
}

func runAudio() {
    let file = opt("file")!
    let offset = Double(opt("offset") ?? "0") ?? 0
    let secs = Double(opt("secs") ?? "3") ?? 3
    let vol = Float(opt("vol") ?? "0.1") ?? 0.1
    hardExit(after: secs + 10)
    do {
        let p = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: file))
        log("file=\(file.split(separator: "/").last!) duration=\(p.duration)s format=\(p.format)")
        p.volume = vol
        p.prepareToPlay()
        p.currentTime = offset
        log("after set currentTime=\(offset): readback currentTime=\(p.currentTime)")
        coreAudioState()
        let ok = p.play()
        log("play() returned \(ok) volume=\(p.volume)")
        let start = Date()
        while Date().timeIntervalSince(start) < secs {
            log(String(format: "playing=%d currentTime=%.3f", p.isPlaying ? 1 : 0, p.currentTime))
            Thread.sleep(forTimeInterval: 0.5)
        }
        p.stop()
        log("stopped; final currentTime=\(p.currentTime)")
        coreAudioState()
    } catch { log("ERROR \(error)") }
}

// MARK: SMAppService

let agentPlist = "com.gopray.spike.agent.plist"
func runAgentCmd() {
    let svc = SMAppService.agent(plistName: agentPlist)
    switch mode {
    case "register":
        do { try svc.register(); log("register OK status=\(svc.status.rawValue) (\(svc.status))") }
        catch { log("register ERROR \(error) status=\(svc.status.rawValue)") }
    case "unregister":
        do { try svc.unregister(); log("unregister OK status=\(svc.status.rawValue) (\(svc.status))") }
        catch { log("unregister ERROR \(error) status=\(svc.status.rawValue)") }
    default:
        log("status=\(svc.status.rawValue) (\(svc.status))")
    }
}

// agent body: log start, then idle forever
func runAgentBody() {
    let f = "/private/tmp/gopray-spike/agent-starts.log"
    try? FileManager.default.createDirectory(atPath: "/private/tmp/gopray-spike", withIntermediateDirectories: true)
    let line = String(format: "%.3f start pid=%d\n", Date().timeIntervalSince1970, ProcessInfo.processInfo.processIdentifier)
    if let h = FileHandle(forWritingAtPath: f) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() } else { FileManager.default.createFile(atPath: f, contents: line.data(using: .utf8)) }
    signal(SIGTERM) { _ in exit(0) }
    RunLoop.main.run()
}

// MARK: main

switch mode {
case "shield", "webcpu":
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    let d = ShieldApp(); app.delegate = d; app.run()
case "fsapp":
    let app = NSApplication.shared; app.setActivationPolicy(.regular)
    let d = FSApp(); app.delegate = d; app.run()
case "hidetest":
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    let d = HideApp(); app.delegate = d; app.run()
case "audio": runAudio()
case "register", "unregister", "status": runAgentCmd()
case "agentrun": runAgentBody()
case "inject":
    // inject cmd+space | cmdtab:<holdSec> | cmdoptesc | ctrlup | cmdw
    let kind = args.count > 2 ? args[2] : ""
    func post(_ key: Int, down: Bool, flags: CGEventFlags) {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: down)!
        e.flags = flags; e.post(tap: .cghidEventTap)
    }
    let src = kind.split(separator: ":")
    switch src[0] {
    case "cmdspace":
        post(kVK_Command, down: true, flags: .maskCommand); usleep(60_000)
        post(kVK_Space, down: true, flags: .maskCommand); usleep(40_000); post(kVK_Space, down: false, flags: .maskCommand); usleep(60_000)
        post(kVK_Command, down: false, flags: [])
    case "cmdtab":
        let hold = src.count > 1 ? Double(src[1]) ?? 1.0 : 1.0
        post(kVK_Command, down: true, flags: .maskCommand); usleep(80_000)
        post(kVK_Tab, down: true, flags: .maskCommand); post(kVK_Tab, down: false, flags: .maskCommand)
        log("cmd held \(hold)s"); Thread.sleep(forTimeInterval: hold)
        // release without selecting: press Escape would cancel but we avoid Escape; release cmd (switches to previous app)
        post(kVK_Command, down: false, flags: [])
    case "cmdoptesc":
        post(kVK_Command, down: true, flags: .maskCommand); post(kVK_Option, down: true, flags: [.maskCommand, .maskAlternate]); usleep(50_000)
        post(53, down: true, flags: [.maskCommand, .maskAlternate]); post(53, down: false, flags: [.maskCommand, .maskAlternate])
        post(kVK_Option, down: false, flags: .maskCommand); post(kVK_Command, down: false, flags: [])
    case "ctrlup":
        post(kVK_Control, down: true, flags: .maskControl); usleep(60_000)
        post(kVK_UpArrow, down: true, flags: [.maskControl, .maskSecondaryFn]); usleep(40_000); post(kVK_UpArrow, down: false, flags: [.maskControl, .maskSecondaryFn]); usleep(60_000); post(kVK_Control, down: false, flags: [])
    case "cmdw": post(kVK_ANSI_W, down: true, flags: .maskCommand); post(kVK_ANSI_W, down: false, flags: .maskCommand)
    case "hotkey":
        post(kVK_Control, down: true, flags: .maskControl); post(kVK_Option, down: true, flags: [.maskControl, .maskAlternate]); post(kVK_Command, down: true, flags: [.maskControl, .maskAlternate, .maskCommand])
        post(kVK_ANSI_Q, down: true, flags: [.maskControl, .maskAlternate, .maskCommand]); post(kVK_ANSI_Q, down: false, flags: [.maskControl, .maskAlternate, .maskCommand])
        post(kVK_Command, down: false, flags: [.maskControl, .maskAlternate]); post(kVK_Option, down: false, flags: .maskControl); post(kVK_Control, down: false, flags: [])
    default: print("unknown inject")
    }
default:
    print("modes: shield webcpu fsapp hidetest audio register unregister status agentrun inject")
}
