// SetupView.swift — first-run window, 520 × 600 (spec §7). Owner: lane A.
// Three steps and a done screen, one question per step, native controls.
// Motion: none between steps (a one-time screen, and nothing here is worth a delay).

import Adhan
import SwiftUI

struct SetupView: View {
    @Bindable var model: SetupViewModel
    /// Lane B's `SceneStill`, when wired. Nil = the prayer's plain ground colour.
    var headerStill: AnyView?
    var onFinished: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            GPSceneBand(prayer: model.headerPrayer, height: 96, still: headerStill)
            VStack(alignment: .leading, spacing: Spacing.s16) {
                if model.step != .done {
                    Text("Step \(model.stepNumber) of 3").font(.caption).foregroundStyle(.secondary)
                }
                Text(model.title).font(GPFont.display(26)).accessibilityAddTraits(.isHeader)
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if let note = model.notice { GPNotice(text: note, systemImage: "info.circle") }
                footer
            }
            .padding(Spacing.s24)
        }
        .frame(width: 520, height: 600)
        .onDisappear { model.preview.stop() }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .city: CitySearchView(model: model.search, selection: $model.pickedCity)
        case .method: methodStep
        case .mode: modeStep
        case .done: doneStep
        }
    }

    // MARK: Step 2

    private var methodStep: some View {
        VStack(alignment: .leading, spacing: Spacing.s16) {
            ScrollViewReader { proxy in
            List(selection: Binding(get: { model.method.rawValue }, set: { raw in
                if let raw, let m = CalculationMethod(rawValue: raw) { model.method = m }
            })) {
                ForEach(CalculationMethod.choices, id: \.rawValue) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.displayName).font(.body.weight(.semibold))
                        Text(m.detail).font(.callout).foregroundStyle(.secondary)
                    }
                    .tag(m.rawValue)
                    .id(m.rawValue)
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            }
            .listStyle(.bordered)
            .frame(height: 252)
            // The suggested method can sit below the fold: show it, selected, on arrival.
            .onAppear { proxy.scrollTo(model.method.rawValue, anchor: .center) }
            }

            VStack(alignment: .leading, spacing: Spacing.s8) {
                Picker("Asr", selection: $model.madhab) {
                    ForEach(Madhab.allCases, id: \.rawValue) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(model.madhab.help).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Step 3

    private var modeStep: some View {
        VStack(alignment: .leading, spacing: Spacing.s24) {
            VStack(alignment: .leading, spacing: Spacing.s8) {
                Picker("Mode", selection: $model.mode) {
                    ForEach([BlockMode.wholeScreen, .codingApps], id: \.rawValue) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                ForEach([BlockMode.wholeScreen, .codingApps], id: \.rawValue) { m in
                    Text("**\(m.displayName).** \(m.help)").font(.callout)
                        .foregroundStyle(m == model.mode ? .primary : .secondary)
                }
            }
            HStack(spacing: Spacing.s8) {
                Text("Athan volume")
                Image(systemName: "speaker.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                Slider(value: $model.volume, in: 0...1).accessibilityLabel("Athan volume")
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                Button(model.preview.isPlaying ? "Stop" : "Preview") {
                    model.preview.toggle(voice: Settings.defaults.voice, volume: Float(model.volume))
                }
                .frame(width: 68)
            }
            if model.preview.failed {
                Text("Couldn't play the preview. You can pick another voice in Settings.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: Spacing.s8) {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                // Shown before Finish calls register(), so the macOS prompt is no surprise.
                if model.launchAtLogin {
                    Text(LoginAgentCopy.firstRunNote).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Done

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: Spacing.s12) {
            if let line = model.nextLine { Text(line).font(.title3) }
            if let note = model.loginNote { Text(note).font(.callout).foregroundStyle(.secondary) }
            Text("Go Pray lives in your menu bar. It stays quiet until the next Athan.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if model.step == .method || model.step == .mode {
                Button("Back") { model.back() }
            }
            Spacer()
            if model.step == .done {
                Button("Close") { onFinished() }.keyboardShortcut(.defaultAction)
            } else {
                Button(model.step == .mode ? "Finish" : "Next") { model.next() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canGoNext)
            }
        }
    }
}
