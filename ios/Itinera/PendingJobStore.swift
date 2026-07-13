import Foundation

struct PendingJobRecord: Codable, Hashable, Identifiable, Sendable {
    let jobID: String
    let title: String?
    let createdAt: Date

    var id: String { jobID }
}

actor PendingJobStore {
    private let fileURL: URL
    private let boundLease: IdentityLease
    private let identityCoordinator: IdentityCoordinator
    private let beforeCommit: PrincipalStorageBeforeCommit?
    private var fileManager: FileManager { .default }
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedRecords: [PendingJobRecord]?

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
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func all() throws -> [PendingJobRecord] {
        if let cachedRecords { return cachedRecords }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            cachedRecords = []
            return []
        }
        let records = try decoder.decode([PendingJobRecord].self, from: Data(contentsOf: fileURL))
            .sorted { $0.createdAt > $1.createdAt }
        cachedRecords = records
        return records
    }

    @discardableResult
    func add(
        jobID: String,
        title: String?,
        createdAt: Date = Date(),
        lease: IdentityLease,
        serverOperationLease: PrivateServerOperationLease
    ) async throws -> [PendingJobRecord] {
        try await validateMutation(lease, serverOperationLease)
        var records = try all()
        if let index = records.firstIndex(where: { $0.jobID == jobID }) {
            let existing = records[index]
            records[index] = PendingJobRecord(
                jobID: jobID,
                title: title ?? existing.title,
                createdAt: existing.createdAt
            )
        } else {
            records.append(PendingJobRecord(jobID: jobID, title: title, createdAt: createdAt))
        }
        return try await persist(
            records,
            lease: lease,
            serverOperationLease: serverOperationLease
        )
    }

    @discardableResult
    func remove(
        jobID: String,
        lease: IdentityLease,
        serverOperationLease: PrivateServerOperationLease
    ) async throws -> [PendingJobRecord] {
        try await validateMutation(lease, serverOperationLease)
        let records = try all().filter { $0.jobID != jobID }
        return try await persist(
            records,
            lease: lease,
            serverOperationLease: serverOperationLease
        )
    }

    @discardableResult
    func replace(
        with records: [PendingJobRecord],
        lease: IdentityLease,
        serverOperationLease: PrivateServerOperationLease
    ) async throws -> [PendingJobRecord] {
        try await validateMutation(lease, serverOperationLease)
        return try await persist(
            records,
            lease: lease,
            serverOperationLease: serverOperationLease
        )
    }

    func removeAll(
        lease: IdentityLease,
        serverOperationLease: PrivateServerOperationLease
    ) async throws {
        try await validateMutation(lease, serverOperationLease)
        let fileCommit = PrivateStorageFileCommit.remove(fileURL)
        if let beforeCommit { await beforeCommit(lease) }
        try await identityCoordinator.commit(
            ifServerOperationCurrent: serverOperationLease
        ) {
            try fileCommit.perform()
        }
        cachedRecords = []
    }

    private func persist(
        _ records: [PendingJobRecord],
        lease: IdentityLease,
        serverOperationLease: PrivateServerOperationLease
    ) async throws -> [PendingJobRecord] {
        let sorted = records.sorted { $0.createdAt > $1.createdAt }
        let encoded = try encoder.encode(sorted)
        let fileCommit = PrivateStorageFileCommit.replaceProtected(
            data: encoded,
            fileURL: fileURL
        )
        if let beforeCommit { await beforeCommit(lease) }
        try await identityCoordinator.commit(
            ifServerOperationCurrent: serverOperationLease
        ) {
            try fileCommit.perform()
        }
        cachedRecords = sorted
        return sorted
    }

    private func validateMutation(
        _ lease: IdentityLease,
        _ serverOperationLease: PrivateServerOperationLease
    ) async throws {
        guard lease == boundLease,
              serverOperationLease.identityLease == lease else {
            throw IdentityCoordinatorError.staleIdentity
        }
        try await identityCoordinator.validate(serverOperationLease)
    }
}

struct PendingSubmissionRecord: Codable, Equatable, Identifiable, Sendable {
    let idempotencyKey: UUID
    let request: GenerateItineraryRequest
    let title: String
    let createdAt: Date

    var id: UUID { idempotencyKey }
}

actor PendingSubmissionStore {
    private let fileURL: URL
    private let boundLease: IdentityLease
    private let identityCoordinator: IdentityCoordinator
    private let beforeCommit: PrincipalStorageBeforeCommit?
    private var fileManager: FileManager { .default }
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedRecords: [PendingSubmissionRecord]?

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
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func all() throws -> [PendingSubmissionRecord] {
        if let cachedRecords { return cachedRecords }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            cachedRecords = []
            return []
        }
        let records = try decoder.decode(
            [PendingSubmissionRecord].self,
            from: Data(contentsOf: fileURL)
        ).sorted { $0.createdAt > $1.createdAt }
        cachedRecords = records
        return records
    }

    func record(
        for request: GenerateItineraryRequest,
        title: String,
        createdAt: Date = Date(),
        lease: IdentityLease,
        serverOperationLease: PrivateServerOperationLease
    ) async throws -> PendingSubmissionRecord {
        try await validateMutation(lease, serverOperationLease)
        var records = try all()
        if let existing = records.first(where: { $0.request == request }) {
            return existing
        }
        let record = PendingSubmissionRecord(
            idempotencyKey: UUID(),
            request: request,
            title: title,
            createdAt: createdAt
        )
        records.append(record)
        try await persist(
            records,
            lease: lease,
            serverOperationLease: serverOperationLease
        )
        return record
    }

    func remove(
        idempotencyKey: UUID,
        lease: IdentityLease,
        serverOperationLease: PrivateServerOperationLease
    ) async throws {
        try await validateMutation(lease, serverOperationLease)
        try await persist(
            try all().filter { $0.idempotencyKey != idempotencyKey },
            lease: lease,
            serverOperationLease: serverOperationLease
        )
    }

    func removeAll(
        lease: IdentityLease,
        serverOperationLease: PrivateServerOperationLease
    ) async throws {
        try await validateMutation(lease, serverOperationLease)
        let fileCommit = PrivateStorageFileCommit.remove(fileURL)
        if let beforeCommit { await beforeCommit(lease) }
        try await identityCoordinator.commit(
            ifServerOperationCurrent: serverOperationLease
        ) {
            try fileCommit.perform()
        }
        cachedRecords = []
    }

    private func persist(
        _ records: [PendingSubmissionRecord],
        lease: IdentityLease,
        serverOperationLease: PrivateServerOperationLease
    ) async throws {
        let sorted = records.sorted { $0.createdAt > $1.createdAt }
        let encoded = try encoder.encode(sorted)
        let fileCommit = PrivateStorageFileCommit.replaceProtected(
            data: encoded,
            fileURL: fileURL
        )
        if let beforeCommit { await beforeCommit(lease) }
        try await identityCoordinator.commit(
            ifServerOperationCurrent: serverOperationLease
        ) {
            try fileCommit.perform()
        }
        cachedRecords = sorted
    }

    private func validateMutation(
        _ lease: IdentityLease,
        _ serverOperationLease: PrivateServerOperationLease
    ) async throws {
        guard lease == boundLease,
              serverOperationLease.identityLease == lease else {
            throw IdentityCoordinatorError.staleIdentity
        }
        try await identityCoordinator.validate(serverOperationLease)
    }
}
