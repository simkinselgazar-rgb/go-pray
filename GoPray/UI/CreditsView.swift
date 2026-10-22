// CreditsView.swift — voices, sources and the takedown line. Owner: lane C.
// Static text, no async loading, so no skeleton state is needed.

import SwiftUI

struct CreditsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Credits").font(.title2.weight(.semibold))

                section("Fajr") {
                    Text(CreditsData.fajrLine)
                    Text(CreditsData.fajrNote).foregroundStyle(.secondary)
                }

                section("Other prayers") {
                    Text(CreditsData.praytimesLine)
                    Link(CreditsData.praytimesName, destination: CreditsData.praytimesURL)
                }

                section("Sunni voices") { names(CreditsData.sunniNames) }
                section("Shia voices") { names(CreditsData.shiaNames) }

                Text(CreditsData.takedownText).font(.callout).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 380, minHeight: 440)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func names(_ list: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) { ForEach(list, id: \.self) { Text($0) } }
    }
}
