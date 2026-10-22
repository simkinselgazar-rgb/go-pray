// Settings.swift — defaults, validation and the adhan-swift bridge for the
// `Settings` struct (the shape lives in Core/Contracts.swift; CONTRACT-NOTES #3).
// Owner: lane A. This is the only place that turns the stored raw values
// (method string, madhab int, high-latitude string) into adhan-swift types.

import Adhan
import Foundation

enum SettingsValidationError: Error, Equatable {
    case invalidCoordinates
    case unknownMethod
    case unknownMadhab
    case unknownHighLatitudeRule
}

extension Settings {
    /// What a fresh install starts with. Setup is not complete, so nothing blocks.
    static let defaults = Settings(
        city: "", latitude: 0, longitude: 0,
        method: CalculationMethod.muslimWorldLeague.rawValue, madhab: Madhab.shafi.rawValue,
        highLatitudeRule: nil, mode: .wholeScreen, voice: VoiceChoices.defaultVoice, athanVolume: 0.8,
        launchAtLogin: true, setupComplete: false, reduceMotion: nil,
        lockMinutes: LockPolicy.defaultMinutes, pausedUntil: nil)

    /// Clamp what has a natural range: break length 10–30, volume 0–1.
    /// A NaN volume falls back to the default. Everything else is checked by `validate()`.
    func sanitized() -> Settings {
        var s = self
        s.lockMinutes = LockPolicy.clamp(lockMinutes)
        s.athanVolume = athanVolume.isFinite ? min(max(athanVolume, 0), 1) : Settings.defaults.athanVolume
        return s
    }

    /// Throws for values that cannot be turned into a schedule. Never repairs them.
    func validate() throws {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw SettingsValidationError.invalidCoordinates
        }
        guard CalculationMethod(rawValue: method) != nil, method != CalculationMethod.other.rawValue else {
            throw SettingsValidationError.unknownMethod
        }
        guard Madhab(rawValue: madhab) != nil else { throw SettingsValidationError.unknownMadhab }
        if let rule = highLatitudeRule, HighLatitudeRule(rawValue: rule) == nil {
            throw SettingsValidationError.unknownHighLatitudeRule
        }
    }

    var coordinates: Coordinates { Coordinates(latitude: latitude, longitude: longitude) }

    var calculationMethod: CalculationMethod? { CalculationMethod(rawValue: method) }
    var asrMadhab: Madhab? { Madhab(rawValue: madhab) }

    /// The rule the schedule really uses: the saved one, or the library's pick for this latitude.
    var effectiveHighLatitudeRule: HighLatitudeRule {
        highLatitudeRule.flatMap(HighLatitudeRule.init(rawValue:)) ?? HighLatitudeRule.recommended(for: coordinates)
    }

    /// nil when the settings cannot make a valid schedule (bad place, unknown method).
    func calculationParameters() -> CalculationParameters? {
        guard (try? validate()) != nil, let method = calculationMethod, let madhab = asrMadhab else { return nil }
        var params = method.params
        params.madhab = madhab
        params.highLatitudeRule = effectiveHighLatitudeRule
        return params
    }
}

// MARK: - Plain-language labels (UI copy lives here so tests can see it)

extension CalculationMethod {
    /// The methods we offer. `.other` is the library's "bring your own angles", not a choice.
    static var choices: [CalculationMethod] { allCases.filter { $0 != .other } }

    var displayName: String {
        switch self {
        case .muslimWorldLeague: return "Muslim World League"
        case .egyptian: return "Egyptian General Authority"
        case .karachi: return "University of Islamic Sciences, Karachi"
        case .ummAlQura: return "Umm al-Qura, Makkah"
        case .dubai: return "Dubai (UAE)"
        case .moonsightingCommittee: return "Moonsighting Committee"
        case .northAmerica: return "ISNA (North America)"
        case .kuwait: return "Kuwait"
        case .qatar: return "Qatar"
        case .singapore: return "Singapore, Malaysia, Indonesia"
        case .tehran: return "Tehran (Institute of Geophysics)"
        case .turkey: return "Turkey (Diyanet)"
        case .other: return "Custom"
        }
    }

    /// Short name for the popover footer: "Toronto · ISNA · Standard".
    var shortName: String {
        switch self {
        case .muslimWorldLeague: return "MWL"
        case .egyptian: return "Egyptian"
        case .karachi: return "Karachi"
        case .ummAlQura: return "Umm al-Qura"
        case .dubai: return "Dubai"
        case .moonsightingCommittee: return "Moonsighting"
        case .northAmerica: return "ISNA"
        case .kuwait: return "Kuwait"
        case .qatar: return "Qatar"
        case .singapore: return "Singapore"
        case .tehran: return "Tehran"
        case .turkey: return "Diyanet"
        case .other: return "Custom"
        }
    }

    /// One grey line under the choice. Angles are from the adhan-swift parameters.
    var detail: String {
        switch self {
        case .muslimWorldLeague: return "Fajr at 18°, Isha at 17°. A common default."
        case .egyptian: return "Fajr at 19.5°, Isha at 17.5°."
        case .karachi: return "Fajr and Isha at 18°. Used across South Asia."
        case .ummAlQura: return "Fajr at 18.5°. Isha 90 minutes after Maghrib."
        case .dubai: return "Fajr and Isha at 18.2°. Used in the UAE."
        case .moonsightingCommittee: return "Seasonal Fajr and Isha. Suits North America and the UK."
        case .northAmerica: return "Fajr and Isha at 15°. Used by many North American mosques."
        case .kuwait: return "Fajr at 18°, Isha at 17.5°."
        case .qatar: return "Fajr at 18°. Isha 90 minutes after Maghrib."
        case .singapore: return "Fajr at 20°, Isha at 18°."
        case .tehran: return "Fajr at 17.7°, Isha at 14°."
        case .turkey: return "Close to the Diyanet timetable. Best inside Turkey."
        case .other: return ""
        }
    }

    /// The method most mosques in a country follow. A suggestion, never forced.
    static func suggested(forCountryCode code: String?) -> CalculationMethod {
        switch code?.uppercased() {
        case "US", "CA": return .northAmerica
        case "GB": return .moonsightingCommittee
        case "SA": return .ummAlQura
        case "EG", "SD", "LY", "DZ", "SY", "LB", "IQ", "PS", "JO": return .egyptian
        case "PK", "IN", "BD", "AF": return .karachi
        case "AE": return .dubai
        case "KW": return .kuwait
        case "QA": return .qatar
        case "SG", "MY", "ID", "BN": return .singapore
        case "IR": return .tehran
        case "TR": return .turkey
        default: return .muslimWorldLeague
        }
    }
}

extension Madhab {
    var displayName: String {
        switch self {
        case .shafi: return "Standard"
        case .hanafi: return "Hanafi"
        }
    }

    var help: String {
        switch self {
        case .shafi: return "Shafi, Maliki and Hanbali. Asr starts when a shadow is as long as the object."
        case .hanafi: return "Asr starts later, when a shadow is twice as long as the object."
        }
    }
}

extension HighLatitudeRule {
    var displayName: String {
        switch self {
        case .middleOfTheNight: return "Middle of the night"
        case .seventhOfTheNight: return "Seventh of the night"
        case .twilightAngle: return "Twilight angle"
        }
    }

    var help: String {
        switch self {
        case .middleOfTheNight: return "Fajr and Isha never pass the middle of the night."
        case .seventhOfTheNight: return "Isha ends the first seventh of the night, Fajr starts the last seventh."
        case .twilightAngle: return "Splits the night by the Fajr and Isha angles."
        }
    }
}

extension BlockMode {
    var displayName: String {
        switch self {
        case .wholeScreen: return "Whole screen"
        case .codingApps: return "Coding apps only"
        }
    }

    /// Short chip text for the popover.
    var chipName: String {
        switch self {
        case .wholeScreen: return "Whole screen"
        case .codingApps: return "Coding apps"
        }
    }

    var help: String {
        switch self {
        case .wholeScreen: return "A calm screen covers everything until you pray."
        case .codingApps: return "Only your coding apps rest. Your agents keep running."
        }
    }
}

extension PauseOption {
    var displayName: String {
        switch self {
        case .oneDay: return "For 1 day"
        case .threeDays: return "For 3 days"
        case .oneWeek: return "For 1 week"
        case .untilResumed: return "Until I resume"
        }
    }
}

extension Prayer {
    var displayName: String {
        switch self {
        case .fajr: return "Fajr"
        case .dhuhr: return "Dhuhr"
        case .asr: return "Asr"
        case .maghrib: return "Maghrib"
        case .isha: return "Isha"
        }
    }
}

extension DayTimes {
    /// The five prayers in order (sunrise is not a prayer).
    var prayers: [(prayer: Prayer, at: Date)] {
        [(.fajr, fajr), (.dhuhr, dhuhr), (.asr, asr), (.maghrib, maghrib), (.isha, isha)]
    }
}
