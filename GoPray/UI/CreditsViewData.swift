// CreditsViewData.swift — the text the credits screen shows. Owner: lane C.
// Kept apart from the view so tests can check it without SwiftUI.

import Foundation

enum CreditsData {
    /// Takedown address (Ahmed, 2026-10-22). Empty = the line is shown without an address.
    static let takedownEmail = "hello@simkinselgazar.com"

    static let takedownLine = "If you own one of these recordings and want it removed, email us and we'll take it out."

    static let praytimesName = "PrayTimes.org"
    static let praytimesURL = URL(string: "https://praytimes.org/docs/adhan")!
    static let praytimesLine = "Athan recordings from PrayTimes.org (© 2007–2026 PrayTimes.org)."

    static let fajrLine = "Adhan al-Fajr, Sheikh Hamed, Mahmoudeya mosque, Cairo. Anna Kipervaser, On Look Films, LLC: Voices and Faces of the Adhan: Cairo. University of Cambridge, CC BY-NC-ND 3.0."
    static let fajrNote = "Played whole and unedited. It starts a few seconds in, to skip the quiet lead-in."

    static var sunniNames: [String] { VoiceCatalog.sunni.map(\.displayName) }
    static var shiaNames: [String] { VoiceCatalog.shia.map(\.displayName) }

    /// The takedown line plus the address, when we have one.
    static var takedownText: String {
        takedownEmail.isEmpty ? takedownLine : "\(takedownLine) (\(takedownEmail))"
    }
}
