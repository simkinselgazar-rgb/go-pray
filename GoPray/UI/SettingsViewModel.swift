// SettingsViewModel.swift — what the Settings window and the popover call to change
// things. Owner: lane A.
//
// Every mutation goes through `SettingsStore.mutate`, which asks the gate first. The
// views only ever show the gate's answer ("Settings open again after you pray.");
// the rule itself lives in BlockGate, not here.

import Foundation
import Observation

/// Preview of an Athan. Plays through the app's one `AthanPlaying`. It never touches
/// `onFinished` (the gate owns that), polls `isPlaying` instead, and never stops audio
/// that a block started.
@MainActor @Observable final class AthanPreview {
    private(set) var isPlaying = false
    private(set) var failed = false

    @ObservationIgnored private let audio: AthanPlaying
    @ObservationIgnored private let isBlocked: @MainActor () -> Bool
    @ObservationIgnored private var poll: Task<Void, Never>?

    init(audio: AthanPlaying, isBlocked: @escaping @MainActor () -> Bool) {
        self.audio = audio
        self.isBlocked = isBlocked
    }

    /// Dhuhr on purpose: Fajr ignores the chosen voice, so it would not preview it.
    func toggle(voice: Voice, volume: Float) {
        if isPlaying { stop(); return }
        guard !isBlocked() else { return }
        failed = false
        do {
            try audio.play(prayer: .dhuhr, voice: voice, volume: volume)
            isPlaying = true
            poll = Task { [weak self] in
                while let self, self.isPlaying {
                    try? await Task.sleep(for: .milliseconds(400))
                    if Task.isCancelled { return }
                    // A block took the audio over (or the file ended): let go without stopping it.
                    if self.isBlocked() || !self.audio.isPlaying { self.isPlaying = false }
                }
            }
        } catch {
            failed = true
        }
    }

    /// Stops our preview only, never a block's Athan.
    func stop() {
        poll?.cancel()
        if isPlaying, !isBlocked() { audio.stop() }
        isPlaying = false
    }
}

@MainActor @Observable final class SettingsViewModel {
    enum PauseState: Equatable { case active, until(Date), untilResumed }

    let store: SettingsStore
    let gate: BlockGate
    let clock: Clock
    let search: CitySearchModel
    let preview: AthanPreview

    @ObservationIgnored private let loginAgent: LoginAgentManaging
    @ObservationIgnored private let schedule: PrayerScheduleProviding?
    @ObservationIgnored private let tv: TVSending
    @ObservationIgnored private let discovery: TVDiscovering

    /// One short line about the last thing that did not work. Cleared by the next success.
    private(set) var notice: String?

    init(store: SettingsStore, gate: BlockGate, clock: Clock, audio: AthanPlaying,
         loginAgent: LoginAgentManaging, geocoder: CityGeocoding,
         schedule: PrayerScheduleProviding? = nil, tv: TVSending = NoTV(), discovery: TVDiscovering = NoTV()) {
        self.schedule = schedule
        self.tv = tv
        self.discovery = discovery
        self.store = store
        self.gate = gate
        self.clock = clock
        self.loginAgent = loginAgent
        self.search = CitySearchModel(geocoder: geocoder)
        self.preview = AthanPreview(audio: audio, isBlocked: { [unowned gate] in gate.isBlocked })
    }

    var settings: Settings { store.settings }
    var isBlocked: Bool { gate.isBlocked }

    // MARK: Changes

    /// Applies a change through the store. A refusal becomes one line, not an alert.
    @discardableResult
    func apply(_ change: (inout Settings) -> Void) -> Bool {
        do {
            try store.mutate(change)
            notice = nil
            return true
        } catch SettingsError.blocked {
            notice = GPCopy.blockedLine
        } catch {
            notice = GPCopy.invalidLine
        }
        return false
    }

    func set<T>(_ keyPath: WritableKeyPath<Settings, T>, to value: T) {
        apply { $0[keyPath: keyPath] = value }
    }

    func binding<T>(_ keyPath: WritableKeyPath<Settings, T>) -> BindingBox<T> {
        BindingBox(get: { [store] in store.settings[keyPath: keyPath] }, set: { [weak self] in self?.set(keyPath, to: $0) })
    }

    /// A line from a view-side failure (e.g. the picker could not read an app).
    func reportNotice(_ text: String) { notice = text }

    func setCity(_ match: CityMatch) {
        apply { $0.city = match.label; $0.latitude = match.latitude; $0.longitude = match.longitude }
    }

    /// The login agent is a side effect of the setting, so the gate is asked before it runs.
    func setLaunchAtLogin(_ on: Bool) {
        do { try store.authorize() } catch { notice = GPCopy.blockedLine; return }
        let failed = "Couldn't change launch at login. Try again in a moment."
        if on {
            do { try loginAgent.register() } catch { notice = failed; return }
            apply { $0.launchAtLogin = true }
        } else {
            // Save first: unregistering stops the launchd copy of the app (a successor copy
            // takes over), so nothing after the unregister call is sure to run in this process.
            guard apply({ $0.launchAtLogin = false }) else { return }
            do { try loginAgent.unregister() } catch { apply { $0.launchAtLogin = true }; notice = failed }
        }
    }

    // MARK: Blocked apps (v2)

    struct AppRow: Identifiable, Equatable { let id: String; let name: String; var isOn: Bool }

    /// What the picker hands back: a bundle id and a display name.
    struct PickedApp: Equatable { var id: String; var name: String }

    static let refusalLine = "Go Pray can't rest that one. It's part of macOS."
    static let duplicateLine = "Already on the list."
    static let emptyListLine = "Nothing is on the list, so Coding apps mode rests nothing."

    /// Every compiled-in default with its switch, in table order (AI + terminals, editors, browsers).
    var defaultAppRows: [AppRow] {
        let off = Set(settings.disabledDefaultApps)
        return CodingApps.defaults.map { AppRow(id: $0.id, name: $0.name, isOn: !off.contains($0.id)) }
    }

    /// "Added by you": this platform's custom apps.
    var customAppRows: [AppRow] {
        settings.customApps.filter { $0.platform == BlockedApps.current }.map { AppRow(id: $0.id, name: $0.name, isOn: true) }
    }

    var effectiveAppCount: Int { BlockedApps.effective(settings, defaults: CodingApps.bundleIDs).count }

    func setDefaultApp(_ id: String, on: Bool) {
        guard CodingApps.bundleIDs.contains(id) else { return }
        apply { s in
            s.disabledDefaultApps.removeAll { $0 == id }
            if !on { s.disabledDefaultApps.append(id) }
        }
    }

    /// A picked app. Refused: the never-blockable list ("part of macOS") and duplicates.
    /// A default that was switched off just comes back on.
    func addApp(_ app: PickedApp) {
        let id = BlockedApps.normalize(app.id)
        guard !id.isEmpty else { notice = GPCopy.invalidLine; return }
        guard BlockedApps.isBlockable(id) else { notice = Self.refusalLine; return }
        if CodingApps.bundleIDs.contains(id) {
            if settings.disabledDefaultApps.contains(id) { setDefaultApp(id, on: true) } else { notice = Self.duplicateLine }
            return
        }
        if settings.customApps.contains(where: { $0.platform == BlockedApps.current && $0.id == id }) {
            notice = Self.duplicateLine
            return
        }
        apply { $0.customApps.append(CustomApp(id: id, name: app.name, platform: BlockedApps.current)) }
    }

    func removeCustomApp(_ id: String) {
        apply { s in s.customApps.removeAll { $0.platform == BlockedApps.current && $0.id == id } }
    }

    // MARK: Emergency exits (v2)

    /// "3 of 5 emergency exits left this year".
    var exitsLine: String { EmergencyExitPolicy.line(left: gate.emergencyExitsLeft) }

    // MARK: TVs (CONTRACT-NOTES #56)

    enum ScanState: Equatable { case idle, scanning, done }

    static let badAddressLine = "Use your TV's address on your home network, like 192.168.1.20."
    static let duplicateTVLine = "That TV is already on the list."
    static let testSentLine = "Sent. Your TV should open Go Pray."
    static let notInstalledLine = "Go Pray isn't installed on this TV yet"
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

    var tvs: [TVDevice] { settings.tvs }

    func scanForTVs() async {
        guard !isBlocked, scanState != .scanning else { return }
        scanState = .scanning
        let scan = await discovery.scan()
        scanNeedsNetworkAccess = scan.denied
        let known = Set(settings.tvs.map(\.host))
        foundTVs = scan.found.filter { !known.contains($0.host) }
        scanState = .done
    }

    /// Adds a TV by address. The address check is `TVHost`; a bad or repeated one is refused with a line.
    @discardableResult
    func addTV(host: String, name: String) -> Bool {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TVHost.isAllowed(host) else { notice = Self.badAddressLine; return false }
        guard !settings.tvs.contains(where: { $0.host == host }) else { notice = Self.duplicateTVLine; return false }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let added = apply { $0.tvs.append(TVDevice(name: label.isEmpty ? "Roku TV" : label, host: host)) }
        if added { foundTVs.removeAll { $0.host == host } }
        return added
    }

    /// Add, then ask the TV which Go Pray app it has (scan and by-address both go through here).
    func addTVAndCheck(host: String, name: String) async -> Bool {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard addTV(host: h, name: name), let id = settings.tvs.first(where: { $0.host == h })?.id else { return false }
        await refreshTV(id)
        return true
    }

    func addFound(_ found: FoundTV) async { _ = await addTVAndCheck(host: found.host, name: found.name) }

    /// Looks the Go Pray app up on the TV and stores the result. A TV that can't be reached keeps what it had.
    @discardableResult
    func refreshTV(_ id: String) async -> TVResolution? {
        guard !isBlocked, let device = settings.tvs.first(where: { $0.id == id }) else { return nil }
        let r = await tv.resolve(device)
        switch r {
        case .found(let ch): apply { s in if let i = s.tvs.firstIndex(where: { $0.id == id }) { s.tvs[i].channelId = ch; s.tvs[i].installed = true } }
        case .notInstalled: apply { s in if let i = s.tvs.firstIndex(where: { $0.id == id }) { s.tvs[i].installed = false } }
        case .unreachable, .localNetworkDenied: break
        }
        if r == .localNetworkDenied { tvsNeedingNetworkAccess.insert(id) } else { tvsNeedingNetworkAccess.remove(id) }
        return r
    }

    func removeTV(_ id: String) {
        apply { $0.tvs.removeAll { $0.id == id } }
        tvTestLines[id] = nil
        tvsNeedingNetworkAccess.remove(id)
    }

    func setTV(_ id: String, enabled: Bool) {
        apply { s in if let i = s.tvs.firstIndex(where: { $0.id == id }) { s.tvs[i].enabled = enabled } }
    }

    func renameTV(_ id: String, to name: String) {
        apply { s in if let i = s.tvs.firstIndex(where: { $0.id == id }) { s.tvs[i].name = name } }
    }

    /// Launches the next prayer, with the current voice, on this one TV. Read-only during a block.
    func testTV(_ id: String) async {
        guard !isBlocked, settings.tvs.contains(where: { $0.id == id }), testingTV == nil else { return }
        testingTV = id
        defer { testingTV = nil }
        let checked = await refreshTV(id)
        if checked == .notInstalled { tvTestLines[id] = Self.notInstalledLine; return }
        if checked == .localNetworkDenied { tvTestLines[id] = Self.allowLocalNetworkLine; return }
        guard let device = settings.tvs.first(where: { $0.id == id }) else { return }
        let prayer = schedule?.nextAthan(after: clock.now)?.prayer ?? .asr
        do {
            try await tv.test(device, prayer: prayer, voice: settings.voice)
            tvTestLines[id] = Self.testSentLine
        } catch {
            tvTestLines[id] = (error as? TVError) == .localNetworkDenied ? Self.allowLocalNetworkLine : Self.testFailedLine
        }
    }

    // MARK: Pause

    var pauseState: PauseState {
        guard let until = settings.pausedUntil, until > clock.now else { return .active }
        return until == .distantFuture ? .untilResumed : .until(until)
    }

    func pause(_ option: PauseOption) {
        do { try store.pause(option, now: clock.now); notice = nil }
        catch SettingsError.blocked { notice = GPCopy.blockedLine }
        catch { notice = GPCopy.invalidLine }
    }

    func resume() {
        do { try store.resume(now: clock.now); notice = nil }
        catch SettingsError.blocked { notice = GPCopy.blockedLine }
        catch { notice = GPCopy.invalidLine }
    }

    var pauseSummary: String? {
        switch pauseState {
        case .active: return nil
        case .until(let d): return "Paused until \(TimeText.day(d))"
        case .untilResumed: return "Paused until you resume"
        }
    }
}

/// A tiny get/set pair, turned into a SwiftUI `Binding` by `.binding`. Keeps the view
/// model free of SwiftUI.
struct BindingBox<T> {
    let get: () -> T
    let set: (T) -> Void
}
