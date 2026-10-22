// NativeFallbackShield.swift — the shield when the web page is blank, hung or crashed (§E.6, §G).
// Same gate, same button, same remaining time, no web. Owner: lane B.
// Plain on purpose: ground colour, name, countdown, "I prayed", Silence.

import SwiftUI
import AppKit

/// Per-prayer colours from the approved styles.css (`--ground`, `--text`), plus the Nabawi green.
struct ShieldPalette {
    let ground: NSColor
    let text: NSColor
    static let nabawi = NSColor(srgbRed: 0x3e / 255, green: 0x6b / 255, blue: 0x3a / 255, alpha: 1)

    static func hex(_ v: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
    static func of(_ p: Prayer) -> ShieldPalette {
        switch p {
        case .fajr: return .init(ground: hex(0x0e0705), text: hex(0xf2e4cc))
        case .dhuhr: return .init(ground: hex(0xf0eee7), text: hex(0x17232a))
        case .asr: return .init(ground: hex(0xf1ece4), text: hex(0x2d1c0e))
        case .maghrib: return .init(ground: hex(0xf8de9c), text: hex(0x241c0d))
        case .isha: return .init(ground: hex(0x08080f), text: hex(0xede9e1))
        }
    }
}

let prayerNames: [Prayer: (latin: String, arabic: String)] = [
    .fajr: ("Fajr", "الفجر"), .dhuhr: ("Dhuhr", "الظهر"), .asr: ("Asr", "العصر"),
    .maghrib: ("Maghrib", "المغرب"), .isha: ("Isha", "العشاء"),
]

/// What the fallback shows. The controller keeps it in step with the gate's `update`.
@MainActor @Observable final class FallbackModel {
    var prayer: Prayer
    var canConfirmAt: Date
    var athanEndsAt: Date?
    var accepting = false
    var hiddenAppName: String?
    var onPrayed: () -> Void = {}
    var onSilence: () -> Void = {}

    init(_ ctx: ShieldContext, now: Date = Date()) {
        prayer = ctx.prayer
        canConfirmAt = now.addingTimeInterval(Double(ctx.remainingMs) / 1000)
        athanEndsAt = ctx.athanRemainingMs > 0 ? now.addingTimeInterval(Double(ctx.athanRemainingMs) / 1000) : nil
        hiddenAppName = ctx.hiddenAppName
    }

    func apply(_ ctx: ShieldContext, now: Date = Date()) {
        prayer = ctx.prayer
        canConfirmAt = now.addingTimeInterval(Double(ctx.remainingMs) / 1000)
        athanEndsAt = ctx.athanRemainingMs > 0 ? now.addingTimeInterval(Double(ctx.athanRemainingMs) / 1000) : nil
        hiddenAppName = ctx.hiddenAppName
    }
}

struct NativeFallbackShield: View {
    let model: FallbackModel

    var body: some View {
        let pal = ShieldPalette.of(model.prayer)
        let ink = Color(nsColor: pal.text)
        TimelineView(.periodic(from: .now, by: 1)) { tl in
            let left = max(0, Int(ceil(model.canConfirmAt.timeIntervalSince(tl.date))))
            let athanOn = (model.athanEndsAt ?? .distantPast) > tl.date
            ZStack {
                Color(nsColor: pal.ground)
                VStack(spacing: 14) {
                    Text(prayerNames[model.prayer]?.latin ?? "")
                        .font(.system(size: 44, weight: .regular, design: .serif))
                    Text(prayerNames[model.prayer]?.arabic ?? "")
                        .font(.custom("Amiri", size: 34))
                        .environment(\.layoutDirection, .rightToLeft)
                    Text(model.hiddenAppName.map { "\($0.prefix(40)) is resting until you pray." } ?? "Time to pray. Your work will be right here.")
                        .font(.system(size: 15))
                        .opacity(0.8)
                        .padding(.top, 6)
                    Text(String(format: "%d:%02d", left / 60, left % 60))
                        .font(.system(size: 40, weight: .light, design: .serif).monospacedDigit())
                        .padding(.vertical, 12)
                        .accessibilityLabel(left > 0 ? "\(left / 60) minutes \(left % 60) seconds until you can confirm" : "You can confirm now")
                    Button { model.onPrayed() } label: {
                        Text("I prayed")
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 200, height: 40)
                            .foregroundStyle(left == 0 ? Color.white : ink.opacity(0.45))
                            .background(RoundedRectangle(cornerRadius: 10).fill(left == 0 ? Color(nsColor: ShieldPalette.nabawi) : ink.opacity(0.07)))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(ink.opacity(0.22), lineWidth: left == 0 ? 0 : 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(left > 0)
                    if athanOn {
                        Button("Athan playing · Silence") { model.onSilence() }
                            .buttonStyle(.plain)
                            .font(.system(size: 13))
                            .opacity(0.7)
                            .padding(.top, 4)
                    }
                }
                .foregroundStyle(ink)
                .opacity(model.accepting ? 0 : 1)
                .animation(.easeOut(duration: 0.2), value: model.accepting)
                Text("May Allah accept it.")
                    .font(.system(size: 28, weight: .regular, design: .serif))
                    .foregroundStyle(ink)
                    .opacity(model.accepting ? 1 : 0)
                    .animation(.easeOut(duration: 0.3), value: model.accepting)
            }
        }
        .ignoresSafeArea()
    }
}
