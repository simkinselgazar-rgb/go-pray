// Geocoder.swift — typed city → coordinates. The ONLY file allowed to touch the
// network (guard.sh: URLSession and CLGeocoder only here). Owner: lane A.
//
// Called only from a user action in the city search field (typing, after a short
// pause). Never at launch, never in the background, no Location permission: it sends
// the typed text to Apple's geocoder and nothing else.

import CoreLocation
import Foundation

struct CityMatch: Identifiable, Equatable, Sendable {
    let name: String
    let region: String?
    let country: String?
    let countryCode: String?
    let latitude: Double
    let longitude: Double

    var id: String { "\(name)|\(region ?? "")|\(countryCode ?? "")|\(latitude)|\(longitude)" }

    /// "Toronto, Ontario" or just "Toronto". The country sits on the second line.
    var title: String { name }
    var subtitle: String { [region, country].compactMap { $0 }.joined(separator: ", ") }
    /// What Settings stores as the city.
    var label: String { subtitle.isEmpty ? name : "\(name), \(region ?? country ?? "")" }
}

enum GeocodeFailure: Error, Equatable {
    /// No connection, or the map service is down.
    case offline
    case other
}

@MainActor protocol CityGeocoding: AnyObject {
    /// Empty array = no match. Throws `GeocodeFailure`. Cancels the previous search.
    func search(_ text: String) async throws -> [CityMatch]
}

@MainActor final class Geocoder: CityGeocoding {
    private let geocoder = CLGeocoder()

    func search(_ text: String) async throws -> [CityMatch] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        geocoder.cancelGeocode()
        do {
            let marks = try await geocoder.geocodeAddressString(query)
            return Self.matches(from: marks)
        } catch let error as CLError {
            switch error.code {
            case .geocodeFoundNoResult: return []
            case .geocodeCanceled: throw CancellationError()
            case .network: throw GeocodeFailure.offline
            default: throw GeocodeFailure.other
            }
        }
    }

    /// Places with coordinates and a name, de-duplicated, at most 5 (a short list reads faster).
    nonisolated static func matches(from marks: [CLPlacemark]) -> [CityMatch] {
        var seen = Set<String>()
        var out: [CityMatch] = []
        for m in marks {
            guard let loc = m.location, let name = m.locality ?? m.name else { continue }
            let match = CityMatch(name: name, region: m.administrativeArea, country: m.country,
                                  countryCode: m.isoCountryCode,
                                  latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
            if seen.insert(match.label + (match.countryCode ?? "")).inserted { out.append(match) }
            if out.count == 5 { break }
        }
        return out
    }
}

/// "Enter coordinates instead": "43.65, -79.38" → a place with no name lookup.
enum CoordinateInput {
    static func parse(_ text: String) -> CityMatch? {
        let parts = text.split(whereSeparator: { ",;\t ".contains($0) }).compactMap { Double($0) }
        guard parts.count == 2, (-90...90).contains(parts[0]), (-180...180).contains(parts[1]) else { return nil }
        let name = String(format: "%.2f°, %.2f°", parts[0], parts[1])
        return CityMatch(name: name, region: nil, country: nil, countryCode: nil,
                         latitude: parts[0], longitude: parts[1])
    }
}
