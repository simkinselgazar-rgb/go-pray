// DebugMenu.swift — DEBUG builds only. Owner: PM.
// None of this exists in Release (§G: no hidden escape in the shipped build;
// `guard.sh --release` checks the binary for these strings).
// It can start a block, never end one: the real shield's "I prayed" goes through
// requestConfirm() like always. The mode is set through the settings store, so it is
// refused during a block like any other change.

#if DEBUG
import SwiftUI

struct DebugMenu: View {
    let env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Debug · \(prayer.displayName)").font(.caption).foregroundStyle(.secondary)
            Group {
                Button("Trigger Athan now (20 s lock) · Whole screen") { trigger(.wholeScreen) }
                Button("Trigger Athan now (20 s lock) · Coding apps") { trigger(.codingApps) }
            }
            .disabled(!env.settingsStore.settings.setupComplete)
            Button("Wipe state (idle only)") { env.gate.debugWipeState() }
        }
        .buttonStyle(.borderless)
        .disabled(env.gate.isBlocked)
    }

    /// The prayer whose window is open now, else the next one.
    private var prayer: Prayer {
        let now = env.clock.now
        if let w = env.schedule.window(containing: now), now < w.end { return w.prayer }
        return env.schedule.nextAthan(after: now)?.prayer ?? .dhuhr
    }

    private func trigger(_ mode: BlockMode) {
        guard !env.gate.isBlocked, env.settingsStore.settings.setupComplete else { return }
        do { try env.settingsStore.mutate { $0.mode = mode } } catch { return }
        env.gate.debugTriggerAthan(prayer, lockSeconds: 20)
    }
}

extension AppEnvironment {
    /// Debug seed for end-to-end runs: `open "Go Pray.app" --args -GoPrayDebugSeed toronto`.
    /// Does what Setup's Finish does (Toronto, ISNA, Shafi, whole screen, volume 0.15, launch
    /// at login), through the same store.mutate, so "first setup never blocks the open window"
    /// still applies. Only when setup is not done yet.
    func debugSeedIfAsked() {
        guard UserDefaults.standard.string(forKey: "GoPrayDebugSeed") == "toronto",
              !settingsStore.settings.setupComplete else { return }
        // Re-register: a rebuilt debug binary has a new ad-hoc signature, and launchd refuses
        // the old registration (EX_CONFIG spawn loop). Developer ID builds keep a stable one.
        var login = false
        try? loginAgent.unregister()
        do { try loginAgent.register(); login = true } catch {}
        try? settingsStore.mutate { s in
            s.city = "Toronto, Ontario, Canada"; s.latitude = 43.6532; s.longitude = -79.3832
            s.method = "northAmerica"; s.madhab = 1
            s.mode = .wholeScreen; s.athanVolume = 0.15
            s.launchAtLogin = login
            s.setupComplete = true
        }
    }

    /// Debug override for the coding-apps list, so a test run can hide only an app it
    /// started itself: `defaults write com.ahmedelgazar.gopray GoPrayDebugHideOnly com.apple.calculator`
    /// (comma-separated). Kept in user defaults so a launchd relaunch keeps it too.
    static func debugHideOnly() -> Set<String>? {
        guard let raw = UserDefaults.standard.string(forKey: "GoPrayDebugHideOnly") else { return nil }
        let ids = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return ids.isEmpty ? nil : Set(ids)
    }
}
#endif
