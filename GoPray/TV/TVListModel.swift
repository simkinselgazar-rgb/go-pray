// TVListModel.swift — the one model behind "your TVs": scan, add, check, test, remove.
// Settings → TVs and the first-run "Play the Athan on your TV?" step both call this, so the
// scan, the address rule and the save path exist once. It has no network code of its own:
// it talks to `TVSending` / `TVDiscovering`, and saves through the caller's `apply`
// (the same `SettingsStore.mutate` path as every other setting).

import Foundation
import Observation

/// What the Google TV "Pair remote" action needs from the controller (`TVController.pairRemote`, wired by the PM).
/// Kept out of `TVSending` so a fake sender needs no change; a sender that does not conform simply cannot pair.
protocol TVRemotePairing: Sendable {
    /// Step 1: the TV shows its 6-character code once this returns true.
    func startRemotePairing(_ tv: TVDevice) async throws -> Bool
    /// Step 2: the typed code finishes the pairing the first step started.
    func pairRemote(_ tv: TVDevice, code: String) async throws -> TVPairResult
}

@MainActor @Observable final class TVListModel {
    enum ScanState: Equatable { case idle, scanning, done }
    /// What the last check of a TV said, in the words a person needs.
    enum Status: Equatable { case checking, ready, notInstalled, needsNetworkAccess, notReached }
    /// Samsung only: where pairing stands for a TV.
    enum TokenState: Equatable { case paired, notPaired, basicLaunchOnly, pairAgain }

    static let badAddressLine = "Use your TV's address on your home network, like 192.168.1.20."
    static let duplicateTVLine = "That TV is already on the list."
    static let testSentLine = "Sent. Your TV should open Go Pray."
    static let notInstalledLine = "Go Pray isn't installed on this TV yet"
    static let notInstalledSetupLine = "Go Pray isn't installed on this TV yet. Search 'Go Pray' in the Roku Channel Store."
    static let allowLocalNetworkLine = "Allow Go Pray on your local network: System Settings → Privacy & Security → Local Network"
    static let testFailedLine = "Couldn't reach that TV. Is it on, and on the same Wi-Fi?"
    static let allowOnTVLine = "Allow Go Pray on the TV when it asks."
    static let pairedLine = "Paired."
    static let pairDeniedLine = "The TV said no. Press Pair and choose Allow."
    static let basicLaunchLine = "This TV only supports the basic launch; the voice is picked on the TV"
    static let pairAgainLine = "The TV's security certificate changed. Press Pair to set it up again."
    static let remoteWrongCodeLine = "That code didn't match. Try again."
    static let remoteTimedOutLine = "Pairing timed out. Press Pair remote again."
    static let remoteNoAnswerLine = "The TV did not answer"
    static let remotePairedHelp = "Turns the TV back off after the Athan if it was off."
    static let remoteNotPairedHelp = "Pair remote to turn the TV back off"
    static let remoteForgetHelp = "To fully unpair, also remove Go Pray on the TV: Settings → Remotes & Accessories."
    static let tvOffLine = "That TV is off. Turn it on, then try again."

    private(set) var scanState: ScanState = .idle
    /// Rokus the last scan found that are not on the list yet.
    private(set) var foundTVs: [FoundTV] = []
    /// One line per TV after its Test button.
    private(set) var tvTestLines: [String: String] = [:]
    private(set) var testingTV: String?
    private(set) var pairingTV: String?
    /// Google TV: the remote code is being checked right now.
    private(set) var remotePairingTV: String?
    /// Samsung TVs with a stored credential, TVs that said they only do the basic launch, TVs whose certificate changed.
    private(set) var pairedTVs: Set<String> = []
    private(set) var basicLaunchOnlyTVs: Set<String> = []
    private(set) var pairAgainTVs: Set<String> = []
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
    func addTV(host: String, name: String, kind: TVKind = .roku) -> Bool {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TVHost.isAllowed(host) else { notify(Self.badAddressLine); return false }
        guard !settings().tvs.contains(where: { $0.host == host }) else { notify(Self.duplicateTVLine); return false }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let added = apply { $0.tvs.append(TVDevice(name: label.isEmpty ? kind.defaultName : label, kind: kind, host: host)) }
        if added { foundTVs.removeAll { $0.host == host } }
        return added
    }

    /// Add, then ask the TV which Go Pray app it has (scan and by-address both go through here).
    func addTVAndCheck(host: String, name: String, kind: TVKind = .roku) async -> Bool {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard addTV(host: h, name: name, kind: kind), let id = settings().tvs.first(where: { $0.host == h })?.id else { return false }
        await refreshTV(id)
        return true
    }

    func addFound(_ found: FoundTV) async { _ = await addTVAndCheck(host: found.host, name: found.name, kind: found.kind) }

    /// The "Add by address" box: true when the TV was added.
    func addTyped(_ address: String, kind: TVKind = .roku) async -> Bool { await addTVAndCheck(host: address, name: "", kind: kind) }

    /// Looks the Go Pray app up on the TV and stores the result. A TV that can't be reached keeps what it had.
    @discardableResult
    func refreshTV(_ id: String) async -> TVResolution? {
        guard !isBlocked(), let device = settings().tvs.first(where: { $0.id == id }) else { return nil }
        checking.insert(id)
        defer { checking.remove(id) }
        let r = await tv.resolve(device)
        lastResolution[id] = r
        loadTokenState(id)
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
        let gone = settings().tvs.first { $0.id == id }
        let removed = apply { $0.tvs.removeAll { $0.id == id } }
        if removed, let gone { tv.forget(gone) }                    // the credential goes with the TV
        pairedTVs.remove(id); basicLaunchOnlyTVs.remove(id); pairAgainTVs.remove(id)
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

    // MARK: Pairing (Samsung)

    /// Reads the stored-credential state for one TV (cheap; called after a check and when a row appears).
    func loadTokenState(_ id: String) {
        guard let device = settings().tvs.first(where: { $0.id == id }), device.kind == .samsung else { return }
        if tv.isPaired(device) { pairedTVs.insert(id) } else { pairedTVs.remove(id) }
    }

    func tokenState(of id: String) -> TokenState {
        if pairAgainTVs.contains(id) { return .pairAgain }
        if pairedTVs.contains(id) { return .paired }
        return basicLaunchOnlyTVs.contains(id) ? .basicLaunchOnly : .notPaired
    }

    /// The Pair button. The only thing that makes a TV show its Allow box.
    func pairTV(_ id: String) async {
        guard !isBlocked(), let device = settings().tvs.first(where: { $0.id == id }), device.kind == .samsung,
              testingTV == nil, pairingTV == nil else { return }
        pairingTV = id
        defer { pairingTV = nil }
        tvTestLines[id] = Self.allowOnTVLine
        do {
            switch try await tv.pair(device) {
            case .paired:
                pairedTVs.insert(id); basicLaunchOnlyTVs.remove(id); pairAgainTVs.remove(id)
                tvTestLines[id] = Self.pairedLine
            case .denied: tvTestLines[id] = Self.pairDeniedLine
            case .unsupported: basicLaunchOnlyTVs.insert(id); tvTestLines[id] = Self.basicLaunchLine
            case .notNeeded: tvTestLines[id] = nil
            }
        } catch {
            switch error as? TVError {
            case .certChanged?: pairAgainTVs.insert(id); tvTestLines[id] = Self.pairAgainLine
            case .localNetworkDenied?: tvTestLines[id] = Self.allowLocalNetworkLine
            default: tvTestLines[id] = Self.testFailedLine
            }
        }
    }

    // MARK: Pairing the remote (Google TV)

    /// The one line under a Google TV row about turning it back off.
    func remoteHelp(for tv: TVDevice) -> String { tv.remotePaired ? Self.remotePairedHelp : Self.remoteNotPairedHelp }

    /// How the code sheet should end: closed with a pairing, kept open for another try, or closed with a line on the row.
    enum RemotePairOutcome: Equatable { case paired, tryAgain, closed }

    /// Step 1, the "Pair remote" button: the TV shows its code only after this handshake starts. True = show the sheet.
    /// False = one line on the row says why.
    func startRemotePairing(_ id: String) async -> Bool {
        guard !isBlocked(), let device = settings().tvs.first(where: { $0.id == id }), device.kind == .googleTV,
              testingTV == nil, remotePairingTV == nil else { return false }
        guard let remote = tv as? TVRemotePairing else { tvTestLines[id] = Self.remoteNoAnswerLine; return false }
        remotePairingTV = id
        defer { remotePairingTV = nil }
        do {
            if try await remote.startRemotePairing(device) { tvTestLines[id] = nil; return true }
            tvTestLines[id] = Self.remoteNoAnswerLine
        } catch {
            tvTestLines[id] = (error as? TVError) == .localNetworkDenied ? Self.allowLocalNetworkLine : Self.remoteNoAnswerLine
        }
        return false
    }

    /// Step 2, the sheet's Pair button. The code is trimmed, upper-cased, hex only; any other shape is "didn't match"
    /// without asking the TV. A wrong code starts a fresh handshake (the TV shows a new code) and keeps the sheet open.
    func pairRemote(_ id: String, code rawCode: String) async -> RemotePairOutcome {
        guard !isBlocked(), let device = settings().tvs.first(where: { $0.id == id }), device.kind == .googleTV,
              testingTV == nil, remotePairingTV == nil else { return .closed }
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            tvTestLines[id] = Self.remoteWrongCodeLine; return .tryAgain
        }
        guard let remote = tv as? TVRemotePairing else { tvTestLines[id] = Self.remoteNoAnswerLine; return .closed }
        remotePairingTV = id
        defer { remotePairingTV = nil }
        do {
            switch try await remote.pairRemote(device, code: code) {
            case .paired:
                _ = apply { s in if let i = s.tvs.firstIndex(where: { $0.id == id }) { s.tvs[i].remotePaired = true } }
                tvTestLines[id] = Self.pairedLine
                return .paired
            case .denied:
                tvTestLines[id] = Self.remoteWrongCodeLine
                if (try? await remote.startRemotePairing(device)) == true { return .tryAgain }
                tvTestLines[id] = Self.remoteNoAnswerLine
            case .unsupported, .notNeeded:
                tvTestLines[id] = Self.remoteTimedOutLine
            }
        } catch {
            tvTestLines[id] = (error as? TVError) == .localNetworkDenied ? Self.allowLocalNetworkLine : Self.remoteTimedOutLine
        }
        return .closed
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
            switch error as? TVError {
            case .localNetworkDenied?: tvTestLines[id] = Self.allowLocalNetworkLine
            case .certChanged?: pairAgainTVs.insert(id); tvTestLines[id] = Self.pairAgainLine
            case .standby?: tvTestLines[id] = Self.tvOffLine
            default: tvTestLines[id] = Self.testFailedLine
            }
        }
    }
}
