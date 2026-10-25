// SettingsView.swift — one grouped Form (spec §7). Owner: lane A.
// Every control is disabled during a block, with one line on top saying why; the rule
// itself is enforced by the store through the gate, so a view bug cannot open a hole.
// Motion: none. A settings window is opened rarely and must feel instant.

import Adhan
import SwiftUI

struct SettingsView: View {
    @Bindable var model: SettingsViewModel
    /// Lane C's CreditsView. Pass nil to hide the row (tests).
    var credits: AnyView? = AnyView(CreditsView())
    @State private var changingCity = false
    @State private var pickedCity: CityMatch?
    @State private var showCredits = false
    @State private var lockDraft: Double?
    @State private var volumeDraft: Double?
    @State private var tvAddress = ""

    private var s: Settings { model.settings }

    var body: some View {
        VStack(spacing: 0) {
            if model.isBlocked || model.notice != nil {
                GPNotice(text: model.isBlocked ? GPCopy.blockedLine : (model.notice ?? ""),
                         systemImage: model.isBlocked ? "lock" : "info.circle")
                    .padding(.horizontal, Spacing.s16).padding(.top, Spacing.s12)
            }
            Form {
                locationSection
                timesSection
                blockSection
                blockedAppsSection
                pauseSection
                athanSection
                tvsSection
                generalSection
            }
            .formStyle(.grouped)
            .disabled(model.isBlocked)
        }
        .frame(width: 480)
        .frame(minHeight: 560, idealHeight: 720)
        .sheet(isPresented: $changingCity) { citySheet }
        .sheet(isPresented: $showCredits) { creditsSheet }
        .onDisappear { model.preview.stop() }
    }

    // MARK: Location

    private var locationSection: some View {
        Section("Location") {
            LabeledContent("City") {
                HStack {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(s.city.isEmpty ? "Not set" : s.city)
                        Text(String(format: "%.2f°, %.2f°", s.latitude, s.longitude))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Button("Change…") { pickedCity = nil; changingCity = true }
                }
            }
        }
    }

    private var citySheet: some View {
        VStack(alignment: .leading, spacing: Spacing.s16) {
            Text("Where do you pray?").font(GPFont.display(26))
            CitySearchView(model: model.search, selection: $pickedCity)
            HStack {
                Spacer()
                Button("Cancel") { changingCity = false }.keyboardShortcut(.cancelAction)
                Button("Use this city") {
                    if let c = pickedCity { model.setCity(c) }
                    changingCity = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pickedCity == nil)
            }
        }
        .padding(Spacing.s24)
        .frame(width: 420)
    }

    // MARK: Prayer times

    private var timesSection: some View {
        Section("Prayer times") {
            Picker("Method", selection: model.binding(\.method).binding) {
                ForEach(CalculationMethod.choices, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
            }
            help(s.calculationMethod?.detail ?? "")

            Picker("Asr", selection: model.binding(\.madhab).binding) {
                ForEach(Madhab.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            help(s.asrMadhab?.help ?? "")

            Picker("Far north or south", selection: model.binding(\.highLatitudeRule).binding) {
                Text("Automatic (\(HighLatitudeRule.recommended(for: s.coordinates).displayName))").tag(String?.none)
                ForEach(HighLatitudeRule.allCases, id: \.rawValue) { Text($0.displayName).tag(String?.some($0.rawValue)) }
            }
            help("For cities where the sky never gets fully dark in summer. \(s.effectiveHighLatitudeRule.help)")
        }
    }

    // MARK: Block

    private var blockSection: some View {
        Section("Block") {
            Picker("Mode", selection: model.binding(\.mode).binding) {
                ForEach([BlockMode.wholeScreen, .codingApps], id: \.rawValue) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            help(s.mode.help)

            LabeledContent("Break length") {
                HStack {
                    Slider(value: Binding(get: { lockDraft ?? Double(s.lockMinutes) }, set: { lockDraft = $0 }),
                           in: Double(LockPolicy.minMinutes)...Double(LockPolicy.maxMinutes), step: 1) { editing in
                        if !editing, let v = lockDraft { model.set(\.lockMinutes, to: Int(v)); lockDraft = nil }
                    }
                    .frame(width: 180)
                    .accessibilityLabel("Break length")
                    Text("\(Int(lockDraft ?? Double(s.lockMinutes))) min")
                        .monospacedDigit().frame(width: 52, alignment: .trailing)
                }
            }
            help("How long the screen rests after each Athan. Never under \(LockPolicy.minMinutes) minutes. A new length starts at the next prayer.")

            Toggle("Allow emergency exits", isOn: model.binding(\.emergencyExitsEnabled).binding)
            help("Up to 5 a year, for the days you truly can't stop. Off means no exit button at all. Changes start at the next prayer.")
            Text(s.emergencyExitsEnabled ? model.exitsLine : EmergencyExitPolicy.offLine).font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Blocked apps (v2)

    private var blockedAppsSection: some View {
        Section("Blocked apps") {
            help("Only these apps rest in Coding apps mode. Turn ours off, or add your own. Changes start at the next prayer.")
            ForEach(model.defaultAppRows) { row in
                Toggle(row.name, isOn: Binding(get: { row.isOn }, set: { model.setDefaultApp(row.id, on: $0) }))
            }
            let mine = model.customAppRows
            if !mine.isEmpty {
                Text("Added by you").font(.callout.weight(.semibold)).padding(.top, Spacing.s8)
                ForEach(mine) { row in
                    LabeledContent {
                        Button { model.removeCustomApp(row.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(row.name)")
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                            Text(row.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Button("Add an app…") { addApp() }
            if model.effectiveAppCount == 0 { help(SettingsViewModel.emptyListLine) }
        }
    }

    private func addApp() {
        switch AppPicker.pick() {
        case .cancelled: break
        case .unreadable: model.reportNotice("Couldn't read that app. Try another one.")
        case .picked(let app): model.addApp(app)
        }
    }

    // MARK: Pause

    private var pauseSection: some View {
        Section("Pause") {
            switch model.pauseState {
            case .active:
                LabeledContent("Pause Go Pray") {
                    Menu("Choose…") {
                        ForEach(PauseOption.allCases, id: \.rawValue) { option in
                            Button(option.displayName) { model.pause(option) }
                        }
                    }
                    .fixedSize()
                }
                help("For travel, illness or any time you can't pray. Only between prayers.")
            case .until, .untilResumed:
                LabeledContent(model.pauseSummary ?? "") {
                    Button("Resume") { model.resume() }
                }
                help("No screen rests while paused. Pausing and resuming only work between prayers.")
            }
        }
    }

    // MARK: Athan

    private var athanSection: some View {
        Section("Athan") {
            Picker("Voice", selection: model.binding(\.voice).binding) {
                Section("Sunni") { ForEach(VoiceChoices.sunni) { Text($0.name).tag($0.voice) } }
                Section("Shia") { ForEach(VoiceChoices.shia) { Text($0.name).tag($0.voice) } }
            }
            help(VoiceChoices.fajrNote)

            LabeledContent("Volume") {
                HStack(spacing: Spacing.s8) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                    Slider(value: Binding(get: { volumeDraft ?? Double(s.athanVolume) }, set: { volumeDraft = $0 }),
                           in: 0...1) { editing in
                        if !editing, let v = volumeDraft { model.set(\.athanVolume, to: Float(v)); volumeDraft = nil }
                    }
                    .frame(width: 150)
                    .accessibilityLabel("Athan volume")
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                    Button(model.preview.isPlaying ? "Stop" : "Preview") {
                        model.preview.toggle(voice: s.voice, volume: Float(volumeDraft ?? Double(s.athanVolume)))
                    }
                    .frame(width: 68)
                }
            }
            if model.preview.failed { help("Couldn't play that one. Try another voice.") }
        }
    }

    // MARK: TVs

    private var tvsSection: some View {
        Section("TVs") {
            help("The Athan starts on your TV too. Your TV needs the Go Pray Roku app.")
            ForEach(model.tvs) { tv in
                TVRow(tv: tv, model: model)
            }
            LabeledContent {
                Button(model.scanState == .scanning ? "Looking…" : "Find TVs") { Task { await model.scanForTVs() } }
                    .disabled(model.scanState == .scanning)
            } label: { Text("On your Wi-Fi") }
            ForEach(model.foundTVs, id: \.host) { found in
                LabeledContent {
                    Button("Add") { Task { await model.addFound(found) } }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(found.name)
                        Text(found.host).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
            if model.scanNeedsNetworkAccess { help(SettingsViewModel.allowLocalNetworkLine) }
            else if model.scanState == .done, model.foundTVs.isEmpty { help("No new Roku TVs found. You can add one by its address.") }
            LabeledContent("Add by address") {
                HStack {
                    TextField("192.168.1.20", text: $tvAddress)
                        .textFieldStyle(.roundedBorder).frame(width: 140).disableAutocorrection(true)
                        .onSubmit { addTypedTV() }
                    Button("Add") { addTypedTV() }.disabled(tvAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func addTypedTV() {
        let host = tvAddress
        Task { if await model.addTyped(host) { tvAddress = "" } }
    }

    // MARK: General

    private var generalSection: some View {
        Section("General") {
            Toggle("Launch at login", isOn: Binding(get: { s.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            if !s.launchAtLogin { help(LoginAgentCopy.firstRunNote) }       // shown before register()
            Toggle("Check for updates automatically", isOn: model.binding(\.checkForUpdates).binding)
            help("Once a day, from GitHub. Nothing about you is sent.")
            if credits != nil {
                Button("Credits and thanks") { showCredits = true }.buttonStyle(.link)
            }
            Text(AppVersionText.label()).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var creditsSheet: some View {
        VStack(spacing: Spacing.s12) {
            if let credits { credits }
            Button("Done") { showCredits = false }.keyboardShortcut(.defaultAction)
        }
        .padding(Spacing.s24)
        .frame(width: 440, height: 480)
    }

    private func help(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// One TV: name (saved on Return or when you leave the field), on/off, Test, Remove.
private struct TVRow: View {
    let tv: TVDevice
    @Bindable var model: SettingsViewModel
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            HStack {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit { commit() }
                    .accessibilityLabel("TV name")
                Toggle("On", isOn: Binding(get: { tv.enabled }, set: { model.setTV(tv.id, enabled: $0) }))
                    .labelsHidden().accessibilityLabel("Start the Athan on \(tv.name)")
                Button { model.removeTV(tv.id) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).accessibilityLabel("Remove \(tv.name)")
            }
            if model.tvsNeedingNetworkAccess.contains(tv.id) { Text(SettingsViewModel.allowLocalNetworkLine).font(.callout).foregroundStyle(.secondary) }
            else if !tv.installed { Text(SettingsViewModel.notInstalledLine).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Text(tv.host).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                if let line = model.tvTestLines[tv.id] {
                    Text(line).font(.callout).foregroundStyle(.secondary)
                }
                Button(model.testingTV == tv.id ? "Sending…" : "Test") { Task { await model.testTV(tv.id) } }
                    .disabled(model.testingTV != nil)
            }
        }
        .onAppear { name = tv.name }
        .onChange(of: tv.name) { _, new in if !focused { name = new } }
        .onChange(of: focused) { _, now in if !now { commit() } }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { name = tv.name } else if trimmed != tv.name { model.renameTV(tv.id, to: trimmed) }
    }
}

extension BindingBox {
    var binding: Binding<T> { Binding(get: get, set: set) }
}
