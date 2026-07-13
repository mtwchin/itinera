import Combine
import Foundation

enum LocalDataCleanupError: LocalizedError, Sendable {
    case clearDownloadsIncomplete
    case identityCleanupIncomplete
    case cleanupJournalUnavailable

    var errorDescription: String? {
        switch self {
        case .clearDownloadsIncomplete:
            return "Some downloaded trip data could not be removed. Your private library remains open; try again."
        case .identityCleanupIncomplete:
            return "Itinera is keeping private content hidden until this iPhone finishes removing the previous library. Try again."
        case .cleanupJournalUnavailable:
            return "Itinera could not safely record the cleanup. No private library will open until you try again."
        }
    }
}

enum PrivateCleanupIntent: String, Codable, Sendable {
    case signOut
    case delete
}

enum PrivateCleanupStage: String, Codable, Sendable {
    case serverDeletionPending
    case localCleanup
}

struct PrivateCleanupPlan: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let operationID: UUID
    let intent: PrivateCleanupIntent
    let stage: PrivateCleanupStage
    let scope: PrincipalScope

    init(
        schemaVersion: Int = 1,
        operationID: UUID = UUID(),
        intent: PrivateCleanupIntent,
        stage: PrivateCleanupStage,
        scope: PrincipalScope
    ) {
        self.schemaVersion = schemaVersion
        self.operationID = operationID
        self.intent = intent
        self.stage = stage
        self.scope = scope
    }

    func advancing(to stage: PrivateCleanupStage) -> Self {
        Self(
            schemaVersion: schemaVersion,
            operationID: operationID,
            intent: intent,
            stage: stage,
            scope: scope
        )
    }
}

protocol PrivateCleanupJournalStoring: Sendable {
    func load() async throws -> PrivateCleanupPlan?
    func save(_ plan: PrivateCleanupPlan) async throws
    func clear() async throws
}

actor ProtectedFilePrivateCleanupJournal: PrivateCleanupJournalStoring {
    private struct Envelope: Codable {
        let schemaVersion: Int
        let plan: PrivateCleanupPlan
    }

    static let currentSchemaVersion = 1
    let fileURL: URL
    var fileManager: FileManager = .default

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func load() async throws -> PrivateCleanupPlan? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        guard let envelope = try? JSONDecoder().decode(
                Envelope.self,
                from: Data(contentsOf: fileURL)
              ),
              envelope.schemaVersion == Self.currentSchemaVersion,
              envelope.plan.schemaVersion == Self.currentSchemaVersion else {
            throw LocalDataCleanupError.cleanupJournalUnavailable
        }
        return envelope.plan
    }

    func save(_ plan: PrivateCleanupPlan) async throws {
        guard plan.schemaVersion == Self.currentSchemaVersion else {
            throw LocalDataCleanupError.cleanupJournalUnavailable
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            Envelope(
                schemaVersion: Self.currentSchemaVersion,
                plan: plan
            )
        )
        try PrivateStorageFileSystem.prepareDirectory(
            at: fileURL.deletingLastPathComponent(),
            fileManager: fileManager
        )
        var writingOptions: Data.WritingOptions = [.atomic]
        #if os(iOS)
        writingOptions.insert(
            .completeFileProtectionUntilFirstUserAuthentication
        )
        #endif
        try data.write(to: fileURL, options: writingOptions)
        try PrivateStorageFileSystem.secureFile(
            at: fileURL,
            fileManager: fileManager
        )
        guard try await load() == plan else {
            throw LocalDataCleanupError.cleanupJournalUnavailable
        }
    }

    func clear() async throws {
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        guard !fileManager.fileExists(atPath: fileURL.path) else {
            throw LocalDataCleanupError.cleanupJournalUnavailable
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    private let apiClient: APIClient
    let identityCoordinator: IdentityCoordinator

    @Published private(set) var pendingJobs: [PendingJobRecord] = []
    @Published private(set) var cachedTrips: [SavedItinerary] = []
    @Published private(set) var tripCacheRefreshedAt: Date?
    @Published private(set) var persistenceError: String?
    @Published private(set) var offlineCacheError: String?
    @Published private(set) var libraryRevision = 0
    @Published private(set) var identityPhase: PrivateIdentityPhase = .restoring
    @Published private(set) var identityEpoch: UInt64 = 0
    @Published private(set) var privateAppSession: PrivateAppSession?
    @Published private(set) var identityOutcome: PrivateIdentityOutcome?

    private let storageFactory: PrincipalStorageFactory
    private let storagePurger: PrincipalStoragePurger
    private let defaults: UserDefaults
    private let defaultsDomain: PrivateStorageDefaultsDomain
    private let surfaceCoordinator: any PrivateSurfaceCoordinating
    private let cleanupJournal: any PrivateCleanupJournalStoring
    private let beforeServerRecoveryResume: (@Sendable () async -> Void)?
    private var storeSet: PrincipalStoreSet?
    private var activeIdentityOperationID: UUID?
    private var integrityCancelledOperationID: UUID?

    var canRetryIdentityBootstrap: Bool {
        if case .blocked = identityPhase { return true }
        if case .cleanupRequired = identityPhase { return true }
        return false
    }

    var currentPrincipalScope: PrincipalScope? {
        storeSet?.scope
    }

    func tripProgressStore(
        session: PrivateAppSession
    ) -> SessionBoundTripProgressStore? {
        guard privateAppSession == session,
              let storeSet,
              storeSet.lease == session.lease else {
            return nil
        }
        return SessionBoundTripProgressStore(
            store: storeSet.tripProgressStore,
            lease: session.lease,
            identityCoordinator: identityCoordinator
        )
    }

    init(
        apiClient: APIClient,
        identityCoordinator: IdentityCoordinator,
        storageFactory: PrincipalStorageFactory,
        defaults: UserDefaults = .standard,
        defaultsDomain: PrivateStorageDefaultsDomain = .standard,
        surfaceCoordinator: any PrivateSurfaceCoordinating,
        cleanupJournal: (any PrivateCleanupJournalStoring)? = nil,
        initialStoreSet: PrincipalStoreSet? = nil,
        beforeServerRecoveryResume: (@Sendable () async -> Void)? = nil
    ) {
        self.apiClient = apiClient
        self.identityCoordinator = identityCoordinator
        self.storageFactory = storageFactory
        storagePurger = storageFactory.purger
        self.defaults = defaults
        self.defaultsDomain = defaultsDomain
        self.surfaceCoordinator = surfaceCoordinator
        self.beforeServerRecoveryResume = beforeServerRecoveryResume
        self.cleanupJournal = cleanupJournal
            ?? ProtectedFilePrivateCleanupJournal(
                fileURL: storageFactory.applicationSupportDirectory
                    .appending(path: "Itinera", directoryHint: .isDirectory)
                    .appending(path: "private-cleanup-journal-v1.json")
            )
        storeSet = initialStoreSet
        if let initialStoreSet {
            privateAppSession = PrivateAppSession(
                lease: initialStoreSet.lease
            )
            identityPhase = .ready(isOffline: false)
        }
    }

    static func live() -> AppState {
        let configuration = APIConfiguration.live()
        let session = URLSession(configuration: configuration.makeSessionConfiguration())
        let credentialStore = KeychainCredentialStore()
        let identityCoordinator = IdentityCoordinator()
        let apiClient = APIClient(
            configuration: configuration,
            session: session,
            credentialStore: credentialStore,
            identityCoordinator: identityCoordinator
        )
        return AppState(
            apiClient: apiClient,
            identityCoordinator: identityCoordinator,
            storageFactory: .live(
                identityCoordinator: identityCoordinator
            ),
            surfaceCoordinator: PrivateSurfaceCoordinator.live()
        )
    }

    func bootstrapIdentity(isRetry: Bool = false) async {
        let mayBootstrap: Bool
        switch identityPhase {
        case .restoring:
            mayBootstrap = true
        case .blocked:
            mayBootstrap = isRetry
        case .cleanupRequired:
            mayBootstrap = isRetry
        case .cleanupBlocked:
            mayBootstrap = false
        case .recoveryRequired:
            mayBootstrap = false
        case .ready, .switching, .signingOut, .deleting, .resumingCleanup,
             .clearingDownloads, .creatingReplacementSession:
            mayBootstrap = false
        }
        guard mayBootstrap,
              let operationID = beginIdentityOperation() else { return }
        defer { endIdentityOperation(operationID) }

        identityPhase = .restoring
        unpublishPrivateState()
        var bootstrapEpoch: UInt64?

        do {
            let transitionEpoch = try await identityCoordinator.beginTransition()
            bootstrapEpoch = transitionEpoch
            identityEpoch = transitionEpoch
            await apiClient.cancelAndInvalidateAuthentication()
            try await surfaceCoordinator.tearDown()
            try await validateTransition(transitionEpoch)

            if let cleanupPlan = try await cleanupJournal.load() {
                guard cleanupPlan.schemaVersion
                        == ProtectedFilePrivateCleanupJournal.currentSchemaVersion
                else {
                    throw LocalDataCleanupError.cleanupJournalUnavailable
                }
                identityPhase = .resumingCleanup(
                    intent: cleanupPlan.intent,
                    stage: cleanupPlan.stage
                )
                try await resumeCleanupPlan(
                    cleanupPlan,
                    transitionEpoch: transitionEpoch
                )
                return
            }

            try storageFactory.quarantineLegacyPrivateData(defaults: defaults)
            try await validateTransition(transitionEpoch)

            let principal: AuthenticatedPrincipal
            if let restored = try await apiClient.restoreCredentials(
                at: transitionEpoch
            ) {
                principal = restored
            } else {
                principal = try await apiClient.createGuestCredentials(
                    at: transitionEpoch
                )
            }
            try await validateTransition(transitionEpoch)

            let plannedLease = IdentityLease(
                scope: principal.identity.scope,
                epoch: transitionEpoch,
                presentationSessionID: UUID()
            )
            let stores = storageFactory.makeStoreSet(
                for: plannedLease,
                defaultsDomain: defaultsDomain
            )
            let stagedCache = try await stores.completedTripCache.load()
            try await validateTransition(transitionEpoch)
            let stagedJobs = try await stores.pendingJobStore.all()
            try await validateTransition(transitionEpoch)

            try await establishPrincipal(
                principal,
                transitionEpoch: transitionEpoch,
                stores: stores,
                cachedSnapshot: stagedCache,
                pendingJobs: stagedJobs
            )
        } catch is CancellationError {
            await handleBootstrapFailure(
                operationID: operationID,
                transitionEpoch: bootstrapEpoch,
                fallbackMessage: "Itinera couldn't safely finish opening this private library. Try again.",
                failure: CancellationError()
            )
        } catch {
            await handleBootstrapFailure(
                operationID: operationID,
                transitionEpoch: bootstrapEpoch,
                fallbackMessage: bootstrapMessage(for: error),
                failure: error
            )
        }
    }

    private func handleBootstrapFailure(
        operationID: UUID,
        transitionEpoch: UInt64?,
        fallbackMessage: String,
        failure: Error
    ) async {
        guard isActiveIdentityOperation(operationID) else { return }
        if let transitionEpoch {
            guard await identityCoordinator.isCurrentTransition(
                epoch: transitionEpoch
            ) else { return }
        }

        unpublishPrivateState()
        await apiClient.cancelAndInvalidateAuthentication()
        try? await surfaceCoordinator.tearDown()

        guard isActiveIdentityOperation(operationID) else { return }
        if let transitionEpoch {
            guard await identityCoordinator.isCurrentTransition(
                epoch: transitionEpoch
            ) else { return }
        }
        if let retainedPlan = await retainedCleanupPlan() {
            identityPhase = cleanupRequiredPhase(
                for: retainedPlan,
                failure: failure
            )
        } else {
            identityPhase = .blocked(message: fallbackMessage)
        }
    }

    private func beginIdentityOperation() -> UUID? {
        guard activeIdentityOperationID == nil else { return nil }
        let identifier = UUID()
        activeIdentityOperationID = identifier
        integrityCancelledOperationID = nil
        // A result belongs to the operation that produced it. Clear stale
        // completion copy only after this operation owns the lifecycle gate.
        identityOutcome = nil
        return identifier
    }

    private func isActiveIdentityOperation(_ identifier: UUID) -> Bool {
        activeIdentityOperationID == identifier
            && integrityCancelledOperationID != identifier
    }

    private func endIdentityOperation(_ identifier: UUID) {
        guard activeIdentityOperationID == identifier else { return }
        activeIdentityOperationID = nil
        integrityCancelledOperationID = nil
    }

    private func bootstrapMessage(for error: Error) -> String {
        if let apiError = error as? APIError,
           case .transport = apiError {
            return "Connect to the internet to establish this private library, then try again."
        }
        return "Itinera couldn't establish a private library on this iPhone. Try again."
    }

    private func retainedCleanupPlan() async -> PrivateCleanupPlan? {
        do {
            guard let plan = try await cleanupJournal.load(),
                  plan.schemaVersion
                    == ProtectedFilePrivateCleanupJournal.currentSchemaVersion
            else { return nil }
            return plan
        } catch {
            return nil
        }
    }

    private func cleanupRequiredPhase(
        for plan: PrivateCleanupPlan,
        failure: Error? = nil
    ) -> PrivateIdentityPhase {
        if plan.intent == .delete,
           plan.stage == .serverDeletionPending {
            if failure as? APIError == .identityRecoveryRequired {
                return .cleanupBlocked(
                    intent: plan.intent,
                    stage: plan.stage,
                    message: "The saved credentials for this same server account were rejected. The deletion request remains recorded and private content stays hidden. Account re-verification is required before deletion can safely continue; contact Itinera support. Repeated retries will not create or switch accounts."
                )
            }
            if failure as? APIError == .identityIntegrityFailure {
                return .cleanupBlocked(
                    intent: plan.intent,
                    stage: plan.stage,
                    message: "Itinera found credentials for a different server account while resuming deletion. The saved deletion remains recorded and private content stays hidden. Do not retry this mismatch; contact Itinera support for verified recovery."
                )
            }
        }
        let message: String
        switch (plan.intent, plan.stage) {
        case (.delete, .serverDeletionPending):
            message = "Itinera has not confirmed deletion with the server. Private app content remains unavailable. Resume the same account deletion to verify system-surface cleanup and retry when its session and network are available."
        case (.delete, .localCleanup):
            message = "The server deletion was accepted, but this iPhone has not finished removing this account's private app data. Calendar events, exported PDFs, files or text, and prior shares remain outside the app."
        case (.signOut, .localCleanup):
            message = "Server data was not deleted. Itinera is keeping private content hidden until this iPhone finishes removing the signed-out library's app data."
        case (.signOut, .serverDeletionPending):
            message = "Itinera found an invalid persisted sign-out phase and will keep private content hidden."
        }
        return .cleanupRequired(
            intent: plan.intent,
            stage: plan.stage,
            message: message
        )
    }

    private func validateTransition(_ epoch: UInt64) async throws {
        try await identityCoordinator.validateTransition(epoch: epoch)
    }

    private func unpublishPrivateState() {
        privateAppSession = nil
        storeSet = nil
        pendingJobs = []
        cachedTrips = []
        tripCacheRefreshedAt = nil
        persistenceError = nil
        offlineCacheError = nil
        libraryRevision &+= 1
    }

    private struct PrivateOperationContext: Sendable {
        let lease: IdentityLease
        let stores: PrincipalStoreSet
        let serverOperationLease: PrivateServerOperationLease?

        func bindingServerOperations(
            to serverOperationLease: PrivateServerOperationLease
        ) -> Self {
            Self(
                lease: lease,
                stores: stores,
                serverOperationLease: serverOperationLease
            )
        }
    }

    private func privateOperationContext(
        _ expectedSession: PrivateAppSession
    ) async throws
        -> PrivateOperationContext {
        let lease = expectedSession.lease
        try await identityCoordinator.validate(lease)
        guard let storeSet, storeSet.lease == lease else {
            throw IdentityCoordinatorError.staleIdentity
        }
        return PrivateOperationContext(
            lease: lease,
            stores: storeSet,
            serverOperationLease: nil
        )
    }

    private func privateNetworkOperationContext(
        _ expectedSession: PrivateAppSession
    ) async throws -> PrivateOperationContext {
        let context = try await privateOperationContext(expectedSession)
        guard case .ready = identityPhase else {
            throw APIError.identityRecoveryRequired
        }
        let serverOperationLease = try await identityCoordinator
            .captureServerOperationLease(ifCurrent: context.lease)
        guard serverOperationLease.identityLease == context.lease else {
            throw IdentityCoordinatorError.staleIdentity
        }
        try await validate(context)
        guard case .ready = identityPhase else {
            throw APIError.identityRecoveryRequired
        }
        return context.bindingServerOperations(to: serverOperationLease)
    }

    private func validate(_ context: PrivateOperationContext) async throws {
        try await identityCoordinator.validate(context.lease)
        guard storeSet?.lease == context.lease,
              context.stores.lease == context.lease else {
            throw IdentityCoordinatorError.staleIdentity
        }
    }

    private func validateServerOperations(
        _ context: PrivateOperationContext
    ) async throws {
        try await validate(context)
        guard let serverOperationLease = context.serverOperationLease else {
            throw IdentityCoordinatorError.staleIdentity
        }
        try await identityCoordinator.validate(serverOperationLease)
    }

    private func validateServerBoundary(
        _ context: PrivateOperationContext
    ) async throws {
        try await validate(context)
        guard let serverOperationLease = context.serverOperationLease else {
            throw IdentityCoordinatorError.staleIdentity
        }
        try await identityCoordinator.validateBoundary(serverOperationLease)
    }

    private func serverOperationLease(
        for context: PrivateOperationContext
    ) throws -> PrivateServerOperationLease {
        guard let serverOperationLease = context.serverOperationLease else {
            throw IdentityCoordinatorError.staleIdentity
        }
        return serverOperationLease
    }

    func scopedAPIValue<Value: Sendable>(
        session: PrivateAppSession,
        _ operation: @escaping @Sendable (IdentityBoundAPIClient) async throws -> Value
    ) async throws -> IdentityScopedValue<Value> {
        let context = try await privateNetworkOperationContext(session)
        let value = try await performPrivateAPI(
            context: context,
            operation
        )
        return IdentityScopedValue(value: value, lease: context.lease)
    }

    private func performPrivateAPI<Value: Sendable>(
        context: PrivateOperationContext,
        identityOperationID: UUID? = nil,
        _ operation: @escaping @Sendable (IdentityBoundAPIClient) async throws -> Value
    ) async throws -> Value {
        let networkContext: PrivateOperationContext
        guard case .ready = identityPhase else {
            throw APIError.identityRecoveryRequired
        }
        if context.serverOperationLease == nil {
            let serverOperationLease = try await identityCoordinator
                .captureServerOperationLease(ifCurrent: context.lease)
            guard serverOperationLease.identityLease == context.lease else {
                throw IdentityCoordinatorError.staleIdentity
            }
            networkContext = context.bindingServerOperations(
                to: serverOperationLease
            )
        } else {
            networkContext = context
        }
        try await validateServerOperations(networkContext)
        guard case .ready = identityPhase else {
            throw APIError.identityRecoveryRequired
        }
        do {
            let value = try await operation(
                apiClient.bound(
                    to: networkContext.lease,
                    serverOperationLease: try serverOperationLease(
                        for: networkContext
                    )
                )
            )
            try await validateServerOperations(networkContext)
            guard case .ready = identityPhase else {
                throw IdentityCoordinatorError.serverOperationsPaused
            }
            return value
        } catch {
            await handleIdentityBoundaryError(
                error,
                context: networkContext,
                identityOperationID: identityOperationID
            )
            throw error
        }
    }

    private func handleIdentityBoundaryError(
        _ error: Error,
        context: PrivateOperationContext,
        identityOperationID: UUID? = nil
    ) async {
        switch error {
        case APIError.identityRecoveryRequired:
            if let serverOperationLease = context.serverOperationLease {
                guard (try? await validateServerBoundary(context)) != nil else {
                    return
                }
                do {
                    try await identityCoordinator.pauseServerOperations(
                        ifCurrent: serverOperationLease
                    )
                } catch {
                    return
                }
            } else {
                // Explicit recovery executes while the coordinator is already
                // paused, so it has no ordinary-operation capability to
                // invalidate. A failed recovery remains behind the existing
                // recovery curtain and must not mint a new readiness token.
                guard case .recoveryRequired = identityPhase else { return }
                guard (try? await validate(context)) != nil else { return }
            }
            if context.serverOperationLease != nil {
                guard (try? await validateServerBoundary(context)) != nil else {
                    return
                }
            } else {
                guard (try? await validate(context)) != nil else { return }
            }
            if let activeIdentityOperationID,
               activeIdentityOperationID != identityOperationID {
                // A lifecycle transition already owns the curtain. Pausing
                // server commits is still required, but a delayed ordinary
                // response must not replace that operation's truthful phase.
                return
            }
            identityPhase = .recoveryRequired(
                message: "Your offline library remains available on this iPhone, but server changes are paused until this session can be restored. Itinera will not create or switch accounts automatically."
            )
            persistenceError = "Server changes are paused for this private library."
        case APIError.identityIntegrityFailure:
            // A delayed error from a lease already replaced by a legitimate
            // transition must never tear down the newer principal. Integrity
            // may own the lifecycle gate itself, or reuse the exact gate of
            // the operation that produced it. It never replaces another
            // operation identifier after an actor hop.
            if context.serverOperationLease != nil {
                guard (try? await validateServerBoundary(context)) != nil else {
                    return
                }
            } else {
                guard (try? await validate(context)) != nil else { return }
            }
            let operationID: UUID
            let ownsOperation: Bool
            if let identityOperationID {
                guard isActiveIdentityOperation(identityOperationID) else {
                    return
                }
                operationID = identityOperationID
                ownsOperation = false
            } else if let acquiredOperationID = beginIdentityOperation() {
                operationID = acquiredOperationID
                ownsOperation = true
            } else if let interruptedOperationID = activeIdentityOperationID {
                // The exact-current integrity result arrived while a separate
                // lifecycle operation was suspended. Cancel that operation in
                // place, retaining its identifier so no post-await work can
                // publish, then take over the same slot for the curtain.
                integrityCancelledOperationID = interruptedOperationID
                operationID = interruptedOperationID
                ownsOperation = false
            } else {
                return
            }
            defer {
                if ownsOperation {
                    endIdentityOperation(operationID)
                }
            }
            identityPhase = .switching
            unpublishPrivateState()

            let transitionEpoch: UInt64
            do {
                transitionEpoch = try await identityCoordinator
                    .beginTransition()
            } catch {
                await identityCoordinator.invalidateCurrent()
                await apiClient.cancelAndInvalidateAuthentication()
                try? await surfaceCoordinator.tearDown()
                if activeIdentityOperationID == operationID
                    || activeIdentityOperationID == nil {
                    identityPhase = .blocked(
                        message: "Itinera found credentials for a different private library. Private content is unavailable until privacy cleanup can be verified."
                    )
                }
                return
            }
            identityEpoch = transitionEpoch
            await apiClient.cancelAndInvalidateAuthentication()
            try? await surfaceCoordinator.tearDown()
            guard await identityCoordinator.isCurrentTransition(
                    epoch: transitionEpoch
                  ) else { return }
            identityPhase = .blocked(
                message: "Itinera found credentials for a different private library and stopped before sending the request. Private content remains unavailable; retry verifies system-surface cleanup before reopening."
            )
        default:
            break
        }
    }

    @discardableResult
    func consume<Value: Sendable>(
        _ scopedValue: IdentityScopedValue<Value>,
        perform: (Value) -> Void
    ) async -> Bool {
        guard await identityCoordinator.isCurrent(scopedValue.lease),
              storeSet?.lease == scopedValue.lease else {
            return false
        }
        perform(scopedValue.value)
        return true
    }

    func isCurrent(_ session: PrivateAppSession) async -> Bool {
        let coordinatorIsCurrent = await identityCoordinator.isCurrent(
            session.lease
        )
        return privateAppSession == session
            && coordinatorIsCurrent
            && storeSet?.lease == session.lease
    }

    func isCurrentPresentationSession(
        _ presentationSession: PrivatePresentationSession
    ) -> Bool {
        privateAppSession?.presentationSession == presentationSession
    }

    func loadTripDraftData(session: PrivateAppSession) async -> Data {
        guard let context = try? await privateOperationContext(session) else {
            return Data()
        }
        let data = await context.stores.localDataStore.tripDraftData()
        guard (try? await validate(context)) != nil else { return Data() }
        return data
    }

    func saveTripDraftData(
        _ data: Data,
        session: PrivateAppSession
    ) async {
        guard let context = try? await privateOperationContext(session) else {
            return
        }
        do {
            try await context.stores.localDataStore.saveTripDraftData(
                data,
                lease: context.lease
            )
            try await validate(context)
        } catch is IdentityCoordinatorError {
            return
        } catch {
            if (try? await validate(context)) != nil {
                persistenceError = "This draft could not be saved on this iPhone."
            }
        }
    }

    func lockedActivityIDs(
        for jobID: String,
        session: PrivateAppSession
    ) async -> Set<String> {
        guard let context = try? await privateOperationContext(session) else {
            return []
        }
        let identifiers = await context.stores.localDataStore
            .lockedActivityIDs(for: jobID)
        guard (try? await validate(context)) != nil else { return [] }
        return identifiers
    }

    func saveLockedActivityIDs(
        _ identifiers: Set<String>,
        for jobID: String,
        session: PrivateAppSession
    ) async {
        guard let context = try? await privateOperationContext(session) else {
            return
        }
        do {
            try await context.stores.localDataStore.saveLockedActivityIDs(
                identifiers,
                for: jobID,
                lease: context.lease
            )
            try await validate(context)
        } catch is IdentityCoordinatorError {
            return
        } catch {
            if (try? await validate(context)) != nil {
                persistenceError = "Locked stops could not be saved on this iPhone."
            }
        }
    }

    func loadCachedTrips(session: PrivateAppSession) async {
        do {
            let context = try await privateOperationContext(session)
            let snapshot = try await context.stores.completedTripCache.load()
            try await validate(context)
            publishCache(snapshot)
            offlineCacheError = nil
        } catch is IdentityCoordinatorError {
            return
        } catch {
            offlineCacheError = "Offline trips could not be loaded on this iPhone."
        }
    }

    /// Fetches the authoritative library and updates its protected offline copy.
    /// The caller can continue displaying `cachedTrips` if this throws.
    func refreshTripLibrary(
        session: PrivateAppSession
    ) async throws -> [SavedItinerary] {
        let context = try await privateOperationContext(session)
        let remoteTrips = try await performPrivateAPI(context: context) {
            try await $0.savedItineraries(includeArchived: true)
        }
        try await validate(context)
        let activeTrips = remoteTrips.filter { $0.archivedAt == nil }
        do {
            let snapshot = try await context.stores.completedTripCache.replace(
                with: remoteTrips,
                lease: context.lease
            )
            try await validate(context)
            publishCache(snapshot)
            offlineCacheError = nil
        } catch is IdentityCoordinatorError {
            throw CancellationError()
        } catch {
            offlineCacheError = "Trips loaded, but the offline copy could not be updated."
        }
        return activeTrips
    }

    /// Makes a newly generated result available offline with authoritative
    /// library metadata when the server is reachable. Generation remains
    /// recoverable offline when the follow-up library request fails.
    func cacheCompletedTrip(
        jobID: String,
        itinerary: Itinerary,
        session: PrivateAppSession
    ) async {
        guard let context = try? await privateOperationContext(session) else {
            return
        }
        let trip: SavedItinerary
        do {
            if var authoritative = (try await performPrivateAPI(
                context: context
            ) { try await $0.savedItineraries() })
                .first(where: { $0.jobId == jobID }) {
                try await validate(context)
                authoritative.status = .succeeded
                authoritative.result = authoritative.result ?? itinerary
                authoritative.error = nil
                trip = authoritative
            } else {
                trip = await fallbackCompletedTrip(
                    jobID: jobID,
                    itinerary: itinerary,
                    context: context
                )
            }
        } catch is IdentityCoordinatorError {
            return
        } catch {
            guard (try? await validate(context)) != nil else { return }
            trip = await fallbackCompletedTrip(
                jobID: jobID,
                itinerary: itinerary,
                context: context
            )
        }

        await persistCompletedTrip(
            trip,
            failureMessage: "This trip is ready, but its offline copy could not be saved.",
            context: context
        )
        if (try? await validate(context)) != nil {
            markLibraryChanged(session: session)
        }
    }

    /// Applies a server-accepted revision to the same protected snapshot used
    /// by Today and Trips before notifying library observers.
    @discardableResult
    func reviseTrip(
        jobID: String,
        expectedVersion: Int,
        operations: [TripRevisionOperation],
        session: PrivateAppSession
    ) async throws -> ItineraryRevisionResponse {
        let context = try await privateOperationContext(session)
        let response = try await performPrivateAPI(context: context) {
            try await $0.reviseTrip(
                jobID,
                expectedVersion: expectedVersion,
                operations: operations
            )
        }
        try await validate(context)
        var trip = await fallbackCompletedTrip(
            jobID: jobID,
            itinerary: response.result,
            context: context
        )
        trip.status = .succeeded
        trip.result = response.result
        trip.error = nil
        trip.version = response.toVersion

        await persistCompletedTrip(
            trip,
            failureMessage: "The revision was saved, but its offline copy could not be updated.",
            context: context
        )
        try await validate(context)
        markLibraryChanged(session: session)
        return response
    }

    private func fallbackCompletedTrip(
        jobID: String,
        itinerary: Itinerary,
        context: PrivateOperationContext
    ) async -> SavedItinerary {
        let publishedTrip = cachedTrips.first { $0.jobId == jobID }
        let storedSnapshot = try? await context.stores.completedTripCache.load()
        let storedTrip = publishedTrip ?? storedSnapshot?.trips.first {
            $0.jobId == jobID
        }
        if var storedTrip {
            storedTrip.status = .succeeded
            storedTrip.result = itinerary
            storedTrip.error = nil
            return storedTrip
        }

        let pending = pendingJobs.first { $0.jobID == jobID }
        return SavedItinerary(
            jobId: jobID,
            status: .succeeded,
            title: pending?.title,
            sourcePublicItineraryId: nil,
            city: nil,
            country: nil,
            arrivalDate: nil,
            departureDate: nil,
            result: itinerary,
            error: nil,
            createdAt: ISO8601DateFormatter().string(
                from: pending?.createdAt ?? Date()
            )
        )
    }

    private func persistCompletedTrip(
        _ trip: SavedItinerary,
        failureMessage: String,
        context: PrivateOperationContext
    ) async {
        do {
            let snapshot = try await context.stores.completedTripCache.upsert(
                trip,
                lease: context.lease
            )
            try await validate(context)
            publishCache(snapshot)
            offlineCacheError = nil
        } catch is IdentityCoordinatorError {
            return
        } catch {
            if (try? await validate(context)) != nil {
                offlineCacheError = failureMessage
            }
        }
    }

    @discardableResult
    func renameTrip(
        jobID: String,
        title: String,
        session: PrivateAppSession
    ) async throws -> TripMutationResponse {
        let context = try await privateOperationContext(session)
        let response = try await performPrivateAPI(context: context) {
            try await $0.updateTrip(jobID, title: title)
        }
        try await validate(context)
        do {
            let snapshot = try await context.stores.completedTripCache.rename(
                jobID: jobID,
                title: response.title ?? title,
                lease: context.lease
            )
            try await validate(context)
            if let snapshot {
                publishCache(snapshot)
            }
            offlineCacheError = nil
        } catch is IdentityCoordinatorError {
            throw CancellationError()
        } catch {
            offlineCacheError = "The trip was renamed, but its offline copy could not be updated."
        }
        markLibraryChanged(session: session)
        return response
    }

    func archiveTrip(
        jobID: String,
        session: PrivateAppSession
    ) async throws {
        let context = try await privateOperationContext(session)
        let response = try await performPrivateAPI(context: context) {
            try await $0.updateTrip(jobID, archived: true)
        }
        try await validate(context)
        do {
            let snapshot = try await context.stores.completedTripCache.setArchivedAt(
                jobID: jobID,
                archivedAt: response.archivedAt,
                lease: context.lease
            )
            try await validate(context)
            if let snapshot {
                publishCache(snapshot)
            }
            offlineCacheError = nil
        } catch is IdentityCoordinatorError {
            throw CancellationError()
        } catch {
            offlineCacheError = "The trip was archived, but its offline copy could not be updated."
        }
        markLibraryChanged(session: session)
    }

    func restoreTrip(
        _ trip: SavedItinerary,
        session: PrivateAppSession
    ) async throws {
        let context = try await privateOperationContext(session)
        let response = try await performPrivateAPI(context: context) {
            try await $0.updateTrip(trip.jobId, archived: false)
        }
        try await validate(context)
        if trip.result != nil {
            var restored = trip
            restored.archivedAt = nil
            restored.title = response.title ?? restored.title
            restored.version = response.version
            do {
                let snapshot = try await context.stores.completedTripCache.upsert(
                    restored,
                    lease: context.lease
                )
                try await validate(context)
                publishCache(snapshot)
                offlineCacheError = nil
            } catch is IdentityCoordinatorError {
                throw CancellationError()
            } catch {
                offlineCacheError = "The trip was restored, but it isn't available offline yet."
            }
        }
        markLibraryChanged(session: session)
    }

    @discardableResult
    func duplicateTrip(
        jobID: String,
        session: PrivateAppSession
    ) async throws -> SavedItinerary {
        let context = try await privateOperationContext(session)
        let duplicate = try await performPrivateAPI(context: context) {
            try await $0.duplicateTrip(jobID)
        }
        try await validate(context)
        if duplicate.result != nil {
            do {
                let snapshot = try await context.stores.completedTripCache.upsert(
                    duplicate,
                    lease: context.lease
                )
                try await validate(context)
                publishCache(snapshot)
            } catch is IdentityCoordinatorError {
                throw CancellationError()
            } catch {
                offlineCacheError = "The copy was created, but it isn't available offline yet."
            }
        }
        markLibraryChanged(session: session)
        return duplicate
    }

    func archivedTrips(
        session: PrivateAppSession
    ) async throws -> [SavedItinerary] {
        let context = try await privateOperationContext(session)
        let trips = try await performPrivateAPI(context: context) {
            try await $0.savedItineraries(includeArchived: true)
        }
        try await validate(context)
        return trips.filter { $0.archivedAt != nil }
    }

    func deleteTrip(jobID: String, session: PrivateAppSession) async throws {
        let context = try await privateOperationContext(session)
        try await performPrivateAPI(context: context) {
            try await $0.deleteTrip(jobID)
        }
        try await validate(context)
        await removeTripFromDeviceCaches(
            jobID: jobID,
            removeProgress: true,
            context: context
        )
        try await validate(context)
        if pendingJobs.contains(where: { $0.jobID == jobID }) {
            await resolvePending(jobID: jobID, session: session)
        }
        markLibraryChanged(session: session)
    }

    private func removeTripFromDeviceCaches(
        jobID: String,
        removeProgress: Bool,
        context: PrivateOperationContext
    ) async {
        do {
            let snapshot = try await context.stores.completedTripCache.remove(
                jobID: jobID,
                lease: context.lease
            )
            try await validate(context)
            if let snapshot {
                publishCache(snapshot)
            }
            offlineCacheError = nil
        } catch is IdentityCoordinatorError {
            return
        } catch {
            if (try? await validate(context)) != nil {
                offlineCacheError = "The trip changed, but its offline copy could not be updated."
            }
        }
        if removeProgress {
            try? await context.stores.tripProgressStore.removeProgress(
                for: jobID,
                lease: context.lease
            )
        }
    }

    func clearDownloadedTripData(session: PrivateAppSession) async throws {
        guard let operationID = beginIdentityOperation() else {
            throw IdentityCoordinatorError.staleIdentity
        }
        defer { endIdentityOperation(operationID) }
        let context = try await privateOperationContext(session)
        let retainedRecoveryMessage: String?
        if case .recoveryRequired(let message) = identityPhase {
            retainedRecoveryMessage = message
        } else {
            retainedRecoveryMessage = nil
        }
        identityPhase = .clearingDownloads
        var cleanupFailed = false
        do {
            try await context.stores.completedTripCache.removeAll(
                lease: context.lease
            )
        } catch {
            cleanupFailed = true
        }
        do {
            try await context.stores.tripProgressStore.removeAll(
                lease: context.lease
            )
        } catch {
            cleanupFailed = true
        }
        try await validate(context)
        guard isActiveIdentityOperation(operationID) else {
            throw IdentityCoordinatorError.staleIdentity
        }
        do {
            try await reestablishCurrentScope(
                context,
                cachedSnapshot: nil,
                operationID: operationID,
                retainedRecoveryMessage: retainedRecoveryMessage
            )
        } catch {
            let transitionEpoch = identityEpoch
            if isActiveIdentityOperation(operationID) {
                try? await surfaceCoordinator.tearDown()
                let isExactTransition = await identityCoordinator
                    .isCurrentTransition(epoch: transitionEpoch)
                if isExactTransition
                    || (error as? IdentityCoordinatorError) == .epochExhausted {
                    identityPhase = .blocked(
                        message: "Itinera could not safely reopen this private library after clearing downloads. Try again."
                    )
                }
            }
            throw error
        }
        if cleanupFailed {
            identityOutcome = .downloadsPartiallyCleared
            throw LocalDataCleanupError.clearDownloadsIncomplete
        }
        identityOutcome = .downloadsCleared
    }

    func retryServerSession(session: PrivateAppSession) async throws {
        guard let operationID = beginIdentityOperation() else {
            throw IdentityCoordinatorError.staleIdentity
        }
        defer { endIdentityOperation(operationID) }
        let context = try await privateOperationContext(session)
        guard case .recoveryRequired = identityPhase else { return }
        identityOutcome = nil
        let recoveryLease = try await identityCoordinator
            .beginServerRecovery(ifCurrent: context.lease)
        do {
            try await apiClient.retrySessionRecovery(lease: context.lease)
            try await validate(context)
            guard isActiveIdentityOperation(operationID) else {
                throw IdentityCoordinatorError.staleIdentity
            }
        } catch {
            try? await identityCoordinator.finishServerRecoveryFailure(
                ifCurrent: recoveryLease
            )
            await handleIdentityBoundaryError(
                error,
                context: context,
                identityOperationID: operationID
            )
            throw error
        }
        if let beforeServerRecoveryResume {
            await beforeServerRecoveryResume()
            try await validate(context)
            guard isActiveIdentityOperation(operationID) else {
                throw IdentityCoordinatorError.staleIdentity
            }
        }
        let recoveredServerOperationLease = try await identityCoordinator
            .resumeServerOperations(ifCurrent: recoveryLease)
        guard isActiveIdentityOperation(operationID) else {
            throw IdentityCoordinatorError.staleIdentity
        }
        let recoveredContext = context.bindingServerOperations(
            to: recoveredServerOperationLease
        )
        identityPhase = .ready(isOffline: true)
        persistenceError = nil
        do {
            let remoteTrips = try await performPrivateAPI(
                context: recoveredContext,
                identityOperationID: operationID
            ) {
                try await $0.savedItineraries(includeArchived: true)
            }
            let snapshot = try await context.stores.completedTripCache.replace(
                with: remoteTrips,
                lease: context.lease
            )
            try await validate(context)
            guard isActiveIdentityOperation(operationID) else {
                throw IdentityCoordinatorError.staleIdentity
            }
            publishCache(snapshot)
            identityPhase = .ready(isOffline: false)
            persistenceError = nil
            offlineCacheError = nil
            markLibraryChanged(session: session)
            identityOutcome = .serverSessionRestored(isOffline: false)
        } catch let error as APIError where error.isRetryable {
            guard (try? await validate(context)) != nil else { throw error }
            identityPhase = .ready(isOffline: true)
            offlineCacheError = "The server session is safe, but the trip library could not refresh. This iPhone's offline copy remains available."
            identityOutcome = .serverSessionRestored(isOffline: true)
        } catch {
            if (try? await validate(context)) != nil {
                if case .recoveryRequired = identityPhase {
                    // performPrivateAPI already supplied the exact recovery
                    // copy and retained the same private session.
                } else if case .blocked = identityPhase {
                    // An integrity failure already raised the privacy curtain.
                } else {
                    // The atomic same-principal recovery already succeeded.
                    // A cancelled, unavailable, or malformed follow-up library
                    // refresh cannot make that verified server session unsafe.
                    identityPhase = .ready(isOffline: true)
                    offlineCacheError = "The server session is safe, but the trip library could not refresh. This iPhone's offline copy remains available."
                    identityOutcome = .serverSessionRestored(isOffline: true)
                }
            }
            throw error
        }
    }

    private func reestablishCurrentScope(
        _ context: PrivateOperationContext,
        cachedSnapshot: CompletedTripCacheSnapshot?,
        operationID: UUID,
        retainedRecoveryMessage: String?
    ) async throws {
        try await validate(context)
        guard isActiveIdentityOperation(operationID) else {
            throw IdentityCoordinatorError.staleIdentity
        }
        guard case .clearingDownloads = identityPhase else {
            throw IdentityCoordinatorError.staleIdentity
        }
        unpublishPrivateState()
        let apiRequiresRecovery = await apiClient
            .cancelAndInvalidateAuthentication(
                capturingRecoveryFor: context.lease
            )
        let transition: IdentityReestablishmentTransition
        do {
            transition = try await identityCoordinator.beginReestablishment(
                ifCurrent: context.lease,
                requiringServerRecovery: apiRequiresRecovery
                    || retainedRecoveryMessage != nil
            )
        } catch {
            await identityCoordinator.invalidateCurrent()
            await apiClient.cancelAndInvalidateAuthentication()
            try? await surfaceCoordinator.tearDown()
            throw error
        }
        let transitionEpoch = transition.epoch
        guard isActiveIdentityOperation(operationID) else {
            await finishIntegrityCancelledTransition(
                transitionEpoch,
                fallbackMessage: "Itinera stopped reopening this library after detecting credentials for a different private library. Private content remains unavailable."
            )
            throw IdentityCoordinatorError.staleIdentity
        }
        identityEpoch = transitionEpoch
        try await surfaceCoordinator.tearDown()
        try await validateTransition(transitionEpoch)

        let plannedLease = IdentityLease(
            scope: context.lease.scope,
            epoch: transitionEpoch,
            presentationSessionID: UUID()
        )
        let stores = storageFactory.makeStoreSet(
            for: plannedLease,
            defaultsDomain: defaultsDomain
        )
        let freshPendingJobs = try await stores.pendingJobStore.all()
        try await validateTransition(transitionEpoch)
        try await surfaceCoordinator.establish(
            session: plannedLease.presentationSession
        )
        try await validateTransition(transitionEpoch)
        let lease = try await identityCoordinator.establish(
            plannedLease.scope,
            presentationSessionID: plannedLease.presentationSessionID,
            at: transitionEpoch,
            requiresServerRecovery: transition.requiresServerRecovery
        )
        guard lease == plannedLease else {
            throw IdentityCoordinatorError.staleIdentity
        }
        if transition.requiresServerRecovery {
            do {
                try await apiClient.bindSessionRecoveryRequirement(to: lease)
            } catch {
                let bindingError = error
                do {
                    let failedEpoch = try await identityCoordinator
                        .beginTransition()
                    identityEpoch = failedEpoch
                } catch {
                    let invalidationError = error
                    await identityCoordinator.invalidateCurrent()
                    await apiClient.cancelAndInvalidateAuthentication()
                    try? await surfaceCoordinator.tearDown()
                    throw invalidationError
                }
                await apiClient.cancelAndInvalidateAuthentication()
                try? await surfaceCoordinator.tearDown()
                throw bindingError
            }
        }
        storeSet = stores
        privateAppSession = PrivateAppSession(lease: lease)
        publishCache(cachedSnapshot)
        pendingJobs = freshPendingJobs
        if transition.requiresServerRecovery {
            identityPhase = .recoveryRequired(
                message: retainedRecoveryMessage
                    ?? "Your offline library remains available on this iPhone, but server changes are paused until this session can be restored. Itinera will not create or switch accounts automatically."
            )
            persistenceError =
                "Server changes are paused for this private library."
        } else {
            identityPhase = .ready(isOffline: false)
            persistenceError = nil
        }
        offlineCacheError = nil
    }

    private func establishPrincipal(
        _ principal: AuthenticatedPrincipal,
        transitionEpoch: UInt64,
        stores providedStores: PrincipalStoreSet? = nil,
        cachedSnapshot: CompletedTripCacheSnapshot?,
        pendingJobs stagedJobs: [PendingJobRecord]
    ) async throws {
        try await validateTransition(transitionEpoch)
        let stores = providedStores ?? storageFactory.makeStoreSet(
            for: IdentityLease(
                scope: principal.identity.scope,
                epoch: transitionEpoch,
                presentationSessionID: UUID()
            ),
            defaultsDomain: defaultsDomain
        )
        guard stores.lease.scope == principal.identity.scope,
              stores.lease.epoch == transitionEpoch else {
            throw IdentityCoordinatorError.staleIdentity
        }
        try await surfaceCoordinator.establish(
            session: stores.lease.presentationSession
        )
        try await validateTransition(transitionEpoch)
        let lease = try await identityCoordinator.establish(
            principal.identity.scope,
            presentationSessionID: stores.lease.presentationSessionID,
            at: transitionEpoch
        )
        guard lease == stores.lease else {
            throw IdentityCoordinatorError.staleIdentity
        }
        storeSet = stores
        privateAppSession = PrivateAppSession(lease: lease)
        publishCache(cachedSnapshot)
        pendingJobs = stagedJobs
        identityPhase = .ready(isOffline: false)
        persistenceError = nil
        offlineCacheError = nil
    }

    func deleteMyData(session: PrivateAppSession) async throws {
        guard let operationID = beginIdentityOperation() else {
            throw IdentityCoordinatorError.staleIdentity
        }
        defer { endIdentityOperation(operationID) }
        let context = try await privateOperationContext(session)
        let pendingPlan = PrivateCleanupPlan(
            intent: .delete,
            stage: .serverDeletionPending,
            scope: context.lease.scope
        )
        try await cleanupJournal.save(pendingPlan)
        guard isActiveIdentityOperation(operationID) else {
            throw IdentityCoordinatorError.staleIdentity
        }
        try await validate(context)
        guard isActiveIdentityOperation(operationID) else {
            throw IdentityCoordinatorError.staleIdentity
        }
        identityPhase = .deleting
        unpublishPrivateState()
        let transitionEpoch = try await beginJournaledCleanupTransition(
            operationID: operationID,
            fallbackMessage: "Itinera recorded the deletion request but could not safely start it. Private content remains hidden; try again."
        )
        do {
            try await surfaceCoordinator.tearDown()
            try await validateTransition(transitionEpoch)
            try await apiClient.retryServerDeletion(
                expectedScope: pendingPlan.scope,
                at: transitionEpoch
            )
            try await validateTransition(transitionEpoch)
            try await cleanupJournal.save(
                pendingPlan.advancing(to: .localCleanup)
            )
            try await validateTransition(transitionEpoch)
            try await finishLocalCleanup(
                pendingPlan.advancing(to: .localCleanup),
                transitionEpoch: transitionEpoch
            )
            identityOutcome = .accountDeleted
        } catch {
            if isActiveIdentityOperation(operationID),
               await identityCoordinator.isCurrentTransition(
                epoch: transitionEpoch
               ) {
                try? await surfaceCoordinator.tearDown()
                if await identityCoordinator.isCurrentTransition(
                    epoch: transitionEpoch
                ) {
                    if let retainedPlan = await retainedCleanupPlan() {
                        identityPhase = cleanupRequiredPhase(
                            for: retainedPlan,
                            failure: error
                        )
                    } else {
                        identityPhase = .blocked(
                            message: "The account cleanup finished, but a separate guest library could not open safely. Private content remains hidden; try again."
                        )
                    }
                }
            }
            throw error
        }
    }

    func signOut(session: PrivateAppSession) async throws {
        guard let operationID = beginIdentityOperation() else {
            throw IdentityCoordinatorError.staleIdentity
        }
        defer { endIdentityOperation(operationID) }
        let context = try await privateOperationContext(session)
        let plan = PrivateCleanupPlan(
            intent: .signOut,
            stage: .localCleanup,
            scope: context.lease.scope
        )
        try await cleanupJournal.save(plan)
        guard isActiveIdentityOperation(operationID) else {
            throw IdentityCoordinatorError.staleIdentity
        }
        try await validate(context)
        guard isActiveIdentityOperation(operationID) else {
            throw IdentityCoordinatorError.staleIdentity
        }
        identityPhase = .signingOut
        unpublishPrivateState()
        let transitionEpoch = try await beginJournaledCleanupTransition(
            operationID: operationID,
            fallbackMessage: "Itinera recorded the sign-out cleanup but could not safely start it. Private content remains hidden; try again."
        )
        do {
            try await finishLocalCleanup(
                plan,
                transitionEpoch: transitionEpoch
            )
            identityOutcome = .signedOut
        } catch {
            if isActiveIdentityOperation(operationID),
               await identityCoordinator.isCurrentTransition(
                epoch: transitionEpoch
               ) {
                if let retainedPlan = await retainedCleanupPlan() {
                    identityPhase = cleanupRequiredPhase(for: retainedPlan)
                } else {
                    identityPhase = .blocked(
                        message: "Sign-out cleanup finished, but a separate guest library could not open safely. Private content remains hidden; try again."
                    )
                }
            }
            throw error
        }
    }

    private func beginJournaledCleanupTransition(
        operationID: UUID,
        fallbackMessage: String
    ) async throws -> UInt64 {
        let transitionEpoch: UInt64
        do {
            transitionEpoch = try await identityCoordinator
                .beginTransition()
        } catch {
            // A durable plan already exists, so no failure may leave the UI in
            // a transient working phase or let old system surfaces remain.
            await identityCoordinator.invalidateCurrent()
            await apiClient.cancelAndInvalidateAuthentication()
            try? await surfaceCoordinator.tearDown()
            if isActiveIdentityOperation(operationID) {
                if let retainedPlan = await retainedCleanupPlan() {
                    identityPhase = cleanupRequiredPhase(for: retainedPlan)
                } else {
                    identityPhase = .blocked(message: fallbackMessage)
                }
            }
            throw error
        }
        guard isActiveIdentityOperation(operationID) else {
            await finishIntegrityCancelledTransition(
                transitionEpoch,
                fallbackMessage: fallbackMessage,
                retainedPlan: await retainedCleanupPlan()
            )
            throw IdentityCoordinatorError.staleIdentity
        }
        identityEpoch = transitionEpoch
        await apiClient.cancelAndInvalidateAuthentication()
        return transitionEpoch
    }

    private func finishIntegrityCancelledTransition(
        _ transitionEpoch: UInt64,
        fallbackMessage: String,
        retainedPlan: PrivateCleanupPlan? = nil
    ) async {
        identityEpoch = transitionEpoch
        await apiClient.cancelAndInvalidateAuthentication()
        try? await surfaceCoordinator.tearDown()
        guard await identityCoordinator.isCurrentTransition(
            epoch: transitionEpoch
        ) else { return }
        if let retainedPlan {
            identityPhase = cleanupRequiredPhase(
                for: retainedPlan,
                failure: APIError.identityIntegrityFailure
            )
        } else {
            identityPhase = .blocked(message: fallbackMessage)
        }
    }

    private func resumeCleanupPlan(
        _ storedPlan: PrivateCleanupPlan,
        transitionEpoch: UInt64
    ) async throws {
        guard storedPlan.schemaVersion
                == ProtectedFilePrivateCleanupJournal.currentSchemaVersion
        else {
            throw LocalDataCleanupError.cleanupJournalUnavailable
        }
        var plan = storedPlan
        if plan.stage == .serverDeletionPending {
            guard plan.intent == .delete else {
                throw LocalDataCleanupError.cleanupJournalUnavailable
            }
            try await apiClient.retryServerDeletion(
                expectedScope: plan.scope,
                at: transitionEpoch
            )
            try await validateTransition(transitionEpoch)
            plan = plan.advancing(to: .localCleanup)
            try await cleanupJournal.save(plan)
            try await validateTransition(transitionEpoch)
        }
        try await finishLocalCleanup(
            plan,
            transitionEpoch: transitionEpoch
        )
        identityOutcome = plan.intent == .delete
            ? .accountDeleted
            : .signedOut
    }

    private func finishLocalCleanup(
        _ plan: PrivateCleanupPlan,
        transitionEpoch: UInt64
    ) async throws {
        guard plan.stage == .localCleanup else {
            throw LocalDataCleanupError.cleanupJournalUnavailable
        }
        try await validateTransition(transitionEpoch)

        // Attempt every independent privacy cleanup. The durable journal is
        // retained until every step and its verification succeeds.
        var cleanupFailed = false
        do {
            try await surfaceCoordinator.tearDown()
        } catch {
            cleanupFailed = true
        }
        do {
            try await storagePurger.purgeCurrentScope(
                plan.scope,
                at: transitionEpoch,
                defaultsDomain: defaultsDomain
            )
        } catch {
            cleanupFailed = true
        }
        do {
            // A relaunch can reach cleanup before ordinary bootstrap's legacy
            // quarantine. Remove every global replay path before any guest can
            // be established; contents remain opaque and are never claimed.
            try storageFactory.quarantineLegacyPrivateData(defaults: defaults)
        } catch {
            cleanupFailed = true
        }
        if plan.intent == .delete {
            do {
                try storageFactory.purgeQuarantine()
            } catch {
                cleanupFailed = true
            }
        }
        do {
            try await apiClient.clearCredentials(at: transitionEpoch)
        } catch {
            cleanupFailed = true
        }
        guard !cleanupFailed else {
            throw LocalDataCleanupError.identityCleanupIncomplete
        }

        try await validateTransition(transitionEpoch)
        try await cleanupJournal.clear()
        try await validateTransition(transitionEpoch)

        identityPhase = .creatingReplacementSession(intent: plan.intent)
        let replacement = try await apiClient.createGuestCredentials(
            at: transitionEpoch
        )
        try await validateTransition(transitionEpoch)
        try await establishPrincipal(
            replacement,
            transitionEpoch: transitionEpoch,
            cachedSnapshot: nil,
            pendingJobs: []
        )
    }

    func connectAppleAccount(
        identityToken: String,
        session: PrivateAppSession
    ) async throws -> AppleLinkResult {
        let context = try await privateOperationContext(session)
        identityOutcome = nil
        let result = try await performPrivateAPI(context: context) {
            try await $0.connectAppleAccount(identityToken: identityToken)
        }
        try await validate(context)
        if result == .linked {
            markLibraryChanged(session: session)
            identityOutcome = .appleAccountLinked
        }
        return result
    }

    @discardableResult
    func acceptCollaborationInvite(
        token: String,
        session: PrivateAppSession
    ) async throws -> TripCollaborator {
        let context = try await privateOperationContext(session)
        let collaborator = try await performPrivateAPI(context: context) {
            try await $0.acceptCollaborationInvite(token: token)
        }
        try await validate(context)
        markLibraryChanged(session: session)
        return collaborator
    }

    func switchToAppleAccount(
        identityToken: String,
        session: PrivateAppSession
    ) async throws {
        let context = try await privateOperationContext(session)
        let candidate = try await performPrivateAPI(context: context) {
            try await $0.prepareAppleSwitch(identityToken: identityToken)
        }
        guard let operationID = beginIdentityOperation() else {
            throw IdentityCoordinatorError.staleIdentity
        }
        defer { endIdentityOperation(operationID) }
        try await validate(context)
        guard isActiveIdentityOperation(operationID) else {
            throw IdentityCoordinatorError.staleIdentity
        }

        var transitionEpoch: UInt64?
        do {
            identityPhase = .switching
            unpublishPrivateState()
            let nextEpoch = try await identityCoordinator.beginTransition()
            guard isActiveIdentityOperation(operationID) else {
                await finishIntegrityCancelledTransition(
                    nextEpoch,
                    fallbackMessage: "Itinera stopped this library switch after detecting credentials for a different private library. Private content remains unavailable."
                )
                throw IdentityCoordinatorError.staleIdentity
            }
            transitionEpoch = nextEpoch
            identityEpoch = nextEpoch
            await apiClient.cancelAndInvalidateAuthentication()
            try await surfaceCoordinator.tearDown()
            try await validateTransition(nextEpoch)

            let principal = try await apiClient.activateAppleCandidate(
                candidate,
                at: nextEpoch
            )
            try await validateTransition(nextEpoch)
            let plannedLease = IdentityLease(
                scope: principal.identity.scope,
                epoch: nextEpoch,
                presentationSessionID: UUID()
            )
            let stores = storageFactory.makeStoreSet(
                for: plannedLease,
                defaultsDomain: defaultsDomain
            )
            let stagedCache = try await stores.completedTripCache.load()
            try await validateTransition(nextEpoch)
            let stagedJobs = try await stores.pendingJobStore.all()
            try await validateTransition(nextEpoch)
            try await establishPrincipal(
                principal,
                transitionEpoch: nextEpoch,
                stores: stores,
                cachedSnapshot: stagedCache,
                pendingJobs: stagedJobs
            )
            identityOutcome = .appleLibrarySwitched
        } catch {
            guard isActiveIdentityOperation(operationID) else { throw error }
            if let transitionEpoch {
                guard await identityCoordinator.isCurrentTransition(
                    epoch: transitionEpoch
                ) else { throw error }
            } else {
                await identityCoordinator.invalidateCurrent()
                await apiClient.cancelAndInvalidateAuthentication()
            }
            try? await surfaceCoordinator.tearDown()
            guard isActiveIdentityOperation(operationID) else { throw error }
            identityPhase = .blocked(
                message: "The library switch could not finish safely. The previous library remains stored separately; try again."
            )
            throw error
        }
    }

    func loadPendingJobs(session: PrivateAppSession) async {
        do {
            let context = try await privateOperationContext(session)
            let jobs = try await context.stores.pendingJobStore.all()
            try await validate(context)
            pendingJobs = jobs
            persistenceError = nil
        } catch is IdentityCoordinatorError {
            return
        } catch {
            persistenceError = "Pending trips could not be loaded."
        }
    }

    func registerPending(
        jobID: String,
        title: String? = nil,
        session: PrivateAppSession
    ) async {
        guard let context = try? await privateNetworkOperationContext(session)
        else { return }
        do {
            let jobs = try await context.stores.pendingJobStore.add(
                jobID: jobID,
                title: title,
                lease: context.lease,
                serverOperationLease: try serverOperationLease(for: context)
            )
            try await validateServerOperations(context)
            pendingJobs = jobs
            persistenceError = nil
        } catch is IdentityCoordinatorError {
            return
        } catch {
            persistenceError = "This pending trip could not be saved on this device."
        }
    }

    func submitItinerary(
        _ request: GenerateItineraryRequest,
        title: String,
        session: PrivateAppSession
    ) async throws -> JobAccepted {
        let context = try await privateNetworkOperationContext(session)
        let submission = try await context.stores.pendingSubmissionStore.record(
            for: request,
            title: title,
            lease: context.lease,
            serverOperationLease: try serverOperationLease(for: context)
        )
        try await validateServerOperations(context)
        let accepted: JobAccepted
        do {
            accepted = try await performPrivateAPI(context: context) {
                try await $0.createItinerary(
                    submission.request,
                    idempotencyKey: submission.idempotencyKey
                )
            }
        } catch let error as APIError where error.shouldDiscardPendingSubmission {
            try? await context.stores.pendingSubmissionStore.remove(
                idempotencyKey: submission.idempotencyKey,
                lease: context.lease,
                serverOperationLease: try serverOperationLease(for: context)
            )
            throw error
        }
        try await validateServerOperations(context)
        let jobs = try await context.stores.pendingJobStore.add(
            jobID: accepted.jobId,
            title: submission.title,
            lease: context.lease,
            serverOperationLease: try serverOperationLease(for: context)
        )
        try await validateServerOperations(context)
        pendingJobs = jobs
        do {
            try await context.stores.pendingSubmissionStore.remove(
                idempotencyKey: submission.idempotencyKey,
                lease: context.lease,
                serverOperationLease: try serverOperationLease(for: context)
            )
            try await validateServerOperations(context)
        } catch {
            if (try? await validateServerOperations(context)) != nil {
                persistenceError = "The accepted trip could not be cleared from the retry queue."
            }
        }
        return accepted
    }

    func resumePendingSubmissions(session: PrivateAppSession) async {
        guard let context = try? await privateNetworkOperationContext(session) else {
            return
        }
        let submissions: [PendingSubmissionRecord]
        do {
            submissions = try await context.stores.pendingSubmissionStore.all()
            try await validateServerOperations(context)
        } catch {
            if (try? await validateServerOperations(context)) != nil {
                persistenceError = "Pending trip submissions could not be loaded."
            }
            return
        }

        for submission in submissions {
            do {
                try await validateServerOperations(context)
                let accepted = try await performPrivateAPI(context: context) {
                    try await $0.createItinerary(
                        submission.request,
                        idempotencyKey: submission.idempotencyKey
                    )
                }
                try await validateServerOperations(context)
                let jobs = try await context.stores.pendingJobStore.add(
                    jobID: accepted.jobId,
                    title: submission.title,
                    lease: context.lease,
                    serverOperationLease: try serverOperationLease(
                        for: context
                    )
                )
                try await validateServerOperations(context)
                pendingJobs = jobs
                try await context.stores.pendingSubmissionStore.remove(
                    idempotencyKey: submission.idempotencyKey,
                    lease: context.lease,
                    serverOperationLease: try serverOperationLease(
                        for: context
                    )
                )
                try await validateServerOperations(context)
            } catch is CancellationError {
                return
            } catch is IdentityCoordinatorError {
                return
            } catch let error as APIError where error.shouldDiscardPendingSubmission {
                if (try? await validateServerOperations(context)) != nil {
                    try? await context.stores.pendingSubmissionStore.remove(
                        idempotencyKey: submission.idempotencyKey,
                        lease: context.lease,
                        serverOperationLease: try serverOperationLease(
                            for: context
                        )
                    )
                }
            } catch {
                // Retain the request and its idempotency key for a later retry.
            }
        }
    }

    func resolvePending(jobID: String, session: PrivateAppSession) async {
        guard let context = try? await privateNetworkOperationContext(session)
        else { return }
        do {
            let jobs = try await context.stores.pendingJobStore.remove(
                jobID: jobID,
                lease: context.lease,
                serverOperationLease: try serverOperationLease(for: context)
            )
            try await validateServerOperations(context)
            pendingJobs = jobs
            persistenceError = nil
        } catch is IdentityCoordinatorError {
            return
        } catch {
            persistenceError = "This pending trip could not be updated on this device."
        }
    }

    func reconcilePending(
        with remoteTrips: [SavedItinerary],
        session: PrivateAppSession
    ) async {
        guard let context = try? await privateNetworkOperationContext(session)
        else { return }
        do {
            var recordsByID: [String: PendingJobRecord] = [:]
            for record in try await context.stores.pendingJobStore.all() {
                recordsByID[record.jobID] = record
            }
            try await validateServerOperations(context)
            for trip in remoteTrips {
                switch trip.status {
                case .pending, .running:
                    if recordsByID[trip.jobId] == nil {
                        recordsByID[trip.jobId] = PendingJobRecord(
                            jobID: trip.jobId,
                            title: trip.displayTitle.isEmpty ? nil : trip.displayTitle,
                            createdAt: Self.parseDate(trip.createdAt) ?? Date()
                        )
                    }
                case .succeeded, .failed:
                    recordsByID.removeValue(forKey: trip.jobId)
                }
            }
            let jobs = try await context.stores.pendingJobStore.replace(
                with: Array(recordsByID.values),
                lease: context.lease,
                serverOperationLease: try serverOperationLease(for: context)
            )
            try await validateServerOperations(context)
            pendingJobs = jobs
            persistenceError = nil
        } catch is IdentityCoordinatorError {
            return
        } catch {
            persistenceError = "Pending trips could not be reconciled."
        }
    }

    func markLibraryChanged(session: PrivateAppSession) {
        guard privateAppSession == session else { return }
        libraryRevision &+= 1
    }

    func dismissIdentityOutcome() {
        identityOutcome = nil
    }

    private func publishCache(_ snapshot: CompletedTripCacheSnapshot?) {
        cachedTrips = snapshot?.trips.filter { $0.archivedAt == nil } ?? []
        tripCacheRefreshedAt = snapshot?.refreshedAt
    }

    private static func parseDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}
