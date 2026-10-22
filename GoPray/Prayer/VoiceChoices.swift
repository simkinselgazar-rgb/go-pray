// VoiceChoices.swift — the Athan voices the picker offers: the 16 Sunni and 12 Shia
// PrayTimes.org recordings (audio/CREDITS.md). The stem is the file name without
// ".mp3"; lane C validates a stem against the bundle. Fajr always uses Sheikh Hamed
// (CONTRACT: `play(prayer:voice:volume:)` ignores the voice for Fajr).
// Owner: lane A (display list only; no audio code here).

import Foundation

struct VoiceChoice: Identifiable, Hashable, Sendable {
    let voice: Voice
    let name: String
    var id: Voice { voice }
}

enum VoiceChoices {
    static let sunni: [VoiceChoice] = [
        ("Abdul-Basit", "Abdul Basit"), ("Abdul-Ghaffar", "Abdul Ghaffar"), ("Abdul-Hakam", "Abdul Hakam"),
        ("Adhan-Alaqsa", "Adhan Al-Aqsa"), ("Adhan-Egypt", "Adhan Egypt"), ("Adhan-Halab", "Adhan Halab"),
        ("Adhan-Madinah", "Adhan Madinah"), ("Adhan-Makkah", "Adhan Makkah"), ("Al-Hussaini", "Al-Hussaini"),
        ("Bakir-Bash", "Bakir Bash"), ("Hafez", "Hafez"), ("Hafiz-Murad", "Hafiz Murad"),
        ("Minshawi", "Minshawi"), ("Naghshbandi", "Naghshbandi"), ("Saber", "Saber"), ("Sharif-Doman", "Sharif Doman"),
    ].map { VoiceChoice(voice: .sunni($0.0), name: $0.1) }

    static let shia: [VoiceChoice] = [
        ("Aghati", "Aghati"), ("Ghalwash", "Ghalwash"), ("Kazem-Zadeh", "Kazem Zadeh"),
        ("Moazzen-Zadeh", "Moazzen Zadeh"), ("Mohammad-Zadeh", "Mohammad Zadeh"), ("Rezaeian", "Rezaeian"),
        ("Rowhani-Nejad", "Rowhani Nejad"), ("Salimi", "Salimi"), ("Sharif", "Sharif"),
        ("Sobhdel", "Sobhdel"), ("Tasvieh-Chi", "Tasviyechi"), ("Tookhi", "Tookhi"),
    ].map { VoiceChoice(voice: .shia($0.0), name: $0.1) }

    static var all: [VoiceChoice] { sunni + shia }

    static let defaultVoice: Voice = .sunni("Adhan-Makkah")

    /// Shown under the picker. Fajr is not a choice.
    static let fajrNote = "Fajr always uses Sheikh Hamed's Athan, from the Mahmoudeya mosque in Cairo."

    static func name(for voice: Voice) -> String {
        all.first { $0.voice == voice }?.name ?? "Custom"
    }
}
