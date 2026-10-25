// SetupViewModel.swift — the first-run flow's state: 4 steps (the last, a TV, is optional) and a done screen.
// Owner: lane A. Nothing is saved until the last step: one `mutate` writes the city,
// method, madhab, mode, volume and launch-at-login together with `setupComplete = true`.
// That false→true flip is what tells the gate not to block the prayer that is already
// open (CONTRACT-NOTES #28). The store asks the gate first, like every other change.

import Adhan
import Foundation
import Observation

@MainActor @Observable final class SetupViewModel {
    enum Step: Int, CaseIterable { case city, method, mode, tv, done }

    private(set) var step: Step = .city
    var pickedCity: CityMatch? { didSet { cityChanged() } }
    var method: CalculationMethod = .muslimWorldLeague { didSet { if !suggesting { methodTouched = true } } }
    var madhab: Madhab = .shafi
    var mode: BlockMode = .wholeScreen
    var volume: Double = Double(Settings.defaults.athanVolume)
    var launchAtLogin = true
    /// "Couldn't turn on launch at login", shown on the done screen. Never blocks setup.
    private(set) var loginNote: String?
    private(set) var notice: String?
    /// "Next: Asr at 3:41 PM." once saved.
    private(set) var nextLine: String?

    let search: CitySearchModel
    let preview: AthanPreview
    /// The same TV model Settings uses. Adding a TV saves through the store right away.
    private(set) var tvs: TVListModel!

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let schedule: PrayerScheduleProviding
    @ObservationIgnored private let clock: Clock
    @ObservationIgnored private let loginAgent: LoginAgentManaging
    @ObservationIgnored private var methodTouched = false
    @ObservationIgnored private var suggesting = false

    init(store: SettingsStore, schedule: PrayerScheduleProviding, clock: Clock, audio: AthanPlaying,
         loginAgent: LoginAgentManaging, geocoder: CityGeocoding, gate: BlockGate,
         tv: TVSending = NoTV(), discovery: TVDiscovering = NoTV()) {
        self.store = store
        self.schedule = schedule
        self.clock = clock
        self.loginAgent = loginAgent
        self.search = CitySearchModel(geocoder: geocoder)
        self.preview = AthanPreview(audio: audio, isBlocked: { [unowned gate] in gate.isBlocked })
        self.tvs = TVListModel(
            settings: { [store] in store.settings }, apply: { [unowned self] in self.applyTVChange($0) },
            notify: { [unowned self] in self.notice = $0 }, isBlocked: { [unowned gate] in gate.isBlocked },
            nextPrayer: { [schedule, clock] in schedule.nextAthan(after: clock.now)?.prayer },
            tv: tv, discovery: discovery)
    }

    /// A TV change goes through the store like every other setting; a refusal becomes the one notice line.
    private func applyTVChange(_ change: (inout Settings) -> Void) -> Bool {
        do { try store.mutate(change); notice = nil; return true }
        catch SettingsError.blocked { notice = GPCopy.blockedLine }
        catch { notice = GPCopy.invalidLine }
        return false
    }

    static let stepCount = 4
    var stepNumber: Int { min(step.rawValue + 1, Self.stepCount) }
    var hasTV: Bool { !tvs.tvs.isEmpty }

    var canGoNext: Bool {
        switch step {
        case .city: return pickedCity != nil
        case .method, .mode, .tv: return true
        case .done: return false
        }
    }

    var title: String {
        switch step {
        case .city: return "Where do you pray?"
        case .method: return "How are your times worked out?"
        case .mode: return "How should Go Pray stop you?"
        case .tv: return "Play the Athan on your TV?"
        case .done: return "You're set."
        }
    }

    func next() {
        notice = nil
        if step == .mode { preview.stop() }
        switch step {
        case .city, .method, .mode: step = Step(rawValue: step.rawValue + 1) ?? .done
        case .tv: finish()
        case .done: break
        }
    }

    func back() {
        guard step != .city, step != .done else { return }
        preview.stop()
        step = Step(rawValue: step.rawValue - 1) ?? .city
    }

    /// The suggestion follows the country until the person picks a method themselves.
    private func cityChanged() {
        guard let c = pickedCity, !methodTouched else { return }
        suggesting = true
        method = CalculationMethod.suggested(forCountryCode: c.countryCode)
        suggesting = false
    }

    private func finish() {
        guard let city = pickedCity else { step = .city; return }
        preview.stop()
        do { try store.authorize() } catch { notice = GPCopy.blockedLine; return }

        var login = false
        if launchAtLogin {
            do { try loginAgent.register(); login = true }
            catch { loginNote = "Couldn't turn on launch at login. You can try again in Settings." }
        }
        do {
            try store.mutate { s in
                s.city = city.label; s.latitude = city.latitude; s.longitude = city.longitude
                s.method = method.rawValue; s.madhab = madhab.rawValue
                s.mode = mode; s.athanVolume = Float(volume)
                s.launchAtLogin = login
                s.setupComplete = true
            }
        } catch SettingsError.blocked {
            notice = GPCopy.blockedLine
            return
        } catch {
            notice = GPCopy.invalidLine
            return
        }
        if let n = schedule.nextAthan(after: clock.now) {
            nextLine = "Next: \(n.prayer.displayName) at \(TimeText.clock(n.at))."
        } else {
            nextLine = "We couldn't work out times for that place. Check the city in Settings."
        }
        step = .done
    }

    /// The prayer whose colours dress the header: the next one, else Dhuhr (light paper; Fajr is near-black for a first screen).
    var headerPrayer: Prayer { schedule.nextAthan(after: clock.now)?.prayer ?? .dhuhr }
}
