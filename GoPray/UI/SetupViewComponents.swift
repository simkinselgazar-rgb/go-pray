// SetupViewComponents.swift — pieces shared by the setup window, Settings and the
// popover: per-prayer tokens (spec §4), type (spec §5), the city search with its
// skeleton (spec §12), and the one-line notice. Owner: lane A.
//
// Rules from the spec's do-not list that this file keeps: no red, no streaks, no
// exclamation marks, no spinners in content areas (the search shows skeleton rows
// that match the final result rows, so nothing shifts when results arrive).

import AppKit
import Observation
import SwiftUI

// MARK: - Tokens (spec §4) and type (spec §5)

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// The few per-prayer colours the app chrome uses. Everything else is system colour.
struct PrayerTokens {
    let ground: Color      // the colour a scene still paints over; also its skeleton
    let text: Color
    let accent: Color      // the 6pt "next prayer" dot

    static func of(_ prayer: Prayer) -> PrayerTokens {
        switch prayer {
        case .fajr: return .init(ground: Color(hex: 0x0E0705), text: Color(hex: 0xF2E4CC), accent: Color(hex: 0xF5D4A0))
        case .dhuhr: return .init(ground: Color(hex: 0xF0EEE7), text: Color(hex: 0x17232A), accent: Color(hex: 0x2E4D60))
        case .asr: return .init(ground: Color(hex: 0xF1ECE4), text: Color(hex: 0x2D1C0E), accent: Color(hex: 0x7A5C22))
        case .maghrib: return .init(ground: Color(hex: 0xF8DE9C), text: Color(hex: 0x241C0D), accent: Color(hex: 0x5C3A12))
        case .isha: return .init(ground: Color(hex: 0x08080F), text: Color(hex: 0xEDE9E1), accent: Color(hex: 0x62A38E))
        }
    }
}

/// Cormorant Garamond when the font is installed (it loads from the bundle through
/// ATSApplicationFontsPath); the system serif otherwise, so the layout holds either way.
@MainActor enum GPFont {
    static let hasCormorant: Bool = NSFontManager.shared.availableFontFamilies.contains("Cormorant Garamond")

    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        hasCormorant ? .custom("Cormorant Garamond", size: size).weight(weight)
                     : .system(size: size, weight: weight, design: .serif)
    }
}

enum Spacing {
    static let s4: CGFloat = 4, s8: CGFloat = 8, s12: CGFloat = 12, s16: CGFloat = 16
    static let s24: CGFloat = 24, s32: CGFloat = 32
}

// MARK: - Copy and formatting shared by all three screens

enum GPCopy {
    static let blockedLine = "Settings open again after you pray."
    static let invalidLine = "That didn't look right. Try again."
}

enum TimeText {
    /// "3:41 PM" in the person's own time zone and locale.
    @MainActor static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    /// "1 h 49 min", "49 min", "less than a minute". Rounds up so it never says 0 min early.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        if total < 60 { return "less than a minute" }
        let minutes = (total + 59) / 60
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// "6:12" for a lock countdown.
    static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    @MainActor static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return f.string(from: date)
    }
}

// MARK: - One line of "why", never red

struct GPNotice: View {
    let text: String
    var systemImage = "lock"

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(text)
    }
}

// MARK: - Header band (stands in for the scene still until lane B's SceneStill is wired)

/// The prayer's ground colour in the exact frame the still will fill. Per spec §12 the
/// ground colour IS the skeleton, so swapping in the real still shifts nothing.
struct GPSceneBand: View {
    let prayer: Prayer
    var height: CGFloat = 96
    /// Lane B's `SceneStill`, when wired. Nil = the plain ground colour.
    var still: AnyView?

    var body: some View {
        ZStack {
            PrayerTokens.of(prayer).ground
            if let still { still }
        }
        .frame(height: height)
        .clipped()
        .accessibilityHidden(true)
    }
}

// MARK: - Skeleton rows (spec §12: city search results)

struct SkeletonBar: View {
    var width: CGFloat
    var height: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.quaternary)
            .frame(width: width, height: height)
            .opacity(dim ? 0.55 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// Same size as a result row: a 140pt bar for the city, an 80pt bar under it.
struct CitySkeletonRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SkeletonBar(width: 140, height: 12)
            SkeletonBar(width: 80, height: 9)
        }
        .frame(maxWidth: .infinity, minHeight: CityRow.height, alignment: .leading)
        .padding(.horizontal, Spacing.s12)
        .accessibilityHidden(true)
    }
}

// MARK: - City search

@MainActor @Observable final class CitySearchModel {
    enum State: Equatable { case idle, searching, results([CityMatch]), noMatch, offline }

    private(set) var query = ""
    private(set) var state: State = .idle
    var coordinateMode = false
    var coordinateText = ""

    private let geocoder: CityGeocoding
    private let debounce: Duration
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Creating the model never searches. A search only starts from `queryChanged`, which
    /// the text field calls on a keystroke: a user action (Architecture Plan §E, lane A).
    init(geocoder: CityGeocoding, debounce: Duration = .milliseconds(450)) {
        self.geocoder = geocoder
        self.debounce = debounce
    }

    func queryChanged(_ text: String) {
        query = text
        task?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { state = .idle; return }
        state = .searching
        task = Task { [geocoder, debounce] in
            try? await Task.sleep(for: debounce)
            if Task.isCancelled { return }
            do {
                let found = try await geocoder.search(trimmed)
                if Task.isCancelled { return }
                state = found.isEmpty ? .noMatch : .results(found)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                state = .offline
            }
        }
    }

    /// Waits for the search in flight. Tests only.
    func settle() async { await task?.value }

    var coordinateMatch: CityMatch? { CoordinateInput.parse(coordinateText) }
}

enum CityRow {
    static let height: CGFloat = 46
    static let visibleRows = 4
    static var listHeight: CGFloat { height * CGFloat(visibleRows) }
}

struct CitySearchView: View {
    @Bindable var model: CitySearchModel
    @Binding var selection: CityMatch?
    var prompt = "Search for a city"
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s12) {
            if model.coordinateMode { coordinateEntry } else { searchEntry }
            Button(model.coordinateMode ? "Search for a city instead" : "Enter coordinates instead") {
                model.coordinateMode.toggle()
                selection = nil
            }
            .buttonStyle(.link)
            .font(.callout)
        }
    }

    // MARK: city search

    private var searchEntry: some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            TextField(prompt, text: Binding(get: { model.query }, set: { model.queryChanged($0) }))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if case .results(let r) = model.state, selection == nil { selection = r.first } }
                .accessibilityLabel("City")
                .onAppear { focused = true }
            resultArea
                .frame(height: CityRow.listHeight, alignment: .top)       // fixed: results swap in, nothing moves
        }
    }

    @ViewBuilder private var resultArea: some View {
        switch model.state {
        case .idle:
            Color.clear
        case .searching:
            VStack(spacing: 0) { ForEach(0..<3, id: \.self) { _ in CitySkeletonRow() }; Spacer(minLength: 0) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Searching")
        case .results(let matches):
            List(matches, selection: Binding(get: { selection?.id }, set: { id in
                selection = matches.first { $0.id == id }
            })) { match in
                CityResultRow(match: match).tag(match.id)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        case .noMatch:
            Text("No match. Try a bigger city nearby, or enter coordinates.")
                .font(.callout).foregroundStyle(.secondary).padding(.horizontal, Spacing.s12)
        case .offline:
            Text("Can't reach the map service right now. Check your connection, or enter coordinates.")
                .font(.callout).foregroundStyle(.secondary).padding(.horizontal, Spacing.s12)
        }
    }

    // MARK: coordinates

    private var coordinateEntry: some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            TextField("43.65, -79.38", text: $model.coordinateText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .accessibilityLabel("Latitude and longitude")
                .onChange(of: model.coordinateText) { _, _ in selection = model.coordinateMatch }
            Text(model.coordinateText.isEmpty || model.coordinateMatch != nil
                 ? "Latitude, then longitude. For example 43.65, -79.38."
                 : "Use two numbers: latitude (-90 to 90), then longitude (-180 to 180).")
                .font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(height: CityRow.listHeight + 28, alignment: .top)
    }
}

struct CityResultRow: View {
    let match: CityMatch

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(match.title).font(.body.weight(.semibold))
            if !match.subtitle.isEmpty {
                Text(match.subtitle).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: CityRow.height - 8, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
