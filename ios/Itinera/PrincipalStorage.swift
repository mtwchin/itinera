import CryptoKit
import Foundation

typealias PrincipalStorageBeforeCommit =
    @Sendable (IdentityLease) async -> Void

typealias PrincipalStorageBeforePurgeCommit =
    @Sendable (PrincipalScope) throws -> Void

typealias PrincipalStorageSecureQuarantineFile =
    (URL, FileManager) throws -> Void

enum PrivateStorageDefaultsDomainError: Error, Equatable {
    case unavailableSuite
}

/// A value-semantic description of the defaults domain. The non-Sendable
/// `UserDefaults` instance is created only where the operation executes and is
/// never carried across an actor boundary.
struct PrivateStorageDefaultsDomain: Hashable, Sendable {
    private let suiteName: String?

    static let standard = Self(suiteName: nil)

    init(suiteName: String) throws {
        guard !suiteName.isEmpty,
              UserDefaults(suiteName: suiteName) != nil else {
            throw PrivateStorageDefaultsDomainError.unavailableSuite
        }
        self.suiteName = suiteName
    }

    private init(suiteName: String?) {
        self.suiteName = suiteName
    }

    func makeDefaults() -> UserDefaults {
        guard let suiteName else { return .standard }
        // The public initializer proved this suite can be opened. Treat a
        // later Foundation contract violation as a programmer error rather
        // than falling back to another principal's defaults domain.
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure(
                "The configured private defaults suite became unavailable."
            )
        }
        return defaults
    }
}

enum PrivateStorageFileCommit: Sendable {
    case remove(URL)
    case replaceProtected(data: Data, fileURL: URL)

    func perform() throws {
        let fileManager = FileManager.default
        switch self {
        case .remove(let fileURL):
            guard fileManager.fileExists(atPath: fileURL.path) else { return }
            try fileManager.removeItem(at: fileURL)
        case .replaceProtected(let data, let fileURL):
            try PrivateStorageFileSystem.prepareDirectory(
                at: fileURL.deletingLastPathComponent(),
                fileManager: fileManager
            )
            try PrivateStorageFileSystem.writeProtectedAtomically(
                data,
                to: fileURL,
                fileManager: fileManager
            )
        }
    }
}

enum PrivateStorageDefaultsCommit: Sendable {
    case clearScope(PrincipalScope, domain: PrivateStorageDefaultsDomain)
    case setData(Data, key: String, domain: PrivateStorageDefaultsDomain)
    case setStrings(
        [String],
        key: String,
        domain: PrivateStorageDefaultsDomain
    )

    func perform() {
        switch self {
        case .clearScope(let scope, let domain):
            ItineraLocalDataCleaner.clearCurrentScope(
                scope,
                defaults: domain.makeDefaults()
            )
        case .setData(let data, let key, let domain):
            domain.makeDefaults().set(data, forKey: key)
        case .setStrings(let strings, let key, let domain):
            domain.makeDefaults().set(strings, forKey: key)
        }
    }
}

enum PrivateStorageFileSystem {
    static func writeProtectedAtomically(
        _ data: Data,
        to fileURL: URL,
        fileManager: FileManager
    ) throws {
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: fileURL, options: options)
        try secureFile(at: fileURL, fileManager: fileManager)
    }

    static func prepareDirectory(
        at directoryURL: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try excludeFromBackup(directoryURL)
        #if os(iOS)
        try fileManager.setAttributes(
            [
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication
            ],
            ofItemAtPath: directoryURL.path
        )
        #endif
    }

    static func secureFile(
        at fileURL: URL,
        fileManager: FileManager
    ) throws {
        try excludeFromBackup(fileURL)
        #if os(iOS)
        try fileManager.setAttributes(
            [
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication
            ],
            ofItemAtPath: fileURL.path
        )
        #endif
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}

struct PrincipalStorageLayout: Equatable, Sendable {
    static let completedTripsFileName = "completed-trips-v1.json"
    static let tripProgressFileName = "trip-progress-v1.json"
    static let pendingJobsFileName = "pending-jobs.json"
    static let pendingSubmissionsFileName = "pending-submissions.json"

    static let legacyFileNames = [
        completedTripsFileName,
        tripProgressFileName,
        pendingJobsFileName,
        pendingSubmissionsFileName
    ]

    let scope: PrincipalScope
    let itineraDirectory: URL
    let privateDirectory: URL
    let scopeDirectory: URL
    let completedTripsURL: URL
    let tripProgressURL: URL
    let pendingJobsURL: URL
    let pendingSubmissionsURL: URL

    init(applicationSupportDirectory: URL, scope: PrincipalScope) {
        self.scope = scope
        itineraDirectory = applicationSupportDirectory
            .appending(path: "Itinera", directoryHint: .isDirectory)
        privateDirectory = itineraDirectory
            .appending(path: "private", directoryHint: .isDirectory)
            .appending(path: "v1", directoryHint: .isDirectory)
        scopeDirectory = privateDirectory
            .appending(path: scope.digest, directoryHint: .isDirectory)
        completedTripsURL = scopeDirectory.appending(
            path: Self.completedTripsFileName
        )
        tripProgressURL = scopeDirectory.appending(
            path: Self.tripProgressFileName
        )
        pendingJobsURL = scopeDirectory.appending(
            path: Self.pendingJobsFileName
        )
        pendingSubmissionsURL = scopeDirectory.appending(
            path: Self.pendingSubmissionsFileName
        )
    }
}

/// One immutable binding between an established principal and fresh actor
/// instances. A set must never be rebound or reused for another scope.
struct PrincipalStoreSet: Sendable {
    let lease: IdentityLease
    let layout: PrincipalStorageLayout
    let completedTripCache: CompletedTripCache
    let tripProgressStore: TripProgressStore
    let pendingJobStore: PendingJobStore
    let pendingSubmissionStore: PendingSubmissionStore
    let localDataStore: PrincipalLocalDataStore

    var scope: PrincipalScope { lease.scope }
}

actor PrincipalLocalDataStore {
    private let boundLease: IdentityLease
    private let defaultsDomain: PrivateStorageDefaultsDomain
    private let identityCoordinator: IdentityCoordinator
    private let beforeCommit: PrincipalStorageBeforeCommit?

    init(
        lease: IdentityLease,
        defaultsDomain: PrivateStorageDefaultsDomain,
        identityCoordinator: IdentityCoordinator,
        beforeCommit: PrincipalStorageBeforeCommit? = nil
    ) {
        boundLease = lease
        self.defaultsDomain = defaultsDomain
        self.identityCoordinator = identityCoordinator
        self.beforeCommit = beforeCommit
    }

    func tripDraftData() -> Data {
        defaultsDomain.makeDefaults().data(
            forKey: ItineraLocalDataKeys.tripDraft(for: boundLease.scope)
        ) ?? Data()
    }

    func saveTripDraftData(
        _ data: Data,
        lease: IdentityLease
    ) async throws {
        try requireBound(lease)
        try await identityCoordinator.validate(lease)
        let key = ItineraLocalDataKeys.tripDraft(for: boundLease.scope)
        let commit = PrivateStorageDefaultsCommit.setData(
            data,
            key: key,
            domain: defaultsDomain
        )
        if let beforeCommit { await beforeCommit(lease) }
        try await identityCoordinator.commit(ifCurrent: lease) {
            commit.perform()
        }
    }

    func lockedActivityIDs(for tripID: String) -> Set<String> {
        Set(
            defaultsDomain.makeDefaults().stringArray(
                forKey: ItineraLocalDataKeys.lockedStops(
                    for: tripID,
                    scope: boundLease.scope
                )
            ) ?? []
        )
    }

    func saveLockedActivityIDs(
        _ identifiers: Set<String>,
        for tripID: String,
        lease: IdentityLease
    ) async throws {
        try requireBound(lease)
        try await identityCoordinator.validate(lease)
        let key = ItineraLocalDataKeys.lockedStops(
            for: tripID,
            scope: boundLease.scope
        )
        let sortedIdentifiers = identifiers.sorted()
        let commit = PrivateStorageDefaultsCommit.setStrings(
            sortedIdentifiers,
            key: key,
            domain: defaultsDomain
        )
        if let beforeCommit { await beforeCommit(lease) }
        try await identityCoordinator.commit(ifCurrent: lease) {
            commit.perform()
        }
    }

    private func requireBound(_ lease: IdentityLease) throws {
        guard lease == boundLease else {
            throw IdentityCoordinatorError.staleIdentity
        }
    }
}

struct LegacyPrivateDataQuarantineReport: Equatable, Sendable {
    let retainedFileURLs: [URL]
    let removedDefaultsCount: Int
}

/// Value-semantic transition capability kept separate from the factory's
/// synchronous FileManager-backed quarantine work. AppState can safely carry
/// this capability across its MainActor-to-IdentityCoordinator await without
/// sending the non-Sendable factory or FileManager.
struct PrincipalStoragePurger: Sendable {
    let applicationSupportDirectory: URL
    let identityCoordinator: IdentityCoordinator
    let beforePurgeCommit: PrincipalStorageBeforePurgeCommit?

    func purgeCurrentScope(
        _ scope: PrincipalScope,
        at transitionEpoch: UInt64,
        defaultsDomain: PrivateStorageDefaultsDomain
    ) async throws {
        let directory = PrincipalStorageLayout(
            applicationSupportDirectory: applicationSupportDirectory,
            scope: scope
        ).scopeDirectory
        let defaultsCommit = PrivateStorageDefaultsCommit.clearScope(
            scope,
            domain: defaultsDomain
        )
        let fileCommit = PrivateStorageFileCommit.remove(directory)
        try await identityCoordinator.commit(
            ifTransition: transitionEpoch
        ) {
            try beforePurgeCommit?(scope)
            defaultsCommit.perform()
            try fileCommit.perform()
        }
    }
}

/// Creates scope-bound private stores and owns the one-way legacy quarantine.
/// This value is immutable; each `makeStoreSet` call returns fresh actors.
struct PrincipalStorageFactory {
    let applicationSupportDirectory: URL
    private let fileManager: FileManager
    private let identityCoordinator: IdentityCoordinator
    private let beforeCommit: PrincipalStorageBeforeCommit?
    private let beforePurgeCommit: PrincipalStorageBeforePurgeCommit?
    private let secureQuarantineFile: PrincipalStorageSecureQuarantineFile

    init(
        applicationSupportDirectory: URL,
        fileManager: FileManager = .default,
        identityCoordinator: IdentityCoordinator,
        beforeCommit: PrincipalStorageBeforeCommit? = nil,
        beforePurgeCommit: PrincipalStorageBeforePurgeCommit? = nil,
        secureQuarantineFile: @escaping PrincipalStorageSecureQuarantineFile = {
            fileURL,
            fileManager in
            try PrivateStorageFileSystem.secureFile(
                at: fileURL,
                fileManager: fileManager
            )
        }
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.fileManager = fileManager
        self.identityCoordinator = identityCoordinator
        self.beforeCommit = beforeCommit
        self.beforePurgeCommit = beforePurgeCommit
        self.secureQuarantineFile = secureQuarantineFile
    }

    static func live(
        identityCoordinator: IdentityCoordinator,
        fileManager: FileManager = .default
    ) -> Self {
        let root = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return Self(
            applicationSupportDirectory: root,
            fileManager: fileManager,
            identityCoordinator: identityCoordinator
        )
    }

    func layout(for scope: PrincipalScope) -> PrincipalStorageLayout {
        PrincipalStorageLayout(
            applicationSupportDirectory: applicationSupportDirectory,
            scope: scope
        )
    }

    var purger: PrincipalStoragePurger {
        PrincipalStoragePurger(
            applicationSupportDirectory: applicationSupportDirectory,
            identityCoordinator: identityCoordinator,
            beforePurgeCommit: beforePurgeCommit
        )
    }

    func makeStoreSet(
        for lease: IdentityLease,
        defaultsDomain: PrivateStorageDefaultsDomain = .standard
    ) -> PrincipalStoreSet {
        let layout = layout(for: lease.scope)
        return PrincipalStoreSet(
            lease: lease,
            layout: layout,
            completedTripCache: CompletedTripCache(
                fileURL: layout.completedTripsURL,
                lease: lease,
                identityCoordinator: identityCoordinator,
                beforeCommit: beforeCommit
            ),
            tripProgressStore: TripProgressStore(
                fileURL: layout.tripProgressURL,
                lease: lease,
                identityCoordinator: identityCoordinator,
                beforeCommit: beforeCommit
            ),
            pendingJobStore: PendingJobStore(
                fileURL: layout.pendingJobsURL,
                lease: lease,
                identityCoordinator: identityCoordinator,
                beforeCommit: beforeCommit
            ),
            pendingSubmissionStore: PendingSubmissionStore(
                fileURL: layout.pendingSubmissionsURL,
                lease: lease,
                identityCoordinator: identityCoordinator,
                beforeCommit: beforeCommit
            ),
            localDataStore: PrincipalLocalDataStore(
                lease: lease,
                defaultsDomain: defaultsDomain,
                identityCoordinator: identityCoordinator,
                beforeCommit: beforeCommit
            )
        )
    }

    /// Moves ambiguous pre-D2 files out of every readable store location.
    /// Contents are treated as opaque bytes and are never decoded or replayed.
    @discardableResult
    func quarantineLegacyPrivateData(
        defaults: UserDefaults = .standard
    ) throws -> LegacyPrivateDataQuarantineReport {
        let itineraDirectory = applicationSupportDirectory
            .appending(path: "Itinera", directoryHint: .isDirectory)
        let quarantineDirectory = itineraDirectory
            .appending(path: "quarantine", directoryHint: .isDirectory)
            .appending(path: "unscoped-v1", directoryHint: .isDirectory)
        var retainedFileURLs: [URL] = []

        let sourceURLs = PrincipalStorageLayout.legacyFileNames.map {
            itineraDirectory.appending(path: $0)
        }
        let hasLegacySource = sourceURLs.contains {
            fileManager.fileExists(atPath: $0.path)
        }
        let hasRetainedQuarantine = fileManager.fileExists(
            atPath: quarantineDirectory.path
        )
        if hasLegacySource || hasRetainedQuarantine {
            try PrivateStorageFileSystem.prepareDirectory(
                at: quarantineDirectory,
                fileManager: fileManager
            )
            // A previous attempt may have created a protected copy and then
            // failed while applying backup exclusion. Re-secure every opaque
            // retained file before touching any new global source so retries
            // converge without silently accepting an unsafe destination.
            try secureExistingRetainedFiles(at: quarantineDirectory)
        }

        for fileName in PrincipalStorageLayout.legacyFileNames {
            let sourceURL = itineraDirectory.appending(path: fileName)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                continue
            }

            let sourceData = try Data(contentsOf: sourceURL)
            let fixedDestination = quarantineDirectory.appending(path: fileName)
            let destination = try retainedDestination(
                for: sourceData,
                fixedDestination: fixedDestination
            )
            if destination.shouldMove {
                // Establish and verify the protected retained copy before
                // removing the global source. A protection/backup failure can
                // therefore never strand the only bytes at the destination.
                try writeRetainedCopy(
                    sourceData,
                    to: destination.url
                )
            }
            // A protected exact copy now exists, including when an earlier
            // collision or failed attempt already retained these bytes.
            // Removing the global path prevents an older build from replaying
            // it on the next launch.
            try fileManager.removeItem(at: sourceURL)
            retainedFileURLs.append(destination.url)
        }

        let removedDefaultsCount =
            ItineraLocalDataCleaner.quarantineLegacyUnscopedData(
                defaults: defaults
            )
        return LegacyPrivateDataQuarantineReport(
            retainedFileURLs: retainedFileURLs,
            removedDefaultsCount: removedDefaultsCount
        )
    }

    /// Removes the selected principal's complete device-local private scope.
    /// The opaque scope is the only ownership input accepted by this helper.
    func purgeCurrentScope(
        _ scope: PrincipalScope,
        at transitionEpoch: UInt64,
        defaultsDomain: PrivateStorageDefaultsDomain
    ) async throws {
        try await purger.purgeCurrentScope(
            scope,
            at: transitionEpoch,
            defaultsDomain: defaultsDomain
        )
    }

    func purgeQuarantine() throws {
        let quarantineDirectory = applicationSupportDirectory
            .appending(path: "Itinera", directoryHint: .isDirectory)
            .appending(path: "quarantine", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: quarantineDirectory.path) else {
            return
        }
        try fileManager.removeItem(at: quarantineDirectory)
    }

    private func retainedDestination(
        for sourceData: Data,
        fixedDestination: URL
    ) throws -> (url: URL, shouldMove: Bool) {
        guard fileManager.fileExists(atPath: fixedDestination.path) else {
            return (fixedDestination, true)
        }
        if try Data(contentsOf: fixedDestination) == sourceData {
            return (fixedDestination, false)
        }

        let contentDigest = SHA256.hash(data: sourceData)
            .map { String(format: "%02x", $0) }
            .joined()
        let extensionSuffix = fixedDestination.pathExtension.isEmpty
            ? ""
            : ".\(fixedDestination.pathExtension)"
        let stem = fixedDestination.deletingPathExtension().lastPathComponent
        let parent = fixedDestination.deletingLastPathComponent()
        var collisionIndex = 0

        while true {
            let indexSuffix = collisionIndex == 0 ? "" : ".\(collisionIndex)"
            let fileName =
                "\(stem).\(contentDigest)\(indexSuffix)\(extensionSuffix)"
            let candidate = parent.appending(path: fileName)
            guard fileManager.fileExists(atPath: candidate.path) else {
                return (candidate, true)
            }
            if try Data(contentsOf: candidate) == sourceData {
                return (candidate, false)
            }
            collisionIndex += 1
        }
    }

    private func secureExistingRetainedFiles(
        at quarantineDirectory: URL
    ) throws {
        let retainedFiles = try fileManager.contentsOfDirectory(
            at: quarantineDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ).filter {
            try $0.resourceValues(forKeys: [.isRegularFileKey])
                .isRegularFile == true
        }
        for fileURL in retainedFiles.sorted(by: { $0.path < $1.path }) {
            try secureQuarantineFile(fileURL, fileManager)
        }
    }

    private func writeRetainedCopy(
        _ data: Data,
        to destination: URL
    ) throws {
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: destination, options: options)
        try secureQuarantineFile(destination, fileManager)
        guard try Data(contentsOf: destination) == data else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
