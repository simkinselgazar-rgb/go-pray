// BlockState.swift — the state.json shape, schema v1 (§C.2). Owner: PM.
// Only Core reads or writes this file. Decoding is strict: an unknown
// schemaVersion, an unknown prayer or a missing required field throws, and
// StateStore turns that into "corrupt → idle".

import Foundation

struct BlockStateFile: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    struct Block: Codable, Equatable, Sendable {
        var prayer: Prayer
        var athanAt: Date
        var blockStartedAt: Date
        var silenced: Bool
        var athanPlayed: Bool
        /// The lock this block uses, copied from `Settings.lockMinutes` at block
        /// start (CONTRACT-NOTES #26). Missing in a file → the default 10 min.
        /// The gate never honours more than `LockPolicy.maxSeconds`.
        var lockSeconds: TimeInterval
        #if DEBUG
        /// DEBUG only: the synthetic window end of a "Trigger Athan now" block (athan = trigger
        /// time), so a relaunch resumes it like a real block instead of failing it open.
        /// Not in Release builds (the key does not exist there; a stray key is ignored).
        var debugWindowEnd: Date?
        #endif

        init(prayer: Prayer, athanAt: Date, blockStartedAt: Date, silenced: Bool, athanPlayed: Bool,
             lockSeconds: TimeInterval = LockPolicy.seconds(forMinutes: LockPolicy.defaultMinutes)) {
            self.prayer = prayer
            self.athanAt = athanAt
            self.blockStartedAt = blockStartedAt
            self.silenced = silenced
            self.athanPlayed = athanPlayed
            self.lockSeconds = lockSeconds
        }

        enum CodingKeys: String, CodingKey {
            case prayer, athanAt, blockStartedAt, silenced, athanPlayed, lockSeconds
            #if DEBUG
            case debugWindowEnd
            #endif
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(prayer: try c.decode(Prayer.self, forKey: .prayer),
                      athanAt: try c.decode(Date.self, forKey: .athanAt),
                      blockStartedAt: try c.decode(Date.self, forKey: .blockStartedAt),
                      silenced: try c.decode(Bool.self, forKey: .silenced),
                      athanPlayed: try c.decode(Bool.self, forKey: .athanPlayed),
                      lockSeconds: try c.decodeIfPresent(TimeInterval.self, forKey: .lockSeconds)
                          ?? LockPolicy.seconds(forMinutes: LockPolicy.defaultMinutes))
            #if DEBUG
            debugWindowEnd = try c.decodeIfPresent(Date.self, forKey: .debugWindowEnd)
            #endif
        }
    }

    /// A prayer that is finished for the gate. `lastConfirmed` = "I prayed".
    /// `lastDropped` = given up by a fail-open rule while its window was still
    /// open (crash loop, corrupt file), so it is not blocked again.
    /// `lastDropped` is an additive v1 field (CONTRACT-NOTES #5).
    struct Done: Codable, Equatable, Sendable {
        var prayer: Prayer
        var athanAt: Date
    }

    var schemaVersion: Int = currentSchemaVersion
    var block: Block?
    var lastConfirmed: Done?
    var lastDropped: Done?
    /// Launch times while `block != nil`, newest last, at most 5. Crash-loop guard.
    var launches: [Date] = []

    init(block: Block? = nil, lastConfirmed: Done? = nil, lastDropped: Done? = nil, launches: [Date] = []) {
        self.block = block
        self.lastConfirmed = lastConfirmed
        self.lastDropped = lastDropped
        self.launches = launches
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, block, lastConfirmed, lastDropped, launches }

    struct UnsupportedVersion: Error { let found: Int }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else { throw UnsupportedVersion(found: version) }
        schemaVersion = version
        block = try c.decodeIfPresent(Block.self, forKey: .block)
        lastConfirmed = try c.decodeIfPresent(Done.self, forKey: .lastConfirmed)
        lastDropped = try c.decodeIfPresent(Done.self, forKey: .lastDropped)
        launches = try c.decodeIfPresent([Date].self, forKey: .launches) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(block, forKey: .block)              // explicit null when idle
        try c.encodeIfPresent(lastConfirmed, forKey: .lastConfirmed)
        try c.encodeIfPresent(lastDropped, forKey: .lastDropped)
        try c.encode(launches, forKey: .launches)
    }

    /// The latest Athan the gate treats as finished. Prayers come in order, so
    /// any window whose Athan is at or before this one is not blocked again
    /// (this also covers the clock going back over a confirmed prayer).
    var latestDoneAthan: Date? {
        [lastConfirmed?.athanAt, lastDropped?.athanAt].compactMap { $0 }.max()
    }
}

// MARK: - JSON coding (ISO 8601 with fractional seconds, so a resumed block keeps its exact start)

extension BlockStateFile {
    static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(Self.fractional))
        }
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = try? Date(s, strategy: Self.fractional) {
                return date
            }
            if let date = try? Date(s, strategy: .iso8601) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(s)")
        }
        return d
    }
}
