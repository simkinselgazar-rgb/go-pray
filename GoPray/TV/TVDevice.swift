// TVDevice.swift — a TV in Settings, and the one rule for which addresses we will talk to.
// (TV Plan §3, CONTRACT-NOTES #56.) The network code is in TVController.swift; this file has none.

import Foundation

enum TVKind: String, Codable, Sendable { case roku }

struct TVDevice: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var kind: TVKind
    /// An IPv4 literal in a private range (`TVHost`). Never a name.
    var host: String
    /// `dev` = the sideloaded channel. Later the published numeric id. Per TV.
    var channelId: String
    var enabled: Bool
    /// False once a check found no Go Pray app on the TV: shown in Settings, skipped at Athan time.
    var installed: Bool

    static let defaultChannelId = "dev"
    static let maxNameLength = 60, maxChannelIdLength = 32

    init(id: String = UUID().uuidString, name: String, kind: TVKind = .roku, host: String,
         channelId: String = TVDevice.defaultChannelId, enabled: Bool = true, installed: Bool = true) {
        self.id = id; self.name = name; self.kind = kind; self.host = host
        self.channelId = channelId; self.enabled = enabled; self.installed = installed
    }

    /// Tolerant like the other v2 keys: only `id`, `host` and `kind` are needed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        host = try c.decode(String.self, forKey: .host)
        kind = try c.decode(TVKind.self, forKey: .kind)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        channelId = try c.decodeIfPresent(String.self, forKey: .channelId) ?? Self.defaultChannelId
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? true
    }

    /// `dev` (the sideloaded channel) or a published numeric id, nothing else. Never put anything else in a URL path.
    static func isValidChannelId(_ s: String) -> Bool {
        s.range(of: "^(dev|[0-9]{1,10})\\z", options: .regularExpression) != nil
    }
}

/// The ONE address check. Used at save (Settings.sanitized), at send (RokuTV) and for scan results.
enum TVHost {
    /// Four plain decimal numbers 0...255, no spaces, no leading zeros ("010" is refused: some stacks read it as octal).
    static func octets(_ text: String) -> [UInt8]? {
        let bits = text.split(separator: ".", omittingEmptySubsequences: false)
        guard bits.count == 4 else { return nil }
        var out: [UInt8] = []
        for b in bits {
            guard (1...3).contains(b.count), b.allSatisfy({ $0.isASCII && $0.isNumber }),
                  b == "0" || b.first != "0", let n = UInt8(b) else { return nil }
            out.append(n)
        }
        return out
    }

    /// 10/8, 172.16/12, 192.168/16, 169.254/16. Not loopback, not public, not a name.
    static func isAllowed(_ text: String) -> Bool {
        guard let o = octets(text) else { return false }
        switch (o[0], o[1]) {
        case (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}

/// A Roku found by a scan.
struct FoundTV: Equatable, Sendable { var host: String; var name: String }
