import Foundation

struct CompletedTripCacheSnapshot: Sendable {
    let trips: [SavedItinerary]
    let refreshedAt: Date

    func isStale(
        at date: Date = Date(),
        maximumAge: TimeInterval = 6 * 60 * 60
    ) -> Bool {
        date.timeIntervalSince(refreshedAt) > maximumAge
    }
}

enum CompletedTripCacheError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
}

/// A versioned, file-protected offline copy of completed itineraries.
///
/// Only successful trips with a result are stored. Pending and failed jobs remain
/// server-owned state so the cache can never make a stale job look actionable.
actor CompletedTripCache {
    private struct Envelope: Codable {
        let schemaVersion: Int
        let refreshedAt: Date
        let trips: [SavedItinerary]
    }

    private static let currentSchemaVersion = 1

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedSnapshot: CompletedTripCacheSnapshot?

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    static func live() -> CompletedTripCache {
        let root = storageRoot()
        return CompletedTripCache(
            fileURL: root
                .appending(path: "Itinera", directoryHint: .isDirectory)
                .appending(path: "completed-trips-v1.json")
        )
    }

    static func live(
        scope: LocalPrincipalScope,
        root: URL? = nil
    ) -> CompletedTripCache {
        CompletedTripCache(
            fileURL: scope.fileURL(
                root: root ?? storageRoot(),
                name: "completed-trips-v1.json"
            )
        )
    }

    private static func storageRoot() -> URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
    }

    func load() throws -> CompletedTripCacheSnapshot? {
        if let cachedSnapshot { return cachedSnapshot }
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

        let envelope = try decoder.decode(
            Envelope.self,
            from: Data(contentsOf: fileURL)
        )
        guard envelope.schemaVersion == Self.currentSchemaVersion else {
            throw CompletedTripCacheError.unsupportedSchemaVersion(
                envelope.schemaVersion
            )
        }

        let snapshot = CompletedTripCacheSnapshot(
            trips: Self.cacheableTrips(from: envelope.trips),
            refreshedAt: envelope.refreshedAt
        )
        cachedSnapshot = snapshot
        return snapshot
    }

    @discardableResult
    func replace(
        with trips: [SavedItinerary],
        refreshedAt: Date = Date()
    ) throws -> CompletedTripCacheSnapshot {
        try persist(
            trips: Self.cacheableTrips(from: trips),
            refreshedAt: refreshedAt
        )
    }

    @discardableResult
    func upsert(
        _ trip: SavedItinerary,
        refreshedAt: Date = Date()
    ) throws -> CompletedTripCacheSnapshot {
        guard trip.status == .succeeded, trip.result != nil else {
            return try load() ?? persist(trips: [], refreshedAt: refreshedAt)
        }

        let existingSnapshot = try load()
        var trips = existingSnapshot?.trips ?? []
        trips.removeAll { $0.jobId == trip.jobId }
        trips.append(trip)
        // An upsert makes a new result available offline, but it is not a full
        // server-library refresh. Keep the last successful sync time truthful.
        return try persist(
            trips: trips,
            refreshedAt: existingSnapshot?.refreshedAt ?? refreshedAt
        )
    }

    @discardableResult
    func rename(
        jobID: String,
        title: String
    ) throws -> CompletedTripCacheSnapshot? {
        guard let snapshot = try load() else { return nil }
        var trips = snapshot.trips
        guard let index = trips.firstIndex(where: { $0.jobId == jobID }) else {
            return snapshot
        }
        trips[index].title = title
        return try persist(trips: trips, refreshedAt: snapshot.refreshedAt)
    }

    @discardableResult
    func setArchivedAt(
        jobID: String,
        archivedAt: String?
    ) throws -> CompletedTripCacheSnapshot? {
        guard let snapshot = try load() else { return nil }
        var trips = snapshot.trips
        guard let index = trips.firstIndex(where: { $0.jobId == jobID }) else {
            return snapshot
        }
        trips[index].archivedAt = archivedAt
        return try persist(trips: trips, refreshedAt: snapshot.refreshedAt)
    }

    @discardableResult
    func remove(jobID: String) throws -> CompletedTripCacheSnapshot? {
        guard let snapshot = try load() else { return nil }
        let trips = snapshot.trips.filter { $0.jobId != jobID }
        guard trips.count != snapshot.trips.count else { return snapshot }
        return try persist(trips: trips, refreshedAt: snapshot.refreshedAt)
    }

    func removeAll() throws {
        cachedSnapshot = nil
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    private func persist(
        trips: [SavedItinerary],
        refreshedAt: Date
    ) throws -> CompletedTripCacheSnapshot {
        let sortedTrips = Self.sorted(trips)
        let envelope = Envelope(
            schemaVersion: Self.currentSchemaVersion,
            refreshedAt: refreshedAt,
            trips: sortedTrips
        )
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var directoryValues = URLResourceValues()
        directoryValues.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(directoryValues)

        try encoder.encode(envelope).write(to: fileURL, options: [.atomic])
        #if os(iOS)
        try fileManager.setAttributes(
            [
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication
            ],
            ofItemAtPath: fileURL.path
        )
        #endif

        let snapshot = CompletedTripCacheSnapshot(
            trips: sortedTrips,
            refreshedAt: refreshedAt
        )
        cachedSnapshot = snapshot
        return snapshot
    }

    private static func cacheableTrips(
        from trips: [SavedItinerary]
    ) -> [SavedItinerary] {
        sorted(
            trips.filter {
                $0.status == .succeeded
                    && $0.result != nil
            }
        )
    }

    private static func sorted(
        _ trips: [SavedItinerary]
    ) -> [SavedItinerary] {
        trips.sorted {
            if $0.createdAt == $1.createdAt { return $0.jobId < $1.jobId }
            return $0.createdAt > $1.createdAt
        }
    }
}
