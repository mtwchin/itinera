import Foundation

enum TripStopStatus: String, Codable, CaseIterable, Sendable {
    case upcoming
    case completed
    case skipped
}

struct TripStopID: Codable, Hashable, Sendable {
    let tripID: String
    let day: Int
    let activityID: String

    init(tripID: String, day: Int, activity: Activity) {
        self.tripID = tripID
        self.day = day
        activityID = activity.id
    }
}

struct TripStopProgress: Codable, Hashable, Sendable {
    let stopID: TripStopID
    let status: TripStopStatus
    let updatedAt: Date
}

/// An immutable, identity-bound capability for one private library's trip
/// progress. Callers cannot use it to select whichever namespace happens to
/// be current later, and scoped read results remain fenced at publication.
struct SessionBoundTripProgressStore: Sendable {
    let lease: IdentityLease
    private let store: TripProgressStore
    private let identityCoordinator: IdentityCoordinator

    init(
        store: TripProgressStore,
        lease: IdentityLease,
        identityCoordinator: IdentityCoordinator
    ) {
        self.store = store
        self.lease = lease
        self.identityCoordinator = identityCoordinator
    }

    func progress(
        for tripID: String
    ) async throws -> IdentityScopedValue<[TripStopID: TripStopStatus]> {
        let value = try await store.progress(for: tripID, lease: lease)
        return IdentityScopedValue(value: value, lease: lease)
    }

    func status(
        for stopID: TripStopID
    ) async throws -> IdentityScopedValue<TripStopStatus> {
        let value = try await store.status(for: stopID, lease: lease)
        return IdentityScopedValue(value: value, lease: lease)
    }

    func set(
        _ status: TripStopStatus,
        for stopID: TripStopID,
        updatedAt: Date = Date()
    ) async throws {
        try await store.set(
            status,
            for: stopID,
            updatedAt: updatedAt,
            lease: lease
        )
    }

    func canPublish<Value: Sendable>(
        _ scopedValue: IdentityScopedValue<Value>
    ) async -> Bool {
        guard scopedValue.lease == lease else { return false }
        return await identityCoordinator.isCurrent(lease)
    }

    func isCurrent() async -> Bool {
        await identityCoordinator.isCurrent(lease)
    }
}

/// Device-local trip progress. This intentionally stays separate from the
/// itinerary payload, allowing a refreshed offline trip to retain its state.
actor TripProgressStore {
    private struct Envelope: Codable {
        let schemaVersion: Int
        let records: [TripStopProgress]
    }

    private static let currentSchemaVersion = 1

    private let fileURL: URL
    private let boundLease: IdentityLease
    private let identityCoordinator: IdentityCoordinator
    private let beforeRead: PrincipalStorageBeforeCommit?
    private let beforeCommit: PrincipalStorageBeforeCommit?
    private var fileManager: FileManager { .default }
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedRecords: [TripStopProgress]?

    init(
        fileURL: URL,
        lease: IdentityLease,
        identityCoordinator: IdentityCoordinator,
        beforeRead: PrincipalStorageBeforeCommit? = nil,
        beforeCommit: PrincipalStorageBeforeCommit? = nil
    ) {
        self.fileURL = fileURL
        boundLease = lease
        self.identityCoordinator = identityCoordinator
        self.beforeRead = beforeRead
        self.beforeCommit = beforeCommit

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func progress(
        for tripID: String,
        lease: IdentityLease
    ) async throws -> [TripStopID: TripStopStatus] {
        try await validateRead(lease)
        if let beforeRead { await beforeRead(lease) }
        let value = Dictionary(
            uniqueKeysWithValues: try all()
                .filter { $0.stopID.tripID == tripID }
                .map { ($0.stopID, $0.status) }
        )
        try await validateRead(lease)
        return value
    }

    func status(
        for stopID: TripStopID,
        lease: IdentityLease
    ) async throws -> TripStopStatus {
        try await validateRead(lease)
        if let beforeRead { await beforeRead(lease) }
        let value = try all().first { $0.stopID == stopID }?.status
            ?? .upcoming
        try await validateRead(lease)
        return value
    }

    func set(
        _ status: TripStopStatus,
        for stopID: TripStopID,
        updatedAt: Date = Date(),
        lease: IdentityLease
    ) async throws {
        try await validateMutation(lease)
        var records = try all().filter { $0.stopID != stopID }
        if status != .upcoming {
            records.append(
                TripStopProgress(
                    stopID: stopID,
                    status: status,
                    updatedAt: updatedAt
                )
            )
        }
        try await persist(records, lease: lease)
    }

    func removeProgress(
        for tripID: String,
        lease: IdentityLease
    ) async throws {
        try await validateMutation(lease)
        try await persist(
            try all().filter { $0.stopID.tripID != tripID },
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
        cachedRecords = []
    }

    private func all() throws -> [TripStopProgress] {
        if let cachedRecords { return cachedRecords }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            cachedRecords = []
            return []
        }
        let envelope = try decoder.decode(
            Envelope.self,
            from: Data(contentsOf: fileURL)
        )
        guard envelope.schemaVersion == Self.currentSchemaVersion else {
            throw CompletedTripCacheError.unsupportedSchemaVersion(
                envelope.schemaVersion
            )
        }
        cachedRecords = envelope.records
        return envelope.records
    }

    private func persist(
        _ records: [TripStopProgress],
        lease: IdentityLease
    ) async throws {
        let sorted = records.sorted {
            if $0.stopID.tripID != $1.stopID.tripID {
                return $0.stopID.tripID < $1.stopID.tripID
            }
            if $0.stopID.day != $1.stopID.day {
                return $0.stopID.day < $1.stopID.day
            }
            return $0.stopID.activityID < $1.stopID.activityID
        }
        let encoded = try encoder.encode(
            Envelope(schemaVersion: Self.currentSchemaVersion, records: sorted)
        )
        let fileCommit = PrivateStorageFileCommit.replaceProtected(
            data: encoded,
            fileURL: fileURL
        )
        if let beforeCommit { await beforeCommit(lease) }
        try await identityCoordinator.commit(ifCurrent: lease) {
            try fileCommit.perform()
        }
        cachedRecords = sorted
    }

    private func validateMutation(_ lease: IdentityLease) async throws {
        guard lease == boundLease else {
            throw IdentityCoordinatorError.staleIdentity
        }
        try await identityCoordinator.validate(lease)
    }

    private func validateRead(_ lease: IdentityLease) async throws {
        guard lease == boundLease else {
            throw IdentityCoordinatorError.staleIdentity
        }
        try await identityCoordinator.validate(lease)
    }
}
