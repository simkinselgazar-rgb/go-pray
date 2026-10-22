// ShieldPanel.swift — one non-activating panel per display. Owner: lane B.
// Spike §1: level .screenSaver is enough; canJoinAllSpaces + canJoinAllApplications +
// fullScreenAuxiliary + stationary covers a full-screen app's Space, Spotlight and Mission Control.

import AppKit

@MainActor final class ShieldPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Spike bug 1: `NSPanel(contentRect:screen:)` treats the rect as screen-relative and doubles
    /// the origin on other displays. So: create anywhere, then `setFrame` with the GLOBAL frame.
    init(globalFrame: NSRect, level: NSWindow.Level, ground: NSColor) {
        super.init(contentRect: NSRect(origin: .zero, size: globalFrame.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isOpaque = true
        backgroundColor = ground          // the skeleton: the ground colour is up before the page is
        hasShadow = false
        animationBehavior = .none
        isMovable = false
        setFrame(globalFrame, display: true)
    }
}
