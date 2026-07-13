import Foundation

enum ItineraLocalDataKeys {
    static let tripDraft = "itinera.tripDraft.v1"
    static let lockedStopsPrefix = "trip.lockedStops."
}

enum ItineraLocalDataCleaner {
    static func clearTripDraftAndLocks(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: ItineraLocalDataKeys.tripDraft)
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix(ItineraLocalDataKeys.lockedStopsPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}

struct TripScheduleConstraint: Codable, Equatable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case freeTime
        case fixedReservation

        var id: String { rawValue }

        var title: String {
            switch self {
            case .freeTime: return "Keep free"
            case .fixedReservation: return "Fixed plan"
            }
        }

        var systemImage: String {
            switch self {
            case .freeTime: return "calendar.badge.minus"
            case .fixedReservation: return "calendar.badge.checkmark"
            }
        }
    }

    var id: UUID
    var kind: Kind
    var title: String
    var date: Date
    var startsAt: Date
    var endsAt: Date
    var address: String
}

struct TripDraft: Codable, Equatable {
    var destinationQuery: String
    var destination: SelectedLocation?
    var homeBaseQuery: String
    var homeBase: SelectedLocation?
    var arrival: Date
    var departure: Date
    var groupSize: Int
    var wakeUpTime: Date
    var foodPreferences: String
    var mustDo: String
    var budget: String
    var pace: String
    var transportationPreference: String
    var travelingWithChildren: Bool
    var interests: String
    var accessibilityNeeds: String
    var fixedReservations: String
    var unavailableTimes: String
    var scheduleConstraints: [TripScheduleConstraint]? = nil
}

enum TripDraftCodec {
    static func encode(_ draft: TripDraft) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(draft)
    }

    static func decode(_ data: Data) -> TripDraft? {
        guard !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TripDraft.self, from: data)
    }
}
