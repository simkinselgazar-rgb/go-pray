// BridgeMessage.swift — the JS <-> Swift vocabulary (Architecture Plan C.6). Owner: lane B.
// Pure value code, no WebKit: the validation rules are unit-tested on their own.

import Foundation

/// What the page may ask. Five names, nothing else (`emergency` is the fifth and last, v2).
/// Anything else is dropped.
enum BridgeMessage: String, CaseIterable, Equatable, Sendable {
    case ready, prayed, silence, emergency, gone

    /// The body must be exactly `{ "type": <one of the five> }`. Any other shape,
    /// extra key, wrong type or unknown name is rejected (the caller logs and drops it).
    static func parse(_ body: Any) -> BridgeMessage? {
        guard let dict = body as? [String: Any], dict.count == 1,
              let type = dict["type"] as? String else { return nil }
        return BridgeMessage(rawValue: type)
    }
}

/// Which page layout Swift asks for.
enum ShieldLayout: String, Codable, Equatable, Sendable { case full, notice, art }

/// Swift -> JS: `GoPrayBridge.show(<this as JSON>)`. Built only from enums, ints and bools,
/// plus `hiddenAppName`, which the JSON encoder escapes and bridge.js renders with textContent.
struct BridgePayload: Codable, Equatable, Sendable {
    var prayer: Prayer
    var mode: BlockMode
    var remainingMs: Int
    var athanRemainingMs: Int
    /// Total lock length, so the ring starts at its true progress. 0 = unknown.
    var lockMs: Int
    var reduceMotion: Bool
    var hiddenAppName: String?
    var layout: ShieldLayout
    /// Exits left this year, clamped 0…5. 0 → the page draws no button.
    var emergencyExitsLeft: Int

    static let maxAppNameLength = 60

    init(_ ctx: ShieldContext, layout: ShieldLayout, reduceMotionOverride: Bool? = nil) {
        prayer = ctx.prayer
        mode = ctx.mode
        remainingMs = min(max(ctx.remainingMs, 0), Int(LockPolicy.maxSeconds * 1000))
        athanRemainingMs = min(max(ctx.athanRemainingMs, 0), 60 * 60 * 1000)
        lockMs = min(max(ctx.lockSeconds, 0), Int(LockPolicy.maxSeconds)) * 1000
        reduceMotion = reduceMotionOverride ?? ctx.reduceMotion
        hiddenAppName = ctx.hiddenAppName.map { String($0.prefix(Self.maxAppNameLength)) }
        self.layout = layout
        emergencyExitsLeft = min(max(ctx.emergencyExitsLeft, 0), EmergencyExitPolicy.perYear)
    }

    /// The JS call. The JSON comes from `JSONEncoder`, never from string pasting.
    func showScript() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let json = (try? enc.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        return "GoPrayBridge.show(\(json))"
    }
}
