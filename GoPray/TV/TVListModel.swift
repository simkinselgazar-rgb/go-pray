// TVListModel.swift — the one model behind "your TVs": scan, add, check, test, remove.
// Settings → TVs and the first-run "Play the Athan on your TV?" step both call this, so the
// scan, the address rule and the save path exist once. It has no network code of its own:
// it talks to `TVSending` / `TVDiscovering`, and saves through the caller's `apply`
// (the same `SettingsStore.mutate` path as every other setting).

import Foundation
import Observation

@MainActor @Observable final class TVListModel {
    enum ScanState: Equatable { case idle, scanning, done }
    /// What the last check of a TV said, in the words a person needs.
    enum Status: Equatable { case checking, ready, notInstalled, needsNetworkAccess, notReached }

    static let badAddressLine = "Use your TV's address on your home network, like 192.168.1.20."
    static let duplicateTVLine = "That TV is already on the list."
    static let testSentLine = "Sent. Your TV should open Go Pray."
    static let notInstalledLine = "Go Pray isn't installed on this TV yet"
    static let notInstalledSetupLine = "Go Pray isn't installed on this TV yet. Search 'Go Pray' in the Roku Channel Store."
    static let allowLocalNetworkLine = "Allow Go Pray on your local network: System Settings → Privacy & Security → Local Network"
    static let testFailedLine = "Couldn't reach that TV. Is it on, and on the same Wi-Fi?"

    private(set) var scanState: ScanState = .idle
    /// Rokus the last scan found that are not on the list yet.
    private(set) var foundTVs: [FoundTV] = []
    /// One line per TV after its Test button.
    private(set) var tvTestLines: [String: String] = [:]
    private(set) var testingTV: String?
    /// TVs whose last check was refused by macOS Local Network privacy, and the same for the last scan.
    private(set) var tvsNeedingNetworkAccess: Set<String> = []
    private(set) var scanNeedsNetworkAccess = false
    /// TVs being looked up right now.
    private(set) var checking: Set<String> = []
    @ObservationIgnored private var lastResolution: [String: TVResolution] = [:]

    @ObservationIgnored private let settings: () -> Settings
    @ObservationIgnored private let apply: ((inout Settings) -> Void) -> Bool
    @ObservationIgnored private let notify: (String) -> Void
    @ObservationIgnored private let isBlocked: () -> Bool
    @ObservationIgnored private let nextPrayer: () -> Prayer?
    @ObservationIgnored private let tv: TVSending
    @ObservationIgnored private let discovery: TVDiscovering

    init(settings: @escaping () -> Settings, apply: @escaping ((inout Settings) -> Void) -> Bool,
         notify: @escaping (String) -> Void, isBlocked: @escaping () -> Bool,
         nextPrayer: @escaping () -> Prayer?, tv: TVSending, discovery: TVDiscovering) {
        self.settings = settings; self.apply = apply; self.notify = notify
        self.isBlocked = isBlocked; self.nextPrayer = nextPrayer; self.tv = tv; self.discovery = discovery
    }

    var tvs: [TVDevice] { settings().tvs }

    func scanForTVs() async {
        guard !isBlocked(), scanState != .scanning else { return }
        scanState = .scanning
        let scan = await discovery.scan()
        scanNeedsNetworkAccess = scan.denied
        let known = Set(settings().tvs.map(\.host))
        foundTVs = scan.found.filter { !known.contains($0.host) }
        scanState = .done
    }

    /// Adds a TV by address. The address check is `TVHost`; a bad or repeated one is refused with a line.
    @discardableResult
    func addTV(host: String, name: String) -> Bool {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TVHost.isAllowed(host) else { notify(Self.badAddressLine); return false }
        guard !settings().tvs.contains(where: { $0.host == host }) else { notify(Self.duplicateTVLine); return false }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let added = apply { $0.tvs.append(TVDevice(name: label.isEmpty ? "Roku TV" : label, host: host)) }
        if added { foundTVs.removeAll { $0.host == host } }
        return added
    }

    /// Add, then ask the TV which Go Pray app it has (scan and by-address both go through here).
    func addTVAndCheck(host: String, name: String) async -> Bool {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard addTV(host: h, name: name), let id = settings().tvs.first(where: { $0.host == h })?.id else { return false }
        await refreshTV(id)
        return true
    }

    func addFound(_ found: FoundTV) async { _ = await addTVAndCheck(host: found.host, name: found.name) }

    /// The "Add by address" box: true when the TV was added.
    func addTyped(_ address: String) async -> Bool { await addTVAndCheck(host: address, name: "") }

    /// Looks the Go Pray app up on the TV and stores the result. A TV that can't be reached keeps what it had.
    @discardableResult
    func refreshTV(_ id: String) async -> TVResolution? {
        guard !isBlocked(), let device = settings().tvs.first(where: { $0.id == id }) else { return nil }
        checking.insert(id)
        defer { checking.remove(id) }
        let r = await tv.resolve(device)
        lastResolution[id] = r
        switch r {
        case .found(let ch): _ = apply { s in if let i = s.tvs.firstIndex(where: { $0.id == id }) { s.tvs[i].channelId = ch; s.tvs[i].installed = true } }
        case .notInstalled: _ = apply { s in if let i = s.tvs.firstIndex(where: { $0.id == id }) { s.tvs[i].installed = false } }
        case .unreachable, .localNetworkDenied: break
        }
        if r == .localNetworkDenied { tvsNeedingNetworkAccess.insert(id) } else { tvsNeedingNetworkAccess.remove(id) }
        return r
    }

    /// What to say about a TV after its check.
    func status(of id: String) -> Status {
        if checking.contains(id) { return .checking }
        if tvsNeedingNetworkAccess.contains(id) { return .needsNetworkAccess }
        guard let r = lastResolution[id] else { return .checking }
        switch r {
        case .found: return .ready
        case .notInstalled: return .notInstalled
        case .localNetworkDenied: return .needsNetworkAccess
        case .unreachable: return .notReached
        }
    }

    func removeTV(_ id: String) {
        _ = apply { $0.tvs.removeAll { $0.id == id } }
        tvTestLines[id] = nil
        tvsNeedingNetworkAccess.remove(id)
        lastResolution[id] = nil
    }

    func setTV(_ id: String, enabled: Bool) {
        _ = apply { s in if let i = s.tvs.firstIndex(where: { $0.id == id }) { s.tvs[i].enabled = enabled } }
    }

    func renameTV(_ id: String, to name: String) {
        _ = apply { s in if let i = s.tvs.firstIndex(where: { $0.id == id }) { s.tvs[i].name = name } }
    }

    /// Launches the next prayer, with the current voice, on this one TV. Read-only during a block.
    func testTV(_ id: String) async {
        guard !isBlocked(), settings().tvs.contains(where: { $0.id == id }), testingTV == nil else { return }
        testingTV = id
        defer { testingTV = nil }
        let checked = await refreshTV(id)
        if checked == .notInstalled { tvTestLines[id] = Self.notInstalledLine; return }
        if checked == .localNetworkDenied { tvTestLines[id] = Self.allowLocalNetworkLine; return }
        guard let device = settings().tvs.first(where: { $0.id == id }) else { return }
        do {
            try await tv.test(device, prayer: nextPrayer() ?? .asr, voice: settings().voice)
            tvTestLines[id] = Self.testSentLine
        } catch {
            tvTestLines[id] = (error as? TVError) == .localNetworkDenied ? Self.allowLocalNetworkLine : Self.testFailedLine
        }
    }
}
