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

    /// One short line about the last thing that did not work. Cleared by the next success.
    private(set) var notice: String?

    init(store: SettingsStore, gate: BlockGate, clock: Clock, audio: AthanPlaying,
         loginAgent: LoginAgentManaging, geocoder: CityGeocoding) {
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
