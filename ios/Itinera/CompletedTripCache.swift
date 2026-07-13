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
    private let boundLease: IdentityLease
    private let identityCoordinator: IdentityCoordinator
    private let beforeCommit: PrincipalStorageBeforeCommit?
    private var fileManager: FileManager { .default }
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedSnapshot: CompletedTripCacheSnapshot?

    init(
        fileURL: URL,
        lease: IdentityLease,
        identityCoordinator: IdentityCoordinator,
        beforeCommit: PrincipalStorageBeforeCommit? = nil
    ) {
        self.fileURL = fileURL
        boundLease = lease
        self.identityCoordinator = identityCoordinator
        self.beforeCommit = beforeCommit

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
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
        refreshedAt: Date = Date(),
        lease: IdentityLease
    ) async throws -> CompletedTripCacheSnapshot {
        try await validateMutation(lease)
        return try await persist(
            trips: Self.cacheableTrips(from: trips),
            refreshedAt: refreshedAt,
            lease: lease
        )
    }

    @discardableResult
    func upsert(
        _ trip: SavedItinerary,
        refreshedAt: Date = Date(),
        lease: IdentityLease
    ) async throws -> CompletedTripCacheSnapshot {
        try await validateMutation(lease)
        guard trip.status == .succeeded, trip.result != nil else {
            if let snapshot = try load() { return snapshot }
            return try await persist(
                trips: [],
                refreshedAt: refreshedAt,
                lease: lease
            )
        }

        let existingSnapshot = try load()
        var trips = existingSnapshot?.trips ?? []
        trips.removeAll { $0.jobId == trip.jobId }
        trips.append(trip)
        // An upsert makes a new result available offline, but it is not a full
        // server-library refresh. Keep the last successful sync time truthful.
        return try await persist(
            trips: trips,
            refreshedAt: existingSnapshot?.refreshedAt ?? refreshedAt,
            lease: lease
        )
    }

    @discardableResult
    func rename(
        jobID: String,
        title: String,
        lease: IdentityLease
    ) async throws -> CompletedTripCacheSnapshot? {
        try await validateMutation(lease)
        guard let snapshot = try load() else { return nil }
        var trips = snapshot.trips
        guard let index = trips.firstIndex(where: { $0.jobId == jobID }) else {
            return snapshot
        }
        trips[index].title = title
        return try await persist(
            trips: trips,
            refreshedAt: snapshot.refreshedAt,
            lease: lease
        )
    }

    @discardableResult
    func setArchivedAt(
        jobID: String,
        archivedAt: String?,
        lease: IdentityLease
    ) async throws -> CompletedTripCacheSnapshot? {
        try await validateMutation(lease)
        guard let snapshot = try load() else { return nil }
        var trips = snapshot.trips
        guard let index = trips.firstIndex(where: { $0.jobId == jobID }) else {
            return snapshot
        }
        trips[index].archivedAt = archivedAt
        return try await persist(
            trips: trips,
            refreshedAt: snapshot.refreshedAt,
            lease: lease
        )
    }

    @discardableResult
    func remove(
        jobID: String,
        lease: IdentityLease
    ) async throws -> CompletedTripCacheSnapshot? {
        try await validateMutation(lease)
        guard let snapshot = try load() else { return nil }
        let trips = snapshot.trips.filter { $0.jobId != jobID }
        guard trips.count != snapshot.trips.count else { return snapshot }
        return try await persist(
            trips: trips,
            refreshedAt: snapshot.refreshedAt,
            lease: lease
        )
    }

    func removeAll(lease: IdentityLease) async throws {
        try await validateMutation(lease)
        let fileCommit = PrivateStorageFileCommit.remove(fileURL)
        if let beforeCommit { await beforeCommit(lease) }
        try await identityCoordinator.commit(ifCurrent: lease) {
            try fileCommit.perform()
        }
        cachedSnapshot = nil
    }

    private func persist(
        trips: [SavedItinerary],
        refreshedAt: Date,
        lease: IdentityLease
    ) async throws -> CompletedTripCacheSnapshot {
        let sortedTrips = Self.sorted(trips)
        let envelope = Envelope(
            schemaVersion: Self.currentSchemaVersion,
            refreshedAt: refreshedAt,
            trips: sortedTrips
        )
        let snapshot = CompletedTripCacheSnapshot(
            trips: sortedTrips,
            refreshedAt: refreshedAt
        )
        let encoded = try encoder.encode(envelope)
        let fileCommit = PrivateStorageFileCommit.replaceProtected(
            data: encoded,
            fileURL: fileURL
        )
        if let beforeCommit { await beforeCommit(lease) }
        try await identityCoordinator.commit(ifCurrent: lease) {
            try fileCommit.perform()
        }
        cachedSnapshot = snapshot
        return snapshot
    }

    private func validateMutation(_ lease: IdentityLease) async throws {
        guard lease == boundLease else {
            throw IdentityCoordinatorError.staleIdentity
        }
        try await identityCoordinator.validate(lease)
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
