// SetupTVStep.swift — the optional "Play the Athan on your TV?" step of first-run setup.
// All the TV work is `TVListModel` (the same one Settings uses); this file is layout only.
// Scanning shows skeleton rows shaped like the found-TV rows, never a spinner or a blank.

import SwiftUI

struct SetupTVStep: View {
    var model: TVListModel
    @State private var address = ""
    @State private var addingByAddress = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s12) {
            Text("If you have a Roku TV, Go Pray can play the Athan on it at each prayer. Your TV needs the free Go Pray Roku app.")
                .font(.body).fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.s8) {
                    ForEach(model.tvs) { tv in addedRow(tv) }
                    if model.scanState == .scanning || model.scanState == .idle { skeletonRow }
                    ForEach(model.foundTVs, id: \.host) { found in foundRow(found) }
                    if model.scanNeedsNetworkAccess {
                        Text(TVListModel.allowLocalNetworkLine).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if model.scanState == .done, model.foundTVs.isEmpty, model.tvs.isEmpty {
                        Text("No Roku TVs found. Is the TV on, and on the same Wi-Fi? You can also add it by its address.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            HStack {
                Button("Find TVs again") { Task { await model.scanForTVs() } }
                    .disabled(model.scanState == .scanning)
                Spacer()
                if addingByAddress {
                    TextField("192.168.1.20", text: $address)
                        .textFieldStyle(.roundedBorder).frame(width: 140).disableAutocorrection(true)
                        .onSubmit { addTyped() }
                    Button("Add") { addTyped() }.disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    Button("Add by address") { addingByAddress = true }.buttonStyle(.link)
                }
            }
        }
        // The macOS Local Network prompt appears here, on purpose: the person is looking at why.
        .task { await model.scanForTVs() }
    }

    private func addTyped() {
        let a = address
        Task { if await model.addTyped(a) { address = ""; addingByAddress = false } }
    }

    // MARK: Rows (same height as the skeleton, so nothing jumps when results arrive)

    private func rowShell<Trailing: View>(name: String, detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: Spacing.s12) {
            Image(systemName: "tv").foregroundStyle(.secondary).frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.semibold))
                Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, Spacing.s12).padding(.vertical, Spacing.s8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    private func foundRow(_ found: FoundTV) -> some View {
        rowShell(name: found.name, detail: found.host) {
            Button("Add") { Task { await model.addFound(found) } }
                .accessibilityLabel("Add \(found.name)")
        }
    }

    private var skeletonRow: some View {
        HStack(spacing: Spacing.s12) {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 24, height: 18)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 130, height: 12)
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 86, height: 9)
            }
            Spacer()
            RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(width: 44, height: 20)
        }
        .padding(.horizontal, Spacing.s12).padding(.vertical, Spacing.s8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.3)))
        .accessibilityElement().accessibilityLabel("Looking for TVs")
    }

    private func addedRow(_ tv: TVDevice) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            rowShell(name: tv.name, detail: tv.host) {
                if model.testingTV == tv.id {
                    Text("Sending…").font(.callout).foregroundStyle(.secondary)
                } else {
                    Button("Play a test") { Task { await model.testTV(tv.id) } }
                        .disabled(model.testingTV != nil || model.status(of: tv.id) == .checking)
                }
            }
            statusLine(tv)
                .padding(.horizontal, Spacing.s12)
        }
    }

    @ViewBuilder private func statusLine(_ tv: TVDevice) -> some View {
        if let line = model.tvTestLines[tv.id] {
            Text(line).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            switch model.status(of: tv.id) {
            case .checking:
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 150, height: 11)
            case .ready:
                Label("Ready", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
            case .notInstalled:
                Text(TVListModel.notInstalledSetupLine).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .needsNetworkAccess:
                Text(TVListModel.allowLocalNetworkLine).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .notReached:
                Text(TVListModel.testFailedLine).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
