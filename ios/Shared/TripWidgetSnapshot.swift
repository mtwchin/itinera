import Foundation

enum ItineraWidgetKind {
    static let nextStop = "ItineraNextStop"
}

struct TripWidgetSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let tripID: String
    let tripTitle: String
    let dayNumber: Int
    let stopNumber: Int
    let totalStops: Int
    let currentStop: String?
    let nextStop: String
    let leaveBy: Date?
    let progress: Double
    let updatedAt: Date

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        tripID: String,
        tripTitle: String,
        dayNumber: Int,
        stopNumber: Int,
        totalStops: Int,
        currentStop: String?,
        nextStop: String,
        leaveBy: Date?,
        progress: Double,
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.tripID = tripID
        self.tripTitle = tripTitle
        self.dayNumber = dayNumber
        self.stopNumber = stopNumber
        self.totalStops = totalStops
        self.currentStop = currentStop
        self.nextStop = nextStop
        self.leaveBy = leaveBy
        self.progress = min(max(progress, 0), 1)
        self.updatedAt = updatedAt
    }
}

enum TripWidgetSnapshotStore {
    static let appGroupIdentifier = "group.com.itinera.shared"
    private static let snapshotKey = "trip-widget-snapshot-v1"

    static func load(defaults: UserDefaults? = nil) -> TripWidgetSnapshot? {
        guard
            let defaults = defaults ?? UserDefaults(suiteName: appGroupIdentifier),
            let data = defaults.data(forKey: snapshotKey),
            let snapshot = try? JSONDecoder().decode(TripWidgetSnapshot.self, from: data),
            snapshot.schemaVersion == TripWidgetSnapshot.currentSchemaVersion
        else {
            return nil
        }
        return snapshot
    }

    @discardableResult
    static func save(
        _ snapshot: TripWidgetSnapshot,
        defaults: UserDefaults? = nil
    ) -> Bool {
        guard
            let defaults = defaults ?? UserDefaults(suiteName: appGroupIdentifier),
            let data = try? JSONEncoder().encode(snapshot)
        else {
            return false
        }
        defaults.set(data, forKey: snapshotKey)
        return true
    }

    static func clear(defaults: UserDefaults? = nil) {
        (defaults ?? UserDefaults(suiteName: appGroupIdentifier))?
            .removeObject(forKey: snapshotKey)
    }
}
