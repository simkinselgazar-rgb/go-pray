// ShieldController.swift — ShieldPresenting: one panel per display, presentation options,
// re-activation, the web page, the native fallback, "May Allah accept it." Owner: lane B.
//
// The shield never ends a block. `prayed` from the page only becomes
// `delegate.shieldDidRequestConfirm()`; the gate decides and answers with show/update/dismiss.
// Rule 1 (never trap): every failure of the web side swaps in the native fallback with the
// same gate and the same remaining time. `tearDown()` works from any state.

import AppKit
import SwiftUI
import os

private let log = Logger(subsystem: "com.ahmedelgazar.gopray", category: "shield")

@MainActor final class ShieldController: NSObject, ShieldPresenting {
    struct Display: Equatable { var id: UInt32; var frame: NSRect }

    @MainActor struct Options {
        var level: NSWindow.Level = .screenSaver
        var activate = true
        /// nil = leave them alone (tests).
        var presentationOptions: NSApplication.PresentationOptions? =
            [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit, .disableHideApplication]
        /// First display is the primary one (the one with the menu bar).
        var displays: @MainActor () -> [Display] = ShieldController.liveDisplays
        var scenesRoot: URL = SceneWebView.bundledScenesRoot
        var orderFront = true
        var readyTimeout: Duration = .seconds(4)
        /// If the page never says `gone`, finish anyway (the gate gives up at 4 s).
        var goneTimeout: Duration = .seconds(2.5)
        var fallbackAcceptHold: Duration = .seconds(1)
        var fadeSeconds: Double = 0.3
        /// Spike bug 2: re-activate at most once per interval.
        var reactivateInterval: Duration = .milliseconds(250)
    }

    @MainActor final class Slot {
        let display: Display
        let layout: ShieldLayout
        let panel: ShieldPanel
        var web: SceneWebView?
        var fallback: FallbackModel?
        var ready = false
        var readyTask: Task<Void, Never>?
        var shownAt = ContinuousClock.now
        var shownRemainingMs = 0
        var shownApp: String?
        var athanActive = false
        var needsReshow = false
        var isMain: Bool { layout != .art }
        var fellBack: Bool { web == nil }
        init(display: Display, layout: ShieldLayout, panel: ShieldPanel) { self.display = display; self.layout = layout; self.panel = panel }
    }

    weak var delegate: ShieldDelegate?
    var options: Options
    private(set) var slots: [Slot] = []
    private(set) var isPresenting = false
    private(set) var isDismissing = false
    /// Why the last web slot fell back (tests and logs).
    private(set) var fallbackReasons: [String] = []

    private var ctx: ShieldContext?
    private var ctxAt = ContinuousClock.now
    private var epoch = 0
    private var dismissCompletion: (() -> Void)?
    private var dismissKind: EndKind = .confirmed
    private var dismissTask: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?
    private var reactivateTask: Task<Void, Never>?
    private var lastReactivate = ContinuousClock.now - .seconds(10)
    private var appliedPresentation = false

    init(options: Options = Options()) {
        self.options = options
        super.init()
    }

    static func liveDisplays() -> [Display] {
        NSScreen.screens.map {
            Display(id: ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0, frame: $0.frame)
        }
    }

    // MARK: ShieldPresenting

    func show(_ ctx: ShieldContext) {
        if isPresenting {
            if self.ctx?.prayer == ctx.prayer && !isDismissing { update(ctx); return }
            tearDown()   // a different prayer replaces the old one; nothing stacks
        }
        isPresenting = true
        self.ctx = ctx
        ctxAt = .now
        build()
        engage()
    }

    func update(_ ctx: ShieldContext) {
        guard isPresenting, !isDismissing else { return }
        let hiddenChanged = self.ctx?.hiddenAppName != ctx.hiddenAppName
        self.ctx = ctx
        ctxAt = .now
        for slot in slots {
            if let model = slot.fallback { model.apply(ctx); continue }
            guard slot.ready, slot.web != nil, slot.layout != .art else { continue }
            let elapsedMs = Int((ContinuousClock.now - slot.shownAt) / .milliseconds(1))
            let pageThinks = slot.shownRemainingMs - elapsedMs
            if slot.needsReshow || abs(pageThinks - ctx.remainingMs) > 1500 || (hiddenChanged && slot.shownApp != ctx.hiddenAppName) {
                sendShow(slot)
                if slot.layout == .notice && hiddenChanged && options.orderFront { slot.panel.orderFrontRegardless() }
            } else if slot.athanActive && ctx.athanRemainingMs == 0 {
                slot.athanActive = false
                slot.web?.athanStopped()
            }
        }
    }

    func dismiss(kind: EndKind, thenIdle: @escaping () -> Void) {
        guard isPresenting else { thenIdle(); return }
        if isDismissing { dismissCompletion = thenIdle; return }
        isDismissing = true
        dismissCompletion = thenIdle
        for slot in slots {
            if slot.fellBack { if slot.isMain { slot.fallback?.beginLeaving(kind) } }
            else { slot.web?.dismissPage(kind: kind) }
        }
        dismissKind = kind
        armDismissTimer()
    }

    func tearDown() {
        dismissTask?.cancel(); rebuildTask?.cancel(); reactivateTask?.cancel()
        dismissTask = nil; rebuildTask = nil; reactivateTask = nil
        dismissCompletion = nil
        isDismissing = false
        isPresenting = false
        epoch += 1
        closeAll()
        disengage()
        ctx = nil
    }

    // MARK: Building

    private func background(for ctx: ShieldContext) -> NSColor { ShieldPalette.of(ctx.prayer).ground }

    /// `ctx` with the time that has passed since it arrived taken off (rebuilds, fallbacks).
    private func adjusted() -> ShieldContext? {
        guard var c = ctx else { return nil }
        let ms = Int((ContinuousClock.now - ctxAt) / .milliseconds(1))
        c.remainingMs = max(0, c.remainingMs - ms)
        c.athanRemainingMs = max(0, c.athanRemainingMs - ms)
        return c
    }

    private func build() {
        guard let ctx else { return }
        let displays = options.displays()
        let ground = background(for: ctx)
        var made: [Slot] = []
        if ctx.mode == .codingApps {
            if let primary = displays.first {
                let panel = ShieldPanel(globalFrame: CodingNoticePanel.frame(on: primary.frame), level: options.level, ground: ground)
                made.append(Slot(display: primary, layout: .notice, panel: panel))
            }
        } else {
            for (i, d) in displays.enumerated() {
                let panel = ShieldPanel(globalFrame: d.frame, level: options.level, ground: ground)
                made.append(Slot(display: d, layout: i == 0 ? .full : .art, panel: panel))
            }
        }
        slots = made
        for slot in slots { attachWeb(slot) }
        if ctx.mode == .codingApps, let s = slots.first { CodingNoticePanel.style(s.panel) }
    }

    private func attachWeb(_ slot: Slot) {
        guard let ctx else { return }
        let web = SceneWebView(scenesRoot: options.scenesRoot, underPage: background(for: ctx))
        web.frame = NSRect(origin: .zero, size: slot.panel.frame.size)
        web.autoresizingMask = [.width, .height]
        web.onMessage = { [weak self, weak slot] msg in
            guard let self, let slot else { return }
            self.handle(msg, from: slot)
        }
        web.onFailure = { [weak self, weak slot] failure in
            guard let self, let slot else { return }
            self.fallBack(slot, reason: String(describing: failure))
        }
        slot.web = web
        slot.panel.contentView = web
        web.load()
        let myEpoch = epoch
        slot.readyTask = Task { [weak self, weak slot] in
            try? await Task.sleep(for: self?.options.readyTimeout ?? .seconds(4))
            guard !Task.isCancelled, let self, let slot, self.epoch == myEpoch, !slot.ready, !slot.fellBack else { return }
            self.fallBack(slot, reason: "ready timeout")
        }
    }

    private func sendShow(_ slot: Slot) {
        guard let c = adjusted(), let web = slot.web else { return }
        let payload = BridgePayload(c, layout: slot.layout, reduceMotionOverride: slot.layout == .full ? nil : true)
        slot.shownAt = .now
        slot.shownRemainingMs = c.remainingMs
        slot.shownApp = c.hiddenAppName
        slot.athanActive = c.athanRemainingMs > 0
        slot.needsReshow = false
        web.show(payload)
    }

    // MARK: Messages from the page

    private func handle(_ msg: BridgeMessage, from slot: Slot) {
        switch msg {
        case .ready:
            slot.ready = true
            slot.readyTask?.cancel()
            sendShow(slot)
        case .prayed:
            guard slot.isMain, isPresenting, !isDismissing else { return }
            // The page may be ahead of the gate. If the gate refuses it calls `update`, and this
            // flag makes that update rebuild the page with the true remaining time.
            slot.needsReshow = true
            delegate?.shieldDidRequestConfirm()
        case .silence:
            guard slot.isMain, isPresenting, !isDismissing else { return }
            delegate?.shieldDidRequestSilence()
        case .emergency:
            guard slot.isMain, isPresenting, !isDismissing else { return }
            // Like `prayed`: if the gate refuses, its `update` rebuilds the page with the true count.
            slot.needsReshow = true
            delegate?.shieldDidRequestEmergencyExit()
        case .gone:
            if isDismissing, slot.isMain { finishDismiss() }
        }
    }

    // MARK: Fallback (rule 1: never trap)

    func fallBack(_ slot: Slot, reason: String) {
        guard isPresenting, slot.web != nil else { return }
        log.error("web shield failed (\(reason, privacy: .public)); native fallback")
        fallbackReasons.append(reason)
        slot.readyTask?.cancel()
        slot.web?.shutDown()
        slot.web?.removeFromSuperview()
        slot.web = nil
        guard let c = adjusted() else { return }
        if slot.isMain {
            let model = FallbackModel(c)
            model.onPrayed = { [weak self] in
                guard let self, self.isPresenting, !self.isDismissing else { return }
                self.delegate?.shieldDidRequestConfirm()
            }
            model.onSilence = { [weak self] in
                guard let self, self.isPresenting, !self.isDismissing else { return }
                self.delegate?.shieldDidRequestSilence()
            }
            model.onEmergency = { [weak self] in
                guard let self, self.isPresenting, !self.isDismissing else { return }
                self.delegate?.shieldDidRequestEmergencyExit()
            }
            slot.fallback = model
            let host = NSHostingView(rootView: NativeFallbackShield(model: model))
            host.frame = NSRect(origin: .zero, size: slot.panel.frame.size)
            host.autoresizingMask = [.width, .height]
            slot.panel.contentView = host
            if slot.layout == .notice { CodingNoticePanel.style(slot.panel) }
            if isDismissing { model.beginLeaving(dismissKind); armDismissTimer() }
        } else {
            let plain = NSView(frame: NSRect(origin: .zero, size: slot.panel.frame.size))
            plain.wantsLayer = true
            plain.layer?.backgroundColor = background(for: c).cgColor
            plain.autoresizingMask = [.width, .height]
            slot.panel.contentView = plain
        }
    }

    // MARK: Dismiss

    private func armDismissTimer() {
        dismissTask?.cancel()
        let mainFell = slots.contains { $0.isMain && $0.fellBack }
        let wait = mainFell ? options.fallbackAcceptHold : options.goneTimeout
        let myEpoch = epoch
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, self.epoch == myEpoch else { return }
            self.finishDismiss()
        }
    }

    private func finishDismiss() {
        guard isDismissing, let done = dismissCompletion else { return }
        dismissCompletion = nil
        dismissTask?.cancel(); dismissTask = nil
        let myEpoch = epoch
        let complete: @MainActor () -> Void = { [weak self] in
            guard let self, self.epoch == myEpoch else { return }
            self.tearDown()      // also resets presentation options
            done()
        }
        let seconds = options.fadeSeconds
        if seconds <= 0 || !options.orderFront { complete(); return }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = seconds
            for s in slots { s.panel.animator().alphaValue = 0 }
        }, completionHandler: { MainActor.assumeIsolated { complete() } })
    }

    private func closeAll() {
        NotificationCenter.default.removeObserver(self)
        for slot in slots {
            slot.readyTask?.cancel()
            slot.web?.shutDown()
            slot.panel.contentView = nil
            slot.panel.orderOut(nil)
            slot.panel.close()
        }
        slots = []
    }

    // MARK: Showing, activation, presentation options, displays

    private func engage() {
        let wholeScreen = ctx?.mode == .wholeScreen
        if options.orderFront { for s in slots { s.panel.orderFrontRegardless() } }
        if wholeScreen {
            if options.activate { activateNow() }
            if let opts = options.presentationOptions { NSApp.presentationOptions = opts; appliedPresentation = true }
            NotificationCenter.default.addObserver(self, selector: #selector(didResignActive),
                                                   name: NSApplication.didResignActiveNotification, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private func disengage() {
        if appliedPresentation { NSApp.presentationOptions = []; appliedPresentation = false }
    }

    private func activateNow() {
        lastReactivate = .now
        NSApp.activate(ignoringOtherApps: true)
        slots.first(where: { $0.isMain })?.panel.makeKeyAndOrderFront(nil)
        if appliedPresentation, let opts = options.presentationOptions { NSApp.presentationOptions = opts }
    }

    /// Spike bug 2: re-activating on every resign ping-pongs (~15 pairs in 500 ms). Only when the
    /// frontmost app is not us, and at most once per interval (a trailing call catches the last one).
    @objc private func didResignActive(_ note: Notification) { reactivateIfNeeded() }

    func reactivateIfNeeded() {
        guard isPresenting, !isDismissing, ctx?.mode == .wholeScreen, options.activate else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        let since = ContinuousClock.now - lastReactivate
        if since >= options.reactivateInterval { activateNow(); return }
        guard reactivateTask == nil else { return }
        let wait = options.reactivateInterval - since
        let myEpoch = epoch
        reactivateTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, self.epoch == myEpoch else { return }
            self.reactivateTask = nil
            self.reactivateIfNeeded()
        }
    }

    @objc private func screensChanged(_ note: Notification) { displaysChanged() }

    /// Panels are rebuilt from the current displays; a panel that cannot be made is just missing
    /// (the main panel and the gate still hold the block).
    func displaysChanged() {
        guard isPresenting, !isDismissing else { return }
        rebuildTask?.cancel()
        let myEpoch = epoch
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, self.epoch == myEpoch, self.isPresenting, !self.isDismissing else { return }
            let now = self.options.displays()
            let same = now == self.slots.map(\.display) || (self.ctx?.mode == .codingApps && now.first == self.slots.first?.display)
            if same { return }
            guard let c = self.adjusted() else { return }
            self.closeAll()
            self.ctx = c
            self.ctxAt = .now
            self.build()
            self.engage()
        }
    }
}
