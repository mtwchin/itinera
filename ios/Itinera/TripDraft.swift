import Foundation

enum ItineraLocalDataKeys {
    private static let prefix = "itinera.private.v1."

    static func tripDraft(for scope: PrincipalScope) -> String {
        prefix + scope.digest + ".tripDraft"
    }

    static func lockedStopsPrefix(for scope: PrincipalScope) -> String {
        prefix + scope.digest + ".lockedStops."
    }

    static func lockedStops(
        for tripID: String,
        scope: PrincipalScope
    ) -> String {
        lockedStopsPrefix(for: scope) + tripID
    }
}

/// These constants exist only so bootstrap can destroy ambiguous pre-D2 data.
/// They must never be used to load, display, or submit private state.
enum ItineraLegacyPrivateDataKeys {
    static let tripDraft = "itinera.tripDraft.v1"
    static let lockedStopsPrefix = "trip.lockedStops."
}

enum ItineraLocalDataCleaner {
    static func clearCurrentScope(
        _ scope: PrincipalScope,
        defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(
            forKey: ItineraLocalDataKeys.tripDraft(for: scope)
        )
        let prefix = ItineraLocalDataKeys.lockedStopsPrefix(for: scope)
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    @discardableResult
    static func quarantineLegacyUnscopedData(
        defaults: UserDefaults = .standard
    ) -> Int {
        var removedCount = 0
        if defaults.object(
            forKey: ItineraLegacyPrivateDataKeys.tripDraft
        ) != nil {
            removedCount += 1
            defaults.removeObject(
                forKey: ItineraLegacyPrivateDataKeys.tripDraft
            )
        }
        for key in defaults.dictionaryRepresentation().keys.sorted()
            where key.hasPrefix(
                ItineraLegacyPrivateDataKeys.lockedStopsPrefix
            ) {
            removedCount += 1
            defaults.removeObject(forKey: key)
        }
        return removedCount
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
