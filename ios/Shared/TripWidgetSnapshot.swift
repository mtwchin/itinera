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
    private static let activeSnapshotKey = "trip-widget-active-snapshot-key-v1"

    static func scopedKey(principalDigest: String) -> String? {
        guard principalDigest.count == 64,
              principalDigest.allSatisfy({ $0.isASCII && $0.isHexDigit })
        else { return nil }
        return "\(snapshotKey).\(principalDigest.lowercased())"
    }

    static func load(defaults: UserDefaults? = nil) -> TripWidgetSnapshot? {
        guard
            let defaults = defaults ?? UserDefaults(suiteName: appGroupIdentifier),
            let selectedKey = defaults.string(forKey: activeSnapshotKey),
            isAllowedSnapshotKey(selectedKey),
            let data = defaults.data(forKey: selectedKey),
            let snapshot = try? JSONDecoder().decode(TripWidgetSnapshot.self, from: data),
            snapshot.schemaVersion == TripWidgetSnapshot.currentSchemaVersion
        else {
            return nil
        }
        return snapshot
    }

    private static func isAllowedSnapshotKey(_ key: String) -> Bool {
        let prefix = "\(snapshotKey)."
        guard key.hasPrefix(prefix) else { return false }
        let suffix = String(key.dropFirst(prefix.count))
        return suffix == "default"
            || (suffix.count == 64
                && suffix.allSatisfy({ $0.isASCII && $0.isHexDigit }))
    }

    @discardableResult
    static func save(
        _ snapshot: TripWidgetSnapshot,
        key: String = "\(snapshotKey).default",
        defaults: UserDefaults? = nil
    ) -> Bool {
        guard
            let defaults = defaults ?? UserDefaults(suiteName: appGroupIdentifier),
            let data = try? JSONEncoder().encode(snapshot)
        else {
            return false
        }
        defaults.set(data, forKey: key)
        defaults.set(key, forKey: activeSnapshotKey)
        return true
    }

    static func clear(key: String? = nil, defaults: UserDefaults? = nil) {
        guard let defaults = defaults ?? UserDefaults(suiteName: appGroupIdentifier)
        else { return }
        let selectedKey = defaults.string(forKey: activeSnapshotKey)
        let keyToRemove = key ?? selectedKey
        if let keyToRemove {
            defaults.removeObject(forKey: keyToRemove)
        }
        // Removes pre-P40 state and makes an unselected snapshot unreadable.
        defaults.removeObject(forKey: snapshotKey)
        if key == nil || key == selectedKey {
            defaults.removeObject(forKey: activeSnapshotKey)
        }
    }
}
