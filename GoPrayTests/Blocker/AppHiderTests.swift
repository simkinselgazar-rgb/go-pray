import AppKit
import Testing
@testable import GoPray

// Fakes for NSWorkspace / NSRunningApplication, plus one live test on TextEdit + Calculator
// (apps this test launches itself; Ahmed's real apps are never touched).

@MainActor final class FakeApp: HidableApp {
    let bundleIdentifier: String?
    let localizedName: String?
    var isHidden = false
    var isFinishedLaunching = true
    var hideCalls = 0
    /// How many hide() calls are ignored before one works. Int.max = refuses forever.
    var ignoreHides = 0
    init(_ id: String?, name: String? = nil) { bundleIdentifier = id; localizedName = name ?? id }
    @discardableResult func hide() -> Bool {
        hideCalls += 1
        if !isFinishedLaunching { return false }   // like the real one: no effect mid-launch
        if ignoreHides > 0 { ignoreHides -= 1; return false }
        isHidden = true
        return false   // like the real one: false even on success
    }
}

@MainActor final class FakeWorkspace: RunningApps {
    var runningApps: [any HidableApp] = []
    var handler: (@MainActor (WorkspaceEvent, any HidableApp) -> Void)?
    var observeCount = 0
    var removeCount = 0
    func observe(_ handler: @escaping @MainActor (WorkspaceEvent, any HidableApp) -> Void) -> AnyObject {
        observeCount += 1; self.handler = handler; return NSObject()
    }
    func removeObserver(_ token: AnyObject) { removeCount += 1; handler = nil }
    var observerActive: Bool { handler != nil }
    func fire(_ e: WorkspaceEvent, _ a: FakeApp) { handler?(e, a) }
}

/// Collects scheduled work; `runAll()` plays it in order.
@MainActor final class ManualScheduler {
    var pending: [@MainActor () -> Void] = []
    lazy var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { [unowned self] _, work in self.pending.append(work) }
    func runAll() { while !pending.isEmpty { pending.removeFirst()() } }
}

@MainActor struct AppHiderFixture {
    let ws = FakeWorkspace()
    let sched = ManualScheduler()
    let hider: AppHider
    let ids: Set<String>
    init(ids: Set<String> = ["listed.a", "listed.b"]) {
        self.ids = ids
        hider = AppHider(workspace: ws, retryDelay: 0.1, schedule: sched.schedule)
    }
    func start() { hider.start(hiding: ids) }
}

@MainActor @Suite struct AppHiderTests {
    @Test func startHidesEveryListedRunningApp() {
        let f = AppHiderFixture()
        let a = FakeApp("listed.a"), b = FakeApp("listed.b")
        f.ws.runningApps = [a, b]
        f.start()
        f.sched.runAll()
        #expect(a.isHidden && b.isHidden)
        #expect(a.hideCalls == 1 && b.hideCalls == 1)   // verified hidden, so no retry
    }

    @Test func unlistedAndNoBundleIDAppsAreNeverTouched() {
        let f = AppHiderFixture()
        let other = FakeApp("not.listed"), none = FakeApp(nil)
        f.ws.runningApps = [other, none]
        f.start()
        f.ws.fire(.didActivate, other)
        f.ws.fire(.didLaunch, none)
        f.sched.runAll()
        #expect(other.hideCalls == 0 && none.hideCalls == 0)
    }

    @Test func activationDuringBlockRehidesAndReportsName() {
        let f = AppHiderFixture()
        let a = FakeApp("listed.a", name: "Alpha")
        f.ws.runningApps = [a]
        var names: [String] = []
        f.hider.onReHide = { names.append($0) }
        f.start()
        f.sched.runAll()
        a.isHidden = false                       // he brought it forward
        f.ws.fire(.didActivate, a)
        f.sched.runAll()
        #expect(a.isHidden)
        #expect(names == ["Alpha"])
    }

    @Test func launchDuringBlockIsHiddenToo() {
        let f = AppHiderFixture()
        f.start()
        let b = FakeApp("listed.b", name: "Beta")
        var names: [String] = []
        f.hider.onReHide = { names.append($0) }
        f.ws.fire(.didLaunch, b)
        f.sched.runAll()
        #expect(b.isHidden && names == ["Beta"])
    }

    @Test func initialHideDoesNotFireOnReHide() {
        let f = AppHiderFixture()
        f.ws.runningApps = [FakeApp("listed.a")]
        var fired = 0
        f.hider.onReHide = { _ in fired += 1 }
        f.start()
        f.sched.runAll()
        #expect(fired == 0)
    }

    @Test func hideReturnValueIsNotTrusted() {
        // FakeApp.hide() returns false even on success; isHidden is the truth.
        let f = AppHiderFixture()
        let a = FakeApp("listed.a")
        f.ws.runningApps = [a]
        f.start()
        f.sched.runAll()
        #expect(a.hideCalls == 1)
    }

    @Test func stubbornAppIsRetriedOnceThenLeftAlone() {
        let f = AppHiderFixture()
        let a = FakeApp("listed.a")
        a.ignoreHides = .max
        f.ws.runningApps = [a]
        f.start()
        f.sched.runAll()
        #expect(a.hideCalls == 2)               // first try + one retry, then it moves on
        #expect(!a.isHidden)
    }

    @Test func appStillLaunchingIsHiddenOnceItFinishes() {
        let f = AppHiderFixture()
        f.start()
        let a = FakeApp("listed.a")
        a.isFinishedLaunching = false
        f.ws.fire(.didLaunch, a)
        for _ in 0..<5 { f.sched.pending.removeFirst()() }   // still launching: keeps waiting
        #expect(!a.isHidden)
        a.isFinishedLaunching = true
        f.sched.runAll()
        #expect(a.isHidden)
    }

    @Test func launchWaitIsCapped() {
        let f = AppHiderFixture()
        f.start()
        let a = FakeApp("listed.a")
        a.isFinishedLaunching = false           // never finishes
        f.ws.fire(.didLaunch, a)
        f.sched.runAll()                         // must terminate, not loop forever
        #expect(!a.isHidden && a.hideCalls <= 105)
    }

    @Test func retrySucceedsWhenSecondHideWorks() {
        let f = AppHiderFixture()
        let a = FakeApp("listed.a")
        a.ignoreHides = 1
        f.ws.runningApps = [a]
        f.start()
        f.sched.runAll()
        #expect(a.hideCalls == 2 && a.isHidden)
    }

    @Test func startTwiceObservesOnceAndHidesAgain() {
        let f = AppHiderFixture()
        let a = FakeApp("listed.a")
        f.ws.runningApps = [a]
        f.start()
        f.start()
        f.sched.runAll()
        #expect(f.ws.observeCount == 1)
        #expect(a.isHidden)
    }

    @Test func stopRemovesObserverAndIsSafeTwice() {
        let f = AppHiderFixture()
        f.start()
        f.hider.stop()
        f.hider.stop()
        #expect(f.ws.removeCount == 1)
        #expect(!f.ws.observerActive)
    }

    @Test func eventsAndPendingChecksAfterStopDoNothing() {
        let f = AppHiderFixture()
        let a = FakeApp("listed.a")
        a.ignoreHides = .max
        f.ws.runningApps = [a]
        f.start()                          // schedules a check
        f.hider.stop()
        f.sched.runAll()                         // the pending check must not retry
        #expect(a.hideCalls == 1)
        var fired = 0
        f.hider.onReHide = { _ in fired += 1 }
        f.ws.fire(.didActivate, a)               // observer is gone, handler nil
        #expect(a.hideCalls == 1 && fired == 0)
    }

    @Test func stopDoesNotUnhide() {
        let f = AppHiderFixture()
        let a = FakeApp("listed.a")
        f.ws.runningApps = [a]
        f.start(); f.sched.runAll(); f.hider.stop()
        #expect(a.isHidden)
    }

    @Test func startAgainAfterStopWorks() {
        let f = AppHiderFixture()
        let a = FakeApp("listed.a")
        f.ws.runningApps = [a]
        f.start(); f.hider.stop()
        a.isHidden = false
        f.start(); f.sched.runAll()
        #expect(a.isHidden && f.ws.observeCount == 2)
    }

    @Test func listContainsTheRequiredApps() {
        let required = ["com.anthropic.claudefordesktop", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
                        "com.mitchellh.ghostty", "com.openai.codex", "com.openai.chat", "com.todesktop.230313mzl4w4u92",
                        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.exafunction.windsurf", "dev.zed.Zed",
                        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "org.mozilla.firefox",
                        "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.dia", "com.operasoftware.Opera",
                        "com.vivaldi.Vivaldi"]
        for id in required { #expect(CodingApps.bundleIDs.contains(id), "missing \(id)") }
        #expect(!CodingApps.bundleIDs.contains("com.ahmedelgazar.gopray"))   // never hides itself
        #expect(!CodingApps.bundleIDs.contains("com.apple.finder"))
    }

    @Test func defaultsHaveNoDenylistedIdNoDuplicateAndEveryOneIsNamed() {
        let ids = CodingApps.defaults.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(Set(ids) == CodingApps.bundleIDs)
        #expect(ids.allSatisfy(BlockedApps.isBlockable))
        #expect(CodingApps.defaults.allSatisfy { !$0.name.isEmpty && $0.name.count <= BlockedApps.maxNameLength })
    }

    @Test func hiderHidesExactlyThePassedSetAndNothingElse() {
        let f = AppHiderFixture(ids: ["listed.a"])
        let a = FakeApp("listed.a"), b = FakeApp("listed.b")
        f.ws.runningApps = [a, b]
        f.start()
        #expect(a.hideCalls >= 1 && b.hideCalls == 0)
    }

    @Test func hiderRefusesADenylistedIdEvenIfPassed() {
        let f = AppHiderFixture(ids: ["com.apple.finder", "com.ahmedelgazar.gopray", "listed.a"])
        let finder = FakeApp("com.apple.finder"), me = FakeApp("com.ahmedelgazar.gopray"), a = FakeApp("listed.a")
        f.ws.runningApps = [finder, me, a]
        f.start()
        #expect(finder.hideCalls == 0 && me.hideCalls == 0 && a.hideCalls >= 1)
        f.ws.fire(.didActivate, finder)
        #expect(finder.hideCalls == 0)
    }

    @Test func aNewSetReplacesTheOldOne() {
        let f = AppHiderFixture(ids: ["listed.a"])
        let a = FakeApp("listed.a"), b = FakeApp("listed.b")
        f.ws.runningApps = [a, b]
        f.start()
        f.hider.start(hiding: ["listed.b"])
        #expect(b.hideCalls >= 1)
        let before = a.hideCalls
        f.ws.fire(.didActivate, a)
        #expect(a.hideCalls == before)
    }
}

// MARK: - Live (opt-in, Calculator only)
// Skipped unless GOPRAY_LIVE_TESTS=1 (xcodebuild: TEST_RUNNER_GOPRAY_LIVE_TESTS=1), so normal runs never launch an app.
// TextEdit is never used (a launch with no document opens a file dialog in the user's last folder).

@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["GOPRAY_LIVE_TESTS"] == "1"))
struct AppHiderLiveTests {
    private func pump(_ seconds: TimeInterval, until done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { try? await Task.sleep(for: .milliseconds(25)) }
    }

    private func osascript(_ script: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
        p.waitUntilExit()
    }

    private func calculators() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.calculator")
    }

    @Test func liveHideAndRehideOnCalculator() async throws {
        guard calculators().isEmpty else {
            Issue.record("Calculator already running; live test skipped so it never touches a real window")
            return
        }
        let url = try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.calculator"))
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.hides = true
        cfg.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        // Quits ONLY the Calculator this test launched (none was running before).
        defer { calculators().forEach { $0.terminate() } }

        var reHidden: [String] = []
        let hider = AppHider()
        hider.onReHide = { reHidden.append($0) }
        hider.start(hiding: ["com.apple.calculator"])
        await pump(5) { calculators().first?.isHidden == true }
        #expect(calculators().first?.isHidden == true, "initial hide")

        osascript("tell application \"Calculator\" to activate")
        await pump(3) { !reHidden.isEmpty }
        await pump(3) { calculators().first?.isHidden == true }
        #expect(calculators().first?.isHidden == true, "re-hidden after activation")
        #expect(!reHidden.isEmpty)
        hider.stop()
    }
}
