// MenuView.swift — the menu bar popover, 320pt wide, system material (spec §7). Owner: lane A.
// Today's five times, the next prayer and a countdown, the current mode, paused state.
// Quiet on purpose: no ticks, no "prayed" marks, no history. During a block the header
// reads "6:12 left" and Quit is disabled.

import SwiftUI

struct MenuView: View {
    let model: MenuViewModel
    /// Lane B's `SceneStill` for a prayer, when wired. Nil = the prayer's plain ground colour.
    var still: ((Prayer) -> AnyView)?
    var openSettings: () -> Void
    var openSetup: () -> Void
    var quit: () -> Void
    var checkForUpdates: () -> Void = {}
    var downloadUpdate: () -> Void = {}
    var openReleases: () -> Void = {}

    var body: some View {
        // One tick a second: the lock countdown shows seconds. The snapshot is cheap (cached day times).
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            content(model.snapshot(at: model.clock.now))
        }
        .frame(width: 320)
    }

    @ViewBuilder private func content(_ snap: MenuSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch snap.status {
            case .needsSetup:
                empty("Add your city to see today's prayer times.", button: "Set up", action: openSetup)
            case .noSchedule:
                empty("Go Pray can't work out times for this place. Check the city in Settings.",
                      button: "Open Settings", action: openSettings)
            case .ready:
                header(snap)
                rows(snap)
                Divider()
                modeAndPlace(snap)
                if let line = snap.exitsLine {
                    Text(line).font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, Spacing.s16).padding(.bottom, Spacing.s12)
                }
            }
            if let line = snap.update { updateRow(line) }
            Divider()
            actions(snap)
        }
    }

    // MARK: Header

    private func header(_ snap: MenuSnapshot) -> some View {
        let prayer = snap.blockPrayer ?? snap.nextPrayer ?? .fajr
        return VStack(alignment: .leading, spacing: 0) {
            GPSceneBand(prayer: prayer, height: 96, still: still?(prayer))
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(prayer.displayName.uppercased())
                        .font(GPFont.display(20)).tracking(0.25 * 20 * 0.4)    // 0.25em of the cap height; Latin caps only
                        .accessibilityLabel(prayer.displayName)
                    Text(subtitle(snap)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if snap.pausedLine != nil, !snap.isBlocked {
                    Button("Resume") { model.resume() }.buttonStyle(.link)
                }
            }
            .padding(.horizontal, Spacing.s16).padding(.vertical, Spacing.s12)
        }
    }

    private func subtitle(_ snap: MenuSnapshot) -> String {
        if let line = snap.blockLine { return line }
        if let paused = snap.pausedLine { return paused }
        if let until = snap.untilNext { return "in \(TimeText.duration(until))" }
        return ""
    }

    // MARK: Five times

    private func rows(_ snap: MenuSnapshot) -> some View {
        VStack(spacing: 0) {
            ForEach(snap.rows, id: \.prayer) { row in
                HStack(spacing: Spacing.s8) {
                    Circle()
                        .fill(row.isNext ? PrayerTokens.of(row.prayer).accent : .clear)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(row.prayer.displayName).fontWeight(row.isNext ? .semibold : .regular)
                    Spacer()
                    Text(TimeText.clock(row.time)).monospacedDigit()
                }
                .foregroundStyle(row.isPast ? Color.secondary : Color.primary)
                .padding(.horizontal, Spacing.s16)
                .frame(height: 28)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.prayer.displayName), \(TimeText.clock(row.time))\(row.isNext ? ", next" : "")")
            }
        }
        .padding(.bottom, Spacing.s8)
    }

    // MARK: Mode + place

    private func modeAndPlace(_ snap: MenuSnapshot) -> some View {
        HStack {
            Text(snap.mode.chipName)
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                .accessibilityLabel("Mode: \(snap.mode.displayName)")
            Spacer()
            Text(snap.footer).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, Spacing.s16).padding(.vertical, Spacing.s12)
    }

    // MARK: Actions

    private func actions(_ snap: MenuSnapshot) -> some View {
        HStack {
            Button("Settings…", action: openSettings)
            if snap.canCheckForUpdates || snap.update != nil || model.updater != nil {
                Button("Check for updates…", action: checkForUpdates).disabled(!snap.canCheckForUpdates)
            }
            Spacer()
            Button("Quit Go Pray", action: quit).disabled(snap.isBlocked)      // the gate refuses it too
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, Spacing.s16).padding(.vertical, Spacing.s12)
    }

    private func updateRow(_ line: UpdateLine) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(line.text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            switch line.action {
            case .download: Button("Download", action: downloadUpdate).buttonStyle(.link).font(.caption)
            case .getFromGitHub: Button("Open GitHub", action: openReleases).buttonStyle(.link).font(.caption)
            case .none: EmptyView()
            }
        }
        .padding(.horizontal, Spacing.s16).padding(.vertical, Spacing.s8)
    }

    private func empty(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s12) {
            Text(text).fixedSize(horizontal: false, vertical: true)
            Button(button, action: action).buttonStyle(.borderedProminent)
        }
        .padding(Spacing.s16)
    }
}
