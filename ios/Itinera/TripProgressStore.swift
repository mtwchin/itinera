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

/// Device-local trip progress. This intentionally stays separate from the
/// itinerary payload, allowing a refreshed offline trip to retain its state.
actor TripProgressStore {
    private struct Envelope: Codable {
        let schemaVersion: Int
        let records: [TripStopProgress]
    }

    private static let currentSchemaVersion = 1

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedRecords: [TripStopProgress]?

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

    static func live() -> TripProgressStore {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return TripProgressStore(
            fileURL: root
                .appending(path: "Itinera", directoryHint: .isDirectory)
                .appending(path: "trip-progress-v1.json")
        )
    }

    func progress(for tripID: String) throws -> [TripStopID: TripStopStatus] {
        Dictionary(
            uniqueKeysWithValues: try all()
                .filter { $0.stopID.tripID == tripID }
                .map { ($0.stopID, $0.status) }
        )
    }

    func status(for stopID: TripStopID) throws -> TripStopStatus {
        try all().first { $0.stopID == stopID }?.status ?? .upcoming
    }

    func set(
        _ status: TripStopStatus,
        for stopID: TripStopID,
        updatedAt: Date = Date()
    ) throws {
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
        try persist(records)
    }

    func removeProgress(for tripID: String) throws {
        try persist(try all().filter { $0.stopID.tripID != tripID })
    }

    func removeAll() throws {
        cachedRecords = []
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
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

    private func persist(_ records: [TripStopProgress]) throws {
        let sorted = records.sorted {
            if $0.stopID.tripID != $1.stopID.tripID {
                return $0.stopID.tripID < $1.stopID.tripID
            }
            if $0.stopID.day != $1.stopID.day {
                return $0.stopID.day < $1.stopID.day
            }
            return $0.stopID.activityID < $1.stopID.activityID
        }
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var directoryValues = URLResourceValues()
        directoryValues.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(directoryValues)
        try encoder.encode(
            Envelope(schemaVersion: Self.currentSchemaVersion, records: sorted)
        ).write(to: fileURL, options: [.atomic])
        #if os(iOS)
        try fileManager.setAttributes(
            [
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication
            ],
            ofItemAtPath: fileURL.path
        )
        #endif
        cachedRecords = sorted
    }
}
