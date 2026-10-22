// CodingNoticePanel.swift — coding-apps mode: a 420 x 520 panel centred on the main display
// (PM redesign 2026-10-22): the scene still as a band across the top with no text on it, then the
// prayer's ground colour with name, one line, a small ring, "I prayed". Same web page, `layout: "notice"`. Owner: lane B.
// The panel never activates the app and never touches presentation options: the person
// keeps working in every other app.

import AppKit

@MainActor enum CodingNoticePanel {
    static let size = NSSize(width: 420, height: 520)
    static let cornerRadius: CGFloat = 14

    static func frame(on display: NSRect) -> NSRect {
        NSRect(x: display.midX - size.width / 2, y: display.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Round the panel's content (the window shadow follows the opaque shape).
    static func style(_ panel: ShieldPanel) {
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        if let v = panel.contentView {
            v.wantsLayer = true
            v.layer?.cornerRadius = cornerRadius
            v.layer?.masksToBounds = true
        }
    }
}
