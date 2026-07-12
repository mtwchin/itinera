import Foundation

struct PendingJobRecord: Codable, Hashable, Identifiable, Sendable {
    let jobID: String
    let title: String?
    let createdAt: Date

    var id: String { jobID }
}

actor PendingJobStore {
    private let fileURL: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedRecords: [PendingJobRecord]?

    init(fileURL: URL) {
        self.fileURL = fileURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    static func live() -> PendingJobStore {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return PendingJobStore(
            fileURL: root
                .appending(path: "Itinera", directoryHint: .isDirectory)
                .appending(path: "pending-jobs.json")
        )
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
    func add(jobID: String, title: String?, createdAt: Date = Date()) throws -> [PendingJobRecord] {
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
        return try persist(records)
    }

    @discardableResult
    func remove(jobID: String) throws -> [PendingJobRecord] {
        let records = try all().filter { $0.jobID != jobID }
        return try persist(records)
    }

    @discardableResult
    func replace(with records: [PendingJobRecord]) throws -> [PendingJobRecord] {
        try persist(records)
    }

    private func persist(_ records: [PendingJobRecord]) throws -> [PendingJobRecord] {
        let sorted = records.sorted { $0.createdAt > $1.createdAt }
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(sorted).write(to: fileURL, options: [.atomic])
        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
        #endif
        cachedRecords = sorted
        return sorted
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
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedRecords: [PendingSubmissionRecord]?

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    static func live(fileManager: FileManager = .default) -> PendingSubmissionStore {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return PendingSubmissionStore(
            fileURL: root
                .appending(path: "Itinera", directoryHint: .isDirectory)
                .appending(path: "pending-submissions.json"),
            fileManager: fileManager
        )
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
        createdAt: Date = Date()
    ) throws -> PendingSubmissionRecord {
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
        try persist(records)
        return record
    }

    func remove(idempotencyKey: UUID) throws {
        try persist(try all().filter { $0.idempotencyKey != idempotencyKey })
    }

    private func persist(_ records: [PendingSubmissionRecord]) throws {
        let sorted = records.sorted { $0.createdAt > $1.createdAt }
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(sorted).write(to: fileURL, options: [.atomic])
        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
        #endif
        cachedRecords = sorted
    }
}
