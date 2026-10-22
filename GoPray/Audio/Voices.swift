// Voices.swift — the catalogue of shipped Athan voices and where their files live.
// Owner: lane C. Source of truth for the credits screen too (CreditsView).
// Files: Resources/athan/{sunni,shia}/<stem>.mp3 and Resources/athan/fajr/<fajr stem>.mp3.
// Yusuf Islam is removed on purpose (living artist, label recording): never add it.

import Foundation

struct VoiceEntry: Equatable, Sendable {
    let voice: Voice
    let stem: String            // file name without ".mp3"
    let displayName: String
}

enum VoiceCatalog {
    static let subdirectory = "athan"
    static let fajrStem = "C-egypt-cairo-mahmoudeya-sheikhhamed-fajr"
    /// Fajr always starts here. A playback offset, not a cut: the file stays unedited (CC BY-NC-ND).
    static let fajrStartOffset: TimeInterval = 9.0

    static let sunni: [VoiceEntry] = [
        ("Abdul-Basit", "Abdul Basit"), ("Abdul-Ghaffar", "Abdul Ghaffar"), ("Abdul-Hakam", "Abdul Hakam"),
        ("Adhan-Alaqsa", "Adhan Al-Aqsa"), ("Adhan-Egypt", "Adhan Egypt"), ("Adhan-Halab", "Adhan Halab"),
        ("Adhan-Madinah", "Adhan Madinah"), ("Adhan-Makkah", "Adhan Makkah"), ("Al-Hussaini", "Al-Hussaini"),
        ("Bakir-Bash", "Bakir Bash"), ("Hafez", "Hafez"), ("Hafiz-Murad", "Hafiz Murad"),
        ("Minshawi", "Minshawi"), ("Naghshbandi", "Naghshbandi"), ("Saber", "Saber"), ("Sharif-Doman", "Sharif Doman"),
    ].map { VoiceEntry(voice: .sunni($0.0), stem: $0.0, displayName: $0.1) }

    static let shia: [VoiceEntry] = [
        ("Aghati", "Aghati"), ("Ghalwash", "Ghalwash"), ("Kazem-Zadeh", "Kazem Zadeh"),
        ("Moazzen-Zadeh", "Moazzen Zadeh"), ("Mohammad-Zadeh", "Mohammad Zadeh"), ("Rezaeian", "Rezaeian"),
        ("Rowhani-Nejad", "Rowhani Nejad"), ("Salimi", "Salimi"), ("Sharif", "Sharif"),
        ("Sobhdel", "Sobhdel"), ("Tasvieh-Chi", "Tasviyechi"), ("Tookhi", "Tookhi"),
    ].map { VoiceEntry(voice: .shia($0.0), stem: $0.0, displayName: $0.1) }

    static var all: [VoiceEntry] { sunni + shia }

    static func entry(for voice: Voice) -> VoiceEntry? { all.first { $0.voice == voice } }

    static func subdirectory(for voice: Voice) -> String {
        switch voice {
        case .sunni: return "\(subdirectory)/sunni"
        case .shia: return "\(subdirectory)/shia"
        }
    }

    static let fajrSubdirectory = "\(subdirectory)/fajr"

    /// The file for a prayer. Fajr ignores `voice`. Throws if the voice is not in the
    /// catalogue or the file is not in the bundle. Never falls back to another file.
    static func url(prayer: Prayer, voice: Voice, bundle: Bundle = .main) throws -> URL {
        if prayer == .fajr {
            guard let u = bundle.url(forResource: fajrStem, withExtension: "mp3", subdirectory: fajrSubdirectory) else {
                throw AthanError.missingFile(fajrStem)
            }
            return u
        }
        guard let e = entry(for: voice) else { throw AthanError.unknownVoice }
        guard let u = bundle.url(forResource: e.stem, withExtension: "mp3", subdirectory: subdirectory(for: voice)) else {
            throw AthanError.missingFile(e.stem)
        }
        return u
    }

    /// True when `voice` is a shipped voice. Lane A uses this to validate `Settings.voice`.
    static func isValid(_ voice: Voice) -> Bool { entry(for: voice) != nil }

    /// Used when a saved voice is no longer valid.
    static var defaultVoice: Voice { .sunni("Adhan-Makkah") }
}

enum AthanError: Error, Equatable {
    case unknownVoice
    case missingFile(String)
    case cannotDecode(String)
}
