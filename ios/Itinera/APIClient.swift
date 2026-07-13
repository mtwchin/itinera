import Foundation

enum APIError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case decoding
    case transport(code: URLError.Code, message: String)
    case unauthorized
    case identityRecoveryRequired
    case identityIntegrityFailure
    case authenticationFailed(String)
    case http(statusCode: Int, code: String?, message: String, retryAfter: TimeInterval?)
    case generationFailed(code: String?, message: String)
    case pollingTimedOut(jobID: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server returned an invalid response."
        case .decoding:
            return "The server returned data this version of Itinera cannot read."
        case .transport(_, let message):
            return message
        case .unauthorized:
            return "Your session has expired. Please try again."
        case .identityRecoveryRequired:
            return "This private library needs its session restored before making server changes."
        case .identityIntegrityFailure:
            return "Itinera stopped the request because the private-library identity changed unexpectedly."
        case .authenticationFailed(let message):
            return message
        case .http(_, _, let message, _):
            return message
        case .generationFailed(_, let message):
            return message
        case .pollingTimedOut:
            return "This trip is taking longer than expected. You can reopen it from My Trips."
        }
    }

    var isRetryable: Bool {
        switch self {
        case .transport:
            return true
        case .http(let statusCode, _, _, _):
            return statusCode == 408 || statusCode == 425 || statusCode == 429 || statusCode >= 500
        default:
            return false
        }
    }

    var retryAfter: TimeInterval? {
        if case .http(_, _, _, let retryAfter) = self { return retryAfter }
        return nil
    }

    var isTerminalGenerationFailure: Bool {
        if case .generationFailed = self { return true }
        return false
    }

    var shouldRemovePendingJob: Bool {
        if isTerminalGenerationFailure { return true }
        if case .http(let statusCode, _, _, _) = self, statusCode == 404 { return true }
        return false
    }

    var shouldDiscardPendingSubmission: Bool {
        if case .http(let statusCode, _, _, _) = self {
            return [400, 403, 409, 422].contains(statusCode)
        }
        return false
    }
}

struct AuthenticatedPrincipal: Equatable, Sendable {
    let credentials: AuthCredentials
    let identity: PrincipalIdentity
}

enum AppleLinkResult: Equatable, Sendable {
    case linked
    case switchConfirmationRequired
}

/// Credentials obtained only after explicit switch confirmation. The bearer
/// and refresh tokens stay encapsulated here in memory until activation.
struct AppleCredentialCandidate: Equatable, Sendable {
    let identity: PrincipalIdentity
    fileprivate let credentials: AuthCredentials
    fileprivate let sourceLease: IdentityLease
}

private enum PrivateServerRequestContext {
    @TaskLocal static var operationLease: PrivateServerOperationLease?
}

/// The only entry point for established-principal network work. Callers bind
/// the lease they captured with their private operation before any suspension;
/// APIClient never substitutes whichever identity happens to be current later.
struct IdentityBoundAPIClient: Sendable {
    fileprivate let client: APIClient
    let lease: IdentityLease
    fileprivate let serverOperationLease: PrivateServerOperationLease?

    private func withServerOperation<Value: Sendable>(
        _ operation: () async throws -> Value
    ) async throws -> Value {
        let operationLease: PrivateServerOperationLease
        do {
            operationLease = try await client.resolveServerOperationLease(
                for: lease,
                preferred: serverOperationLease
            )
        } catch IdentityCoordinatorError.serverOperationsPaused {
            throw APIError.identityRecoveryRequired
        }
        return try await PrivateServerRequestContext.$operationLease.withValue(
            operationLease
        ) {
            try await operation()
        }
    }

    func createItinerary(
        _ payload: GenerateItineraryRequest,
        idempotencyKey: UUID = UUID()
    ) async throws -> JobAccepted {
        try await withServerOperation {
            try await client.createItinerary(
                payload,
                idempotencyKey: idempotencyKey,
                lease: lease
            )
        }
    }

    func jobStatus(_ jobID: String) async throws -> JobStatusResponse {
        try await withServerOperation {
            try await client.jobStatus(jobID, lease: lease)
        }
    }

    func savedItineraries(includeArchived: Bool = false) async throws -> [SavedItinerary] {
        try await withServerOperation {
            try await client.savedItineraries(
                includeArchived: includeArchived,
                lease: lease
            )
        }
    }

    func updateTrip(
        _ jobID: String,
        title: String? = nil,
        archived: Bool? = nil
    ) async throws -> TripMutationResponse {
        try await withServerOperation {
            try await client.updateTrip(
                jobID,
                title: title,
                archived: archived,
                lease: lease
            )
        }
    }

    func deleteTrip(_ jobID: String) async throws {
        try await withServerOperation {
            try await client.deleteTrip(jobID, lease: lease)
        }
    }

    func duplicateTrip(_ jobID: String) async throws -> SavedItinerary {
        try await withServerOperation {
            try await client.duplicateTrip(jobID, lease: lease)
        }
    }

    func reviseTrip(
        _ jobID: String,
        expectedVersion: Int,
        operations: [TripRevisionOperation]
    ) async throws -> ItineraryRevisionResponse {
        try await withServerOperation {
            try await client.reviseTrip(
                jobID,
                expectedVersion: expectedVersion,
                operations: operations,
                lease: lease
            )
        }
    }

    func revisionHistory(_ jobID: String) async throws -> [ItineraryRevisionResponse] {
        try await withServerOperation {
            try await client.revisionHistory(jobID, lease: lease)
        }
    }

    func reservations(_ jobID: String) async throws -> [TripReservation] {
        try await withServerOperation {
            try await client.reservations(jobID, lease: lease)
        }
    }

    func createReservation(
        _ jobID: String,
        input: TripReservationCreate
    ) async throws -> TripReservation {
        try await withServerOperation {
            try await client.createReservation(
                jobID,
                input: input,
                lease: lease
            )
        }
    }

    func deleteReservation(_ jobID: String, reservationID: String) async throws {
        try await withServerOperation {
            try await client.deleteReservation(
                jobID,
                reservationID: reservationID,
                lease: lease
            )
        }
    }

    func checklist(_ jobID: String) async throws -> [TripChecklistItem] {
        try await withServerOperation {
            try await client.checklist(jobID, lease: lease)
        }
    }

    func createChecklistItem(
        _ jobID: String,
        input: TripChecklistItemCreate
    ) async throws -> TripChecklistItem {
        try await withServerOperation {
            try await client.createChecklistItem(
                jobID,
                input: input,
                lease: lease
            )
        }
    }

    func updateChecklistItem(
        _ jobID: String,
        itemID: String,
        input: TripChecklistItemUpdate
    ) async throws -> TripChecklistItem {
        try await withServerOperation {
            try await client.updateChecklistItem(
                jobID,
                itemID: itemID,
                input: input,
                lease: lease
            )
        }
    }

    func deleteChecklistItem(_ jobID: String, itemID: String) async throws {
        try await withServerOperation {
            try await client.deleteChecklistItem(
                jobID,
                itemID: itemID,
                lease: lease
            )
        }
    }

    func expenses(_ jobID: String) async throws -> [TripExpense] {
        try await withServerOperation {
            try await client.expenses(jobID, lease: lease)
        }
    }

    func createExpense(
        _ jobID: String,
        input: TripExpenseCreate
    ) async throws -> TripExpense {
        try await withServerOperation {
            try await client.createExpense(jobID, input: input, lease: lease)
        }
    }

    func deleteExpense(_ jobID: String, expenseID: String) async throws {
        try await withServerOperation {
            try await client.deleteExpense(
                jobID,
                expenseID: expenseID,
                lease: lease
            )
        }
    }

    func collaborators(_ jobID: String) async throws -> [TripCollaborator] {
        try await withServerOperation {
            try await client.collaborators(jobID, lease: lease)
        }
    }

    func createCollaborationInvite(
        _ jobID: String,
        input: CollaborationInviteCreate
    ) async throws -> CollaborationInvite {
        try await withServerOperation {
            try await client.createCollaborationInvite(
                jobID,
                input: input,
                lease: lease
            )
        }
    }

    func removeCollaborator(_ jobID: String, collaboratorID: String) async throws {
        try await withServerOperation {
            try await client.removeCollaborator(
                jobID,
                collaboratorID: collaboratorID,
                lease: lease
            )
        }
    }

    func acceptCollaborationInvite(token: String) async throws -> TripCollaborator {
        try await withServerOperation {
            try await client.acceptCollaborationInvite(
                token: token,
                lease: lease
            )
        }
    }

    func placeReports(_ jobID: String) async throws -> [PlaceReport] {
        try await withServerOperation {
            try await client.placeReports(jobID, lease: lease)
        }
    }

    func createPlaceReport(
        _ jobID: String,
        input: PlaceReportCreate
    ) async throws -> PlaceReport {
        try await withServerOperation {
            try await client.createPlaceReport(
                jobID,
                input: input,
                lease: lease
            )
        }
    }

    func connectAppleAccount(identityToken: String) async throws -> AppleLinkResult {
        try await withServerOperation {
            try await client.connectAppleAccount(
                identityToken: identityToken,
                lease: lease
            )
        }
    }

    func prepareAppleSwitch(identityToken: String) async throws -> AppleCredentialCandidate {
        try await withServerOperation {
            try await client.prepareAppleSwitch(
                identityToken: identityToken,
                lease: lease
            )
        }
    }

    func popularItineraries() async throws -> [PopularItinerarySummary] {
        try await withServerOperation {
            try await client.popularItineraries(lease: lease)
        }
    }

    func popularItinerary(_ itineraryID: String) async throws -> PopularItineraryDetail {
        try await withServerOperation {
            try await client.popularItinerary(itineraryID, lease: lease)
        }
    }

    func savePopularItinerary(
        _ itineraryID: String
    ) async throws -> SavePopularItineraryResponse {
        try await withServerOperation {
            try await client.savePopularItinerary(itineraryID, lease: lease)
        }
    }

    func awaitItinerary(
        _ jobID: String,
        policy: JobPollingPolicy = JobPollingPolicy()
    ) async throws -> Itinerary {
        try await withServerOperation {
            try await client.awaitItinerary(
                jobID,
                policy: policy,
                lease: lease
            )
        }
    }
}

struct JobPollingPolicy: Sendable, Equatable {
    var initialDelay: TimeInterval = 1
    var maximumDelay: TimeInterval = 10
    var multiplier: Double = 1.8
    var jitterFraction: Double = 0.2
    // Local inference can consume the composer's full three-minute budget
    // after queueing, discovery, and geocoding. Keep foreground polling longer
    // than that end-to-end path; leaving the screen still cancels polling and
    // the persisted pending job can be resumed from Trips.
    var timeout: TimeInterval = 10 * 60

    func delay(forAttempt attempt: Int, randomUnit: Double = Double.random(in: 0...1)) -> TimeInterval {
        let exponential = min(maximumDelay, initialDelay * pow(multiplier, Double(max(attempt, 0))))
        let clampedRandom = min(max(randomUnit, 0), 1)
        let jitterMultiplier = 1 + ((clampedRandom * 2) - 1) * jitterFraction
        return max(0, exponential * jitterMultiplier)
    }
}

actor APIClient {
    private struct TokenResponse: Decodable, Sendable {
        let userId: String
        let accessToken: String
        let refreshToken: String
        let tokenType: String
        let expiresIn: TimeInterval
    }

    private struct RefreshRequest: Encodable, Sendable {
        let refreshToken: String
    }

    private struct AppleIdentityRequest: Encodable, Sendable {
        let identityToken: String
    }

    private struct ServerErrorDetails: Sendable {
        let code: String?
        let message: String
    }

    private let configuration: APIConfiguration
    private let session: URLSession
    private let credentialStore: any CredentialStoring
    private let identityCoordinator: IdentityCoordinator
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let now: @Sendable () -> Date
    private let beforeReturningIdentityRecoveryRequired:
        (@Sendable () async -> Void)?
    private var authenticationTask: AuthenticationTask?
    private var authenticationGeneration = UUID()
    private var recoveryRequiredLease: IdentityLease?
    private var credentialMutationLocked = false
    private var credentialMutationWaiters: [CheckedContinuation<Void, Never>] = []
#if DEBUG
    private var credentialMutationQueueObservers: [CheckedContinuation<Void, Never>] = []
#endif

    private enum EstablishedAuthenticationAuthorization: Equatable, Sendable {
        case serverOperation(PrivateServerOperationLease)
        case explicitRecovery(IdentityLease)

        var identityLease: IdentityLease {
            switch self {
            case .serverOperation(let operationLease):
                return operationLease.identityLease
            case .explicitRecovery(let identityLease):
                return identityLease
            }
        }
    }

    private enum AuthenticationContext: Equatable {
        case established(EstablishedAuthenticationAuthorization)
        case transition(UInt64)
    }

    private struct AuthenticationTask {
        let context: AuthenticationContext
        let generation: UUID
        let task: Task<AuthCredentials, Error>
    }

    init(
        configuration: APIConfiguration,
        session: URLSession,
        credentialStore: any CredentialStoring,
        identityCoordinator: IdentityCoordinator,
        now: @escaping @Sendable () -> Date = { Date() },
        beforeReturningIdentityRecoveryRequired:
            (@Sendable () async -> Void)? = nil
    ) {
        self.configuration = configuration
        self.session = session
        self.credentialStore = credentialStore
        self.identityCoordinator = identityCoordinator
        self.now = now
        self.beforeReturningIdentityRecoveryRequired =
            beforeReturningIdentityRecoveryRequired

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = encoder
    }

    nonisolated func bound(to lease: IdentityLease) -> IdentityBoundAPIClient {
        IdentityBoundAPIClient(
            client: self,
            lease: lease,
            serverOperationLease: nil
        )
    }

    nonisolated func bound(
        to lease: IdentityLease,
        serverOperationLease: PrivateServerOperationLease
    ) -> IdentityBoundAPIClient {
        IdentityBoundAPIClient(
            client: self,
            lease: lease,
            serverOperationLease: serverOperationLease
        )
    }

    fileprivate func resolveServerOperationLease(
        for lease: IdentityLease,
        preferred: PrivateServerOperationLease?
    ) async throws -> PrivateServerOperationLease {
        if let preferred {
            guard preferred.identityLease == lease else {
                throw IdentityCoordinatorError.staleIdentity
            }
            try await identityCoordinator.validate(preferred)
            return preferred
        }
        return try await identityCoordinator.captureServerOperationLease(
            ifCurrent: lease
        )
    }

    fileprivate func createItinerary(
        _ payload: GenerateItineraryRequest,
        idempotencyKey: UUID,
        lease: IdentityLease
    ) async throws -> JobAccepted {
        try await send(
            path: "/api/v1/itineraries",
            method: "POST",
            body: encoder.encode(payload),
            additionalHeaders: ["Idempotency-Key": idempotencyKey.uuidString.lowercased()],
            lease: lease,
            as: JobAccepted.self
        )
    }

    fileprivate func jobStatus(
        _ jobID: String,
        lease: IdentityLease
    ) async throws -> JobStatusResponse {
        try await send(
            path: "/api/v1/itineraries/\(jobID)",
            lease: lease,
            as: JobStatusResponse.self
        )
    }

    fileprivate func savedItineraries(
        includeArchived: Bool,
        lease: IdentityLease
    ) async throws -> [SavedItinerary] {
        let path = includeArchived
            ? "/api/v1/itineraries?include_archived=true"
            : "/api/v1/itineraries"
        return try await send(path: path, lease: lease, as: [SavedItinerary].self)
    }

    fileprivate func updateTrip(
        _ jobID: String,
        title: String? = nil,
        archived: Bool? = nil,
        lease: IdentityLease
    ) async throws -> TripMutationResponse {
        try await send(
            path: "/api/v1/itineraries/\(jobID)",
            method: "PATCH",
            body: encoder.encode(
                TripUpdateRequest(title: title, archived: archived)
            ),
            lease: lease,
            as: TripMutationResponse.self
        )
    }

    fileprivate func deleteTrip(_ jobID: String, lease: IdentityLease) async throws {
        try await sendWithoutResponse(
            path: "/api/v1/itineraries/\(jobID)",
            method: "DELETE",
            lease: lease
        )
    }

    fileprivate func duplicateTrip(
        _ jobID: String,
        lease: IdentityLease
    ) async throws -> SavedItinerary {
        try await send(
            path: "/api/v1/itineraries/\(jobID)/duplicate",
            method: "POST",
            lease: lease,
            as: SavedItinerary.self
        )
    }

    fileprivate func reviseTrip(
        _ jobID: String,
        expectedVersion: Int,
        operations: [TripRevisionOperation],
        lease: IdentityLease
    ) async throws -> ItineraryRevisionResponse {
        try await send(
            path: "/api/v1/itineraries/\(jobID)/revisions",
            method: "POST",
            body: encoder.encode(
                ItineraryRevisionCreate(
                    expectedVersion: expectedVersion,
                    operations: operations
                )
            ),
            lease: lease,
            as: ItineraryRevisionResponse.self
        )
    }

    fileprivate func revisionHistory(
        _ jobID: String,
        lease: IdentityLease
    ) async throws -> [ItineraryRevisionResponse] {
        try await send(
            path: "/api/v1/itineraries/\(jobID)/revisions",
            lease: lease,
            as: [ItineraryRevisionResponse].self
        )
    }

    fileprivate func reservations(
        _ jobID: String,
        lease: IdentityLease
    ) async throws -> [TripReservation] {
        try await send(path: "/api/v1/itineraries/\(jobID)/reservations", lease: lease, as: [TripReservation].self)
    }

    fileprivate func createReservation(_ jobID: String, input: TripReservationCreate, lease: IdentityLease) async throws -> TripReservation {
        try await send(path: "/api/v1/itineraries/\(jobID)/reservations", method: "POST", body: encoder.encode(input), lease: lease, as: TripReservation.self)
    }

    fileprivate func deleteReservation(_ jobID: String, reservationID: String, lease: IdentityLease) async throws {
        try await sendWithoutResponse(path: "/api/v1/itineraries/\(jobID)/reservations/\(reservationID)", method: "DELETE", lease: lease)
    }

    fileprivate func checklist(_ jobID: String, lease: IdentityLease) async throws -> [TripChecklistItem] {
        try await send(path: "/api/v1/itineraries/\(jobID)/checklist", lease: lease, as: [TripChecklistItem].self)
    }

    fileprivate func createChecklistItem(_ jobID: String, input: TripChecklistItemCreate, lease: IdentityLease) async throws -> TripChecklistItem {
        try await send(path: "/api/v1/itineraries/\(jobID)/checklist", method: "POST", body: encoder.encode(input), lease: lease, as: TripChecklistItem.self)
    }

    fileprivate func updateChecklistItem(_ jobID: String, itemID: String, input: TripChecklistItemUpdate, lease: IdentityLease) async throws -> TripChecklistItem {
        try await send(path: "/api/v1/itineraries/\(jobID)/checklist/\(itemID)", method: "PATCH", body: encoder.encode(input), lease: lease, as: TripChecklistItem.self)
    }

    fileprivate func deleteChecklistItem(_ jobID: String, itemID: String, lease: IdentityLease) async throws {
        try await sendWithoutResponse(path: "/api/v1/itineraries/\(jobID)/checklist/\(itemID)", method: "DELETE", lease: lease)
    }

    fileprivate func expenses(_ jobID: String, lease: IdentityLease) async throws -> [TripExpense] {
        try await send(path: "/api/v1/itineraries/\(jobID)/expenses", lease: lease, as: [TripExpense].self)
    }

    fileprivate func createExpense(_ jobID: String, input: TripExpenseCreate, lease: IdentityLease) async throws -> TripExpense {
        try await send(path: "/api/v1/itineraries/\(jobID)/expenses", method: "POST", body: encoder.encode(input), lease: lease, as: TripExpense.self)
    }

    fileprivate func deleteExpense(_ jobID: String, expenseID: String, lease: IdentityLease) async throws {
        try await sendWithoutResponse(path: "/api/v1/itineraries/\(jobID)/expenses/\(expenseID)", method: "DELETE", lease: lease)
    }

    fileprivate func collaborators(_ jobID: String, lease: IdentityLease) async throws -> [TripCollaborator] {
        try await send(path: "/api/v1/itineraries/\(jobID)/collaborators", lease: lease, as: [TripCollaborator].self)
    }

    fileprivate func createCollaborationInvite(_ jobID: String, input: CollaborationInviteCreate, lease: IdentityLease) async throws -> CollaborationInvite {
        try await send(path: "/api/v1/itineraries/\(jobID)/collaboration-invites", method: "POST", body: encoder.encode(input), lease: lease, as: CollaborationInvite.self)
    }

    fileprivate func removeCollaborator(_ jobID: String, collaboratorID: String, lease: IdentityLease) async throws {
        try await sendWithoutResponse(path: "/api/v1/itineraries/\(jobID)/collaborators/\(collaboratorID)", method: "DELETE", lease: lease)
    }

    fileprivate func acceptCollaborationInvite(token: String, lease: IdentityLease) async throws -> TripCollaborator {
        try await send(path: "/api/v1/collaboration-invites/accept", method: "POST", body: encoder.encode(CollaborationInviteAccept(token: token)), lease: lease, as: TripCollaborator.self)
    }

    fileprivate func placeReports(_ jobID: String, lease: IdentityLease) async throws -> [PlaceReport] {
        try await send(path: "/api/v1/itineraries/\(jobID)/place-reports", lease: lease, as: [PlaceReport].self)
    }

    fileprivate func createPlaceReport(_ jobID: String, input: PlaceReportCreate, lease: IdentityLease) async throws -> PlaceReport {
        try await send(path: "/api/v1/itineraries/\(jobID)/place-reports", method: "POST", body: encoder.encode(input), lease: lease, as: PlaceReport.self)
    }

    /// Reads Keychain only while the coordinator is behind its privacy
    /// curtain. This does not infer a principal or perform network work.
    func inspectCredentials(at transitionEpoch: UInt64) async throws -> AuthCredentials? {
        try await identityCoordinator.validateTransition(epoch: transitionEpoch)
        let credentials: AuthCredentials?
        do {
            credentials = try await credentialStore.loadCredentials()
        } catch {
            let storeError = error
            try await identityCoordinator.validateTransition(epoch: transitionEpoch)
            throw storeError
        }
        try await identityCoordinator.validateTransition(epoch: transitionEpoch)
        return credentials
    }

    /// Restores a previously established principal without requiring network
    /// access. A legacy record deliberately has no principal and must obtain
    /// one from refresh before it can be established.
    func restoreCredentials(
        at transitionEpoch: UInt64
    ) async throws -> AuthenticatedPrincipal? {
        guard let stored = try await inspectCredentials(at: transitionEpoch) else {
            return nil
        }

        if stored.userID == nil {
            return try await refreshLegacyCredentials(
                current: stored,
                transitionEpoch: transitionEpoch
            )
        }

        let principal = try authenticatedPrincipal(from: stored)
        guard principal.credentials == stored else {
            try await saveCredentials(
                principal.credentials,
                transitionEpoch: transitionEpoch
            )
            return principal
        }
        return principal
    }

    func createGuestCredentials(
        at transitionEpoch: UInt64
    ) async throws -> AuthenticatedPrincipal {
        let credentials = try await runTransitionAuthentication(at: transitionEpoch) { generation in
            try await self.performCreateGuestCredentials(
                transitionEpoch: transitionEpoch,
                authenticationGeneration: generation
            )
        }
        return try authenticatedPrincipal(from: credentials)
    }

    /// Credential removal is intentionally transition-only. Callers must
    /// unpublish all private surfaces before invoking it.
    func clearCredentials(at transitionEpoch: UInt64) async throws {
        await acquireCredentialMutationGate()
        defer { releaseCredentialMutationGate() }
        try Task.checkCancellation()
        try await identityCoordinator.validateTransition(epoch: transitionEpoch)
        do {
            try await credentialStore.clearCredentials()
        } catch {
            let storeError = error
            try await identityCoordinator.validateTransition(epoch: transitionEpoch)
            throw storeError
        }
        try Task.checkCancellation()
        try await identityCoordinator.validateTransition(epoch: transitionEpoch)
    }

    /// Invalidates shared refresh/bootstrap work. Epoch validation remains the
    /// authoritative barrier if URL loading finishes after cancellation.
    func cancelAndInvalidateAuthentication() {
        _ = cancelAndInvalidateAuthentication(capturingRecoveryFor: nil)
    }

    /// Same-principal actor replacement must invalidate every in-flight auth
    /// task without forgetting a recovery requirement that already
    /// linearized in this actor. The coordinator independently captures its
    /// paused generation, and the two results are combined fail closed.
    func cancelAndInvalidateAuthentication(
        capturingRecoveryFor lease: IdentityLease?
    ) -> Bool {
        let capturedRecovery = lease.map { recoveryRequiredLease == $0 }
            ?? false
        authenticationGeneration = UUID()
        authenticationTask?.task.cancel()
        authenticationTask = nil
        recoveryRequiredLease = nil
        return capturedRecovery
    }

    /// Rebinds a carried recovery requirement to the exact replacement
    /// presentation. The coordinator's paused state remains authoritative;
    /// this latch prevents internal credential paths from treating the new
    /// lease as an ordinary ready session.
    func bindSessionRecoveryRequirement(to lease: IdentityLease) async throws {
        do {
            try await identityCoordinator.validateServerRecoveryRequired(
                ifCurrent: lease
            )
            recoveryRequiredLease = lease
            try await identityCoordinator.validateServerRecoveryRequired(
                ifCurrent: lease
            )
        } catch {
            if recoveryRequiredLease == lease {
                recoveryRequiredLease = nil
            }
            throw error
        }
    }

#if DEBUG
    func waitForCredentialMutationWaiterForTesting() async {
        guard credentialMutationWaiters.isEmpty else { return }
        await withCheckedContinuation { continuation in
            credentialMutationQueueObservers.append(continuation)
        }
    }
#endif

    /// Explicit lifecycle-only recovery for one established presentation.
    /// This is intentionally absent from IdentityBoundAPIClient so ordinary
    /// scoped request closures cannot unlatch or resume server operations.
    func retrySessionRecovery(lease: IdentityLease) async throws {
        try await identityCoordinator.validate(lease)
        if let recoveryRequiredLease, recoveryRequiredLease != lease {
            throw APIError.identityIntegrityFailure
        }
        // Explicit recovery owns a fresh authentication generation. Any
        // pre-recovery refresh may still finish at URLSession, but it cannot
        // share work with or mutate credentials for the recovered session.
        authenticationGeneration = UUID()
        authenticationTask?.task.cancel()
        authenticationTask = nil
        recoveryRequiredLease = nil
        do {
            try Task.checkCancellation()
            let loaded: AuthCredentials?
            do {
                loaded = try await credentialStore.loadCredentials()
            } catch {
                let storeError = error
                try await identityCoordinator.validate(lease)
                throw storeError
            }
            try Task.checkCancellation()
            try await identityCoordinator.validate(lease)
            guard let loaded else {
                throw APIError.identityRecoveryRequired
            }
            let principal = try authenticatedPrincipal(from: loaded)
            guard principal.identity.scope == lease.scope else {
                throw APIError.identityIntegrityFailure
            }

            let recovered = try await refreshCredentials(
                current: principal.credentials,
                authorization: .explicitRecovery(lease)
            )
            try Task.checkCancellation()
            try await identityCoordinator.validate(lease)
            let recoveredPrincipal = try authenticatedPrincipal(from: recovered)
            guard recoveredPrincipal.identity == principal.identity,
                  recoveredPrincipal.identity.scope == lease.scope else {
                throw APIError.identityIntegrityFailure
            }
        } catch {
            let recoveryError = error
            recoveryRequiredLease = lease
            let isStillCurrent = await identityCoordinator.isCurrent(lease)
            if !isStillCurrent, recoveryRequiredLease == lease {
                recoveryRequiredLease = nil
            }
            throw recoveryError
        }
    }

    /// Replays a deletion while the privacy curtain remains raised. The
    /// retained access token is always tried first, even when expired. A 401
    /// permits exactly one same-principal refresh and one DELETE retry; this
    /// transition-only path never establishes or creates a principal.
    func retryServerDeletion(
        expectedScope: PrincipalScope,
        at transitionEpoch: UInt64
    ) async throws {
        let generation = authenticationGeneration
        try await validateTransition(
            transitionEpoch,
            authenticationGeneration: generation
        )
        let loaded: AuthCredentials?
        do {
            loaded = try await credentialStore.loadCredentials()
        } catch {
            let storeError = error
            try await validateTransition(
                transitionEpoch,
                authenticationGeneration: generation
            )
            throw storeError
        }
        try await validateTransition(
            transitionEpoch,
            authenticationGeneration: generation
        )
        guard let loaded else {
            throw APIError.identityRecoveryRequired
        }
        let principal = try authenticatedPrincipal(from: loaded)
        guard principal.identity.scope == expectedScope else {
            throw APIError.identityIntegrityFailure
        }

        guard !principal.credentials.accessToken.isEmpty else {
            throw APIError.identityRecoveryRequired
        }
        let installationID: String
        do {
            installationID = try await credentialStore.installationIdentifier()
        } catch {
            let storeError = error
            try await validateTransition(
                transitionEpoch,
                authenticationGeneration: generation
            )
            throw storeError
        }
        try await validateTransition(
            transitionEpoch,
            authenticationGeneration: generation
        )

        let body = try encoder.encode(["confirmation": "DELETE"])
        var request = try makeRequestWithoutCredentialLookup(
            path: "/api/v1/auth/me",
            method: "DELETE",
            body: body,
            bearerToken: principal.credentials.accessToken,
            installationID: installationID,
            additionalHeaders: [:],
        )
        var (data, response) = try await perform(
            request,
            transitionEpoch: transitionEpoch,
            authenticationGeneration: generation
        )
        if response.statusCode == 401 {
            let refreshed = try await refreshCredentialsForServerDeletion(
                current: principal.credentials,
                expectedScope: expectedScope,
                transitionEpoch: transitionEpoch,
                authenticationGeneration: generation,
                installationID: installationID
            )
            request.setValue(
                "Bearer \(refreshed.accessToken)",
                forHTTPHeaderField: "Authorization"
            )
            (data, response) = try await perform(
                request,
                transitionEpoch: transitionEpoch,
                authenticationGeneration: generation
            )
            if response.statusCode == 401 {
                throw APIError.identityRecoveryRequired
            }
        }
        try validate(response: response, data: data)
        try await validateTransition(
            transitionEpoch,
            authenticationGeneration: generation
        )
    }

    fileprivate func connectAppleAccount(
        identityToken: String,
        lease: IdentityLease
    ) async throws -> AppleLinkResult {
        let serverOperationLease = try await currentServerOperationLease(
            for: lease
        )
        let generation = authenticationGeneration
        let body = try encoder.encode(AppleIdentityRequest(identityToken: identityToken))
        let response: TokenResponse
        do {
            response = try await send(
                path: "/api/v1/auth/apple/link",
                method: "POST",
                body: body,
                lease: lease,
                as: TokenResponse.self
            )
        } catch APIError.http(let statusCode, let code, _, _)
            where statusCode == 409 && code == "apple_account_exists" {
            try await identityCoordinator.validate(serverOperationLease)
            return .switchConfirmationRequired
        }

        try await identityCoordinator.validateBoundary(serverOperationLease)
        let principal = try authenticatedPrincipal(from: response)
        guard principal.identity.scope == lease.scope else {
            throw APIError.identityIntegrityFailure
        }
        try await saveCredentials(
            principal.credentials,
            authorization: .serverOperation(serverOperationLease),
            authenticationGeneration: generation
        )
        return .linked
    }

    /// Called only after the traveler confirms that they want to inspect the
    /// separate Apple library. The resulting tokens remain in memory and do
    /// not replace the current library.
    fileprivate func prepareAppleSwitch(
        identityToken: String,
        lease sourceLease: IdentityLease
    ) async throws -> AppleCredentialCandidate {
        let serverOperationLease = try await currentServerOperationLease(
            for: sourceLease
        )
        let authorization = EstablishedAuthenticationAuthorization
            .serverOperation(serverOperationLease)
        let generation = authenticationGeneration
        let body = try encoder.encode(AppleIdentityRequest(identityToken: identityToken))
        let installationID: String
        do {
            installationID = try await credentialStore.installationIdentifier()
        } catch {
            let storeError = error
            try await validateBoundary(
                authorization,
                authenticationGeneration: generation
            )
            throw storeError
        }
        try await validate(
            authorization,
            authenticationGeneration: generation
        )
        let response: TokenResponse
        do {
            response = try await sendAuthenticationRequest(
                path: "/api/v1/auth/apple",
                body: body,
                installationID: installationID,
                authorization: authorization,
                authenticationGeneration: generation
            )
        } catch {
            let authenticationError = error
            try await validateBoundary(
                authorization,
                authenticationGeneration: generation
            )
            throw authenticationError
        }
        try await validateBoundary(
            authorization,
            authenticationGeneration: generation
        )
        let principal = try authenticatedPrincipal(from: response)
        let candidate = AppleCredentialCandidate(
            identity: principal.identity,
            credentials: principal.credentials,
            sourceLease: sourceLease
        )
        try await validate(
            authorization,
            authenticationGeneration: generation
        )
        return candidate
    }

    /// Commits a confirmed in-memory candidate only in the immediately next
    /// transition, preventing an A candidate from being replayed after A→B→A.
    func activateAppleCandidate(
        _ candidate: AppleCredentialCandidate,
        at transitionEpoch: UInt64
    ) async throws -> AuthenticatedPrincipal {
        guard candidate.sourceLease.epoch < UInt64.max,
              transitionEpoch == candidate.sourceLease.epoch + 1 else {
            throw IdentityCoordinatorError.staleIdentity
        }
        let principal = try authenticatedPrincipal(from: candidate.credentials)
        guard principal.identity == candidate.identity else {
            throw APIError.identityIntegrityFailure
        }
        try await saveCredentials(
            principal.credentials,
            transitionEpoch: transitionEpoch
        )
        return principal
    }

    fileprivate func popularItineraries(
        lease: IdentityLease
    ) async throws -> [PopularItinerarySummary] {
        try await send(
            path: "/api/v1/popular-itineraries",
            lease: lease,
            as: [PopularItinerarySummary].self
        )
    }

    fileprivate func popularItinerary(
        _ itineraryID: String,
        lease: IdentityLease
    ) async throws -> PopularItineraryDetail {
        try await send(
            path: "/api/v1/popular-itineraries/\(itineraryID)",
            lease: lease,
            as: PopularItineraryDetail.self
        )
    }

    fileprivate func savePopularItinerary(
        _ itineraryID: String,
        lease: IdentityLease
    ) async throws -> SavePopularItineraryResponse {
        try await send(
            path: "/api/v1/popular-itineraries/\(itineraryID)/saved",
            method: "PUT",
            lease: lease,
            as: SavePopularItineraryResponse.self
        )
    }

    fileprivate func awaitItinerary(
        _ jobID: String,
        policy: JobPollingPolicy,
        lease: IdentityLease
    ) async throws -> Itinerary {
        let serverOperationLease = try await currentServerOperationLease(
            for: lease
        )
        let deadline = now().addingTimeInterval(policy.timeout)
        var attempt = 0

        while now() < deadline {
            try Task.checkCancellation()

            do {
                let status = try await send(
                    path: "/api/v1/itineraries/\(jobID)",
                    lease: lease,
                    as: JobStatusResponse.self
                )
                switch status.status {
                case .succeeded:
                    guard let itinerary = status.result else {
                        throw APIError.generationFailed(
                            code: "missing_result",
                            message: "The trip finished without an itinerary. Please generate it again."
                        )
                    }
                    return itinerary
                case .failed:
                    throw APIError.generationFailed(
                        code: "generation_failed",
                        message: status.error ?? "Itinerary generation failed."
                    )
                case .pending, .running:
                    break
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as APIError where error.isRetryable {
                let delay = max(policy.delay(forAttempt: attempt), error.retryAfter ?? 0)
                try await sleep(delay, noLaterThan: deadline)
                try await identityCoordinator.validate(serverOperationLease)
                attempt += 1
                continue
            }

            let delay = policy.delay(forAttempt: attempt)
            try await sleep(delay, noLaterThan: deadline)
            try await identityCoordinator.validate(serverOperationLease)
            attempt += 1
        }

        try await identityCoordinator.validate(serverOperationLease)
        throw APIError.pollingTimedOut(jobID: jobID)
    }

    private func send<Response: Decodable & Sendable>(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        additionalHeaders: [String: String] = [:],
        lease: IdentityLease,
        as type: Response.Type
    ) async throws -> Response {
        let serverOperationLease = try await currentServerOperationLease(
            for: lease
        )
        let requestGeneration = authenticationGeneration
        var credentials = try await credentialsForRequest(
            lease: lease,
            serverOperationLease: serverOperationLease
        )
        var request = try await makeRequest(
            path: path,
            method: method,
            body: body,
            bearerToken: credentials.accessToken,
            additionalHeaders: additionalHeaders,
            serverOperationLease: serverOperationLease
        )

        var (data, response) = try await perform(
            request,
            serverOperationLease: serverOperationLease
        )
        if response.statusCode == 401 {
            credentials = try await refreshCredentials(
                current: credentials,
                authorization: .serverOperation(serverOperationLease)
            )
            try await identityCoordinator.validate(serverOperationLease)
            request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
            try await identityCoordinator.validate(serverOperationLease)
            (data, response) = try await perform(
                request,
                serverOperationLease: serverOperationLease
            )
            if response.statusCode == 401 {
                try await requireSessionRecovery(
                    authorization: .serverOperation(serverOperationLease),
                    authenticationGeneration: requestGeneration
                )
                throw APIError.identityRecoveryRequired
            }
        }

        try await identityCoordinator.validate(serverOperationLease)
        try validate(response: response, data: data)
        do {
            let decoded = try decoder.decode(Response.self, from: data)
            try await identityCoordinator.validate(serverOperationLease)
            return decoded
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if error is IdentityCoordinatorError {
                throw error
            }
            throw APIError.decoding
        }
    }

    private func sendWithoutResponse(
        path: String,
        method: String,
        body: Data? = nil,
        additionalHeaders: [String: String] = [:],
        lease: IdentityLease
    ) async throws {
        let serverOperationLease = try await currentServerOperationLease(
            for: lease
        )
        let requestGeneration = authenticationGeneration
        var credentials = try await credentialsForRequest(
            lease: lease,
            serverOperationLease: serverOperationLease
        )
        var request = try await makeRequest(
            path: path,
            method: method,
            body: body,
            bearerToken: credentials.accessToken,
            additionalHeaders: additionalHeaders,
            serverOperationLease: serverOperationLease
        )

        var (data, response) = try await perform(
            request,
            serverOperationLease: serverOperationLease
        )
        if response.statusCode == 401 {
            credentials = try await refreshCredentials(
                current: credentials,
                authorization: .serverOperation(serverOperationLease)
            )
            try await identityCoordinator.validate(serverOperationLease)
            request.setValue(
                "Bearer \(credentials.accessToken)",
                forHTTPHeaderField: "Authorization"
            )
            try await identityCoordinator.validate(serverOperationLease)
            (data, response) = try await perform(
                request,
                serverOperationLease: serverOperationLease
            )
            if response.statusCode == 401 {
                try await requireSessionRecovery(
                    authorization: .serverOperation(serverOperationLease),
                    authenticationGeneration: requestGeneration
                )
                throw APIError.identityRecoveryRequired
            }
        }
        try await identityCoordinator.validate(serverOperationLease)
        try validate(response: response, data: data)
        try await identityCoordinator.validate(serverOperationLease)
    }

    private func credentialsForRequest(
        lease: IdentityLease,
        serverOperationLease: PrivateServerOperationLease
    ) async throws -> AuthCredentials {
        guard serverOperationLease.identityLease == lease else {
            throw IdentityCoordinatorError.staleIdentity
        }
        let requestGeneration = authenticationGeneration
        try await identityCoordinator.validate(serverOperationLease)
        guard recoveryRequiredLease != lease else {
            throw APIError.identityRecoveryRequired
        }
        let loaded: AuthCredentials?
        do {
            loaded = try await credentialStore.loadCredentials()
        } catch {
            let storeError = error
            try await identityCoordinator.validateBoundary(
                serverOperationLease
            )
            throw storeError
        }
        guard let stored = loaded else {
            try await requireSessionRecovery(
                authorization: .serverOperation(serverOperationLease),
                authenticationGeneration: requestGeneration
            )
            throw APIError.identityRecoveryRequired
        }
        try await identityCoordinator.validateBoundary(serverOperationLease)
        let principal: AuthenticatedPrincipal
        do {
            principal = try authenticatedPrincipal(from: stored)
        } catch APIError.identityRecoveryRequired {
            try await requireSessionRecovery(
                authorization: .serverOperation(serverOperationLease),
                authenticationGeneration: requestGeneration
            )
            throw APIError.identityRecoveryRequired
        }
        guard principal.identity.scope == lease.scope else {
            throw APIError.identityIntegrityFailure
        }
        if principal.credentials.isExpired(at: now()) {
            return try await refreshCredentials(
                current: principal.credentials,
                authorization: .serverOperation(serverOperationLease)
            )
        }
        try await identityCoordinator.validate(serverOperationLease)
        return principal.credentials
    }

    private func performCreateGuestCredentials(
        transitionEpoch: UInt64,
        authenticationGeneration generation: UUID
    ) async throws -> AuthCredentials {
        try await validateTransition(
            transitionEpoch,
            authenticationGeneration: generation
        )
        let installationID: String
        do {
            installationID = try await credentialStore.installationIdentifier()
        } catch {
            let storeError = error
            try await validateTransition(
                transitionEpoch,
                authenticationGeneration: generation
            )
            throw storeError
        }
        try await validateTransition(
            transitionEpoch,
            authenticationGeneration: generation
        )
        let response: TokenResponse
        do {
            response = try await sendAuthenticationRequest(
                path: "/api/v1/auth/guest",
                body: nil,
                installationID: installationID
            )
        } catch {
            let authenticationError = error
            try await validateTransition(
                transitionEpoch,
                authenticationGeneration: generation
            )
            throw authenticationError
        }
        try await validateTransition(
            transitionEpoch,
            authenticationGeneration: generation
        )
        let principal = try authenticatedPrincipal(from: response)
        try await saveCredentials(
            principal.credentials,
            transitionEpoch: transitionEpoch,
            authenticationGeneration: generation
        )
        return principal.credentials
    }

    private func refreshCredentials(
        current: AuthCredentials,
        authorization: EstablishedAuthenticationAuthorization
    ) async throws -> AuthCredentials {
        let context = AuthenticationContext.established(authorization)
        if let authenticationTask,
           authenticationTask.context == context,
           authenticationTask.generation == authenticationGeneration {
            let credentials = try await authenticationTask.task.value
            try await validate(
                authorization,
                authenticationGeneration: authenticationTask.generation
            )
            return credentials
        }

        authenticationTask?.task.cancel()
        let generation = authenticationGeneration
        let task = Task {
            try await self.refreshIfCurrent(
                current,
                authorization: authorization,
                authenticationGeneration: generation
            )
        }
        authenticationTask = AuthenticationTask(
            context: context,
            generation: generation,
            task: task
        )
        do {
            let credentials = try await task.value
            clearAuthenticationTask(context: context, generation: generation)
            try await validate(
                authorization,
                authenticationGeneration: generation
            )
            return credentials
        } catch {
            clearAuthenticationTask(context: context, generation: generation)
            throw error
        }
    }

    private func refreshIfCurrent(
        _ current: AuthCredentials,
        authorization: EstablishedAuthenticationAuthorization,
        authenticationGeneration generation: UUID
    ) async throws -> AuthCredentials {
        let lease = authorization.identityLease
        try await validate(authorization, authenticationGeneration: generation)
        let loaded: AuthCredentials?
        do {
            loaded = try await credentialStore.loadCredentials()
        } catch {
            let storeError = error
            try await validateBoundary(
                authorization,
                authenticationGeneration: generation
            )
            throw storeError
        }
        guard let stored = loaded else {
            try await requireSessionRecovery(
                authorization: authorization,
                authenticationGeneration: generation
            )
            throw APIError.identityRecoveryRequired
        }
        try await validateBoundary(
            authorization,
            authenticationGeneration: generation
        )
        let storedPrincipal: AuthenticatedPrincipal
        do {
            storedPrincipal = try authenticatedPrincipal(from: stored)
        } catch APIError.identityRecoveryRequired {
            try await requireSessionRecovery(
                authorization: authorization,
                authenticationGeneration: generation
            )
            throw APIError.identityRecoveryRequired
        }
        guard storedPrincipal.identity.scope == lease.scope else {
            throw APIError.identityIntegrityFailure
        }
        if storedPrincipal.credentials != current {
            if storedPrincipal.credentials.isExpired(at: now()) {
                return try await performRefreshCredentials(
                    current: storedPrincipal.credentials,
                    authorization: authorization,
                    authenticationGeneration: generation
                )
            }
            try await validate(
                authorization,
                authenticationGeneration: generation
            )
            return storedPrincipal.credentials
        }
        return try await performRefreshCredentials(
            current: current,
            authorization: authorization,
            authenticationGeneration: generation
        )
    }

    private func performRefreshCredentials(
        current: AuthCredentials,
        authorization: EstablishedAuthenticationAuthorization,
        authenticationGeneration generation: UUID
    ) async throws -> AuthCredentials {
        let lease = authorization.identityLease
        try await validateBoundary(
            authorization,
            authenticationGeneration: generation
        )
        let currentPrincipal = try authenticatedPrincipal(from: current)
        guard currentPrincipal.identity.scope == lease.scope else {
            throw APIError.identityIntegrityFailure
        }
        try await validate(authorization, authenticationGeneration: generation)
        let installationID: String
        do {
            installationID = try await credentialStore.installationIdentifier()
        } catch {
            let storeError = error
            try await validateBoundary(
                authorization,
                authenticationGeneration: generation
            )
            throw storeError
        }
        try await validate(authorization, authenticationGeneration: generation)
        let requestBody = try encoder.encode(RefreshRequest(refreshToken: current.refreshToken))
        let response: TokenResponse
        do {
            response = try await sendAuthenticationRequest(
                path: "/api/v1/auth/refresh",
                body: requestBody,
                installationID: installationID,
                authorization: authorization,
                authenticationGeneration: generation
            )
        } catch APIError.unauthorized {
            try await requireSessionRecovery(
                authorization: authorization,
                authenticationGeneration: generation
            )
            throw APIError.identityRecoveryRequired
        } catch {
            let authenticationError = error
            try await validateBoundary(
                authorization,
                authenticationGeneration: generation
            )
            throw authenticationError
        }
        try await validateBoundary(
            authorization,
            authenticationGeneration: generation
        )
        let refreshed = try authenticatedPrincipal(from: response)
        guard refreshed.identity == currentPrincipal.identity else {
            throw APIError.identityIntegrityFailure
        }
        try await saveCredentials(
            refreshed.credentials,
            authorization: authorization,
            authenticationGeneration: generation
        )
        if recoveryRequiredLease == lease {
            recoveryRequiredLease = nil
        }
        return refreshed.credentials
    }

    private func refreshCredentialsForServerDeletion(
        current: AuthCredentials,
        expectedScope: PrincipalScope,
        transitionEpoch: UInt64,
        authenticationGeneration generation: UUID,
        installationID: String
    ) async throws -> AuthCredentials {
        let currentPrincipal = try authenticatedPrincipal(from: current)
        guard currentPrincipal.identity.scope == expectedScope else {
            throw APIError.identityIntegrityFailure
        }
        guard !current.refreshToken.isEmpty else {
            throw APIError.identityRecoveryRequired
        }
        try await validateTransition(
            transitionEpoch,
            authenticationGeneration: generation
        )
        let requestBody = try encoder.encode(
            RefreshRequest(refreshToken: current.refreshToken)
        )
        let response: TokenResponse
        do {
            response = try await sendAuthenticationRequest(
                path: "/api/v1/auth/refresh",
                body: requestBody,
                installationID: installationID
            )
        } catch APIError.unauthorized {
            try await validateTransition(
                transitionEpoch,
                authenticationGeneration: generation
            )
            throw APIError.identityRecoveryRequired
        } catch {
            let authenticationError = error
            try await validateTransition(
                transitionEpoch,
                authenticationGeneration: generation
            )
            throw authenticationError
        }
        try await validateTransition(
            transitionEpoch,
            authenticationGeneration: generation
        )
        let refreshed = try authenticatedPrincipal(from: response)
        guard refreshed.identity == currentPrincipal.identity,
              refreshed.identity.scope == expectedScope else {
            throw APIError.identityIntegrityFailure
        }
        do {
            try await saveCredentials(
                refreshed.credentials,
                transitionEpoch: transitionEpoch,
                authenticationGeneration: generation
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let identityError as IdentityCoordinatorError {
            throw identityError
        } catch {
            // The server may already have rotated the refresh family. Once
            // the response is verified as the same principal, do not strand
            // a journaled deletion solely because Keychain could not persist
            // the replacement credentials. Continue this one DELETE retry
            // with the in-memory access token while the transition is exact.
            try await validateTransition(
                transitionEpoch,
                authenticationGeneration: generation
            )
        }
        return refreshed.credentials
    }

    private func refreshLegacyCredentials(
        current: AuthCredentials,
        transitionEpoch: UInt64
    ) async throws -> AuthenticatedPrincipal {
        let credentials = try await runTransitionAuthentication(at: transitionEpoch) { generation in
            try await self.performLegacyRefresh(
                current: current,
                transitionEpoch: transitionEpoch,
                authenticationGeneration: generation
            )
        }
        return try authenticatedPrincipal(from: credentials)
    }

    private func performLegacyRefresh(
        current: AuthCredentials,
        transitionEpoch: UInt64,
        authenticationGeneration generation: UUID
    ) async throws -> AuthCredentials {
        try await validateTransition(
            transitionEpoch,
            authenticationGeneration: generation
        )
        let installationID: String
        do {
            installationID = try await credentialStore.installationIdentifier()
        } catch {
            let storeError = error
            try await validateTransition(
                transitionEpoch,
                authenticationGeneration: generation
            )
            throw storeError
        }
        try await validateTransition(
            transitionEpoch,
            authenticationGeneration: generation
        )
        let requestBody = try encoder.encode(RefreshRequest(refreshToken: current.refreshToken))
        let response: TokenResponse
        do {
            response = try await sendAuthenticationRequest(
                path: "/api/v1/auth/refresh",
                body: requestBody,
                installationID: installationID
            )
        } catch APIError.unauthorized {
            try await validateTransition(
                transitionEpoch,
                authenticationGeneration: generation
            )
            throw APIError.identityRecoveryRequired
        } catch {
            let authenticationError = error
            try await validateTransition(
                transitionEpoch,
                authenticationGeneration: generation
            )
            throw authenticationError
        }
        try await validateTransition(
            transitionEpoch,
            authenticationGeneration: generation
        )
        let principal = try authenticatedPrincipal(from: response)
        try await saveCredentials(
            principal.credentials,
            transitionEpoch: transitionEpoch,
            authenticationGeneration: generation
        )
        return principal.credentials
    }

    private func runTransitionAuthentication(
        at transitionEpoch: UInt64,
        operation: @escaping @Sendable (UUID) async throws -> AuthCredentials
    ) async throws -> AuthCredentials {
        let context = AuthenticationContext.transition(transitionEpoch)
        if let authenticationTask,
           authenticationTask.context == context,
           authenticationTask.generation == authenticationGeneration {
            let credentials = try await authenticationTask.task.value
            try await validateTransition(
                transitionEpoch,
                authenticationGeneration: authenticationTask.generation
            )
            return credentials
        }

        authenticationTask?.task.cancel()
        let generation = authenticationGeneration
        let task = Task { try await operation(generation) }
        authenticationTask = AuthenticationTask(
            context: context,
            generation: generation,
            task: task
        )
        do {
            let credentials = try await task.value
            clearAuthenticationTask(context: context, generation: generation)
            try await validateTransition(
                transitionEpoch,
                authenticationGeneration: generation
            )
            return credentials
        } catch {
            clearAuthenticationTask(context: context, generation: generation)
            throw error
        }
    }

    private func clearAuthenticationTask(
        context: AuthenticationContext,
        generation: UUID
    ) {
        guard authenticationTask?.context == context,
              authenticationTask?.generation == generation else {
            return
        }
        authenticationTask = nil
    }

    private func authenticatedPrincipal(
        from credentials: AuthCredentials
    ) throws -> AuthenticatedPrincipal {
        guard let userID = credentials.userID else {
            throw APIError.identityRecoveryRequired
        }
        let identity: PrincipalIdentity
        do {
            identity = try PrincipalIdentity(serverUserID: userID)
        } catch {
            throw APIError.identityIntegrityFailure
        }
        let canonical = AuthCredentials(
            accessToken: credentials.accessToken,
            refreshToken: credentials.refreshToken,
            tokenType: credentials.tokenType,
            expiresAt: credentials.expiresAt,
            userID: identity.serverUserID
        )
        return AuthenticatedPrincipal(credentials: canonical, identity: identity)
    }

    private func authenticatedPrincipal(
        from response: TokenResponse
    ) throws -> AuthenticatedPrincipal {
        guard !response.accessToken.isEmpty,
              !response.refreshToken.isEmpty,
              !response.tokenType.isEmpty,
              response.expiresIn > 0 else {
            throw APIError.authenticationFailed(
                "The server did not return a complete recoverable session."
            )
        }
        let identity: PrincipalIdentity
        do {
            identity = try PrincipalIdentity(serverUserID: response.userId)
        } catch {
            throw APIError.identityIntegrityFailure
        }
        let credentials = AuthCredentials(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            tokenType: response.tokenType,
            expiresAt: now().addingTimeInterval(response.expiresIn),
            userID: identity.serverUserID
        )
        return AuthenticatedPrincipal(credentials: credentials, identity: identity)
    }

    private func saveCredentials(
        _ credentials: AuthCredentials,
        authorization: EstablishedAuthenticationAuthorization,
        authenticationGeneration generation: UUID
    ) async throws {
        await acquireCredentialMutationGate()
        defer { releaseCredentialMutationGate() }
        try Task.checkCancellation()
        try await validate(authorization, authenticationGeneration: generation)
        do {
            try await credentialStore.saveCredentials(credentials)
        } catch {
            let storeError = error
            try await validateBoundary(
                authorization,
                authenticationGeneration: generation
            )
            throw storeError
        }
        try Task.checkCancellation()
        try await validate(authorization, authenticationGeneration: generation)
    }

    private func saveCredentials(
        _ credentials: AuthCredentials,
        transitionEpoch: UInt64,
        authenticationGeneration generation: UUID? = nil
    ) async throws {
        await acquireCredentialMutationGate()
        defer { releaseCredentialMutationGate() }
        try Task.checkCancellation()
        if let generation {
            try await validateTransition(
                transitionEpoch,
                authenticationGeneration: generation
            )
        } else {
            try await identityCoordinator.validateTransition(epoch: transitionEpoch)
        }
        do {
            try await credentialStore.saveCredentials(credentials)
        } catch {
            let storeError = error
            if let generation {
                try await validateTransition(
                    transitionEpoch,
                    authenticationGeneration: generation
                )
            } else {
                try await identityCoordinator.validateTransition(epoch: transitionEpoch)
            }
            throw storeError
        }
        try Task.checkCancellation()
        if let generation {
            try await validateTransition(
                transitionEpoch,
                authenticationGeneration: generation
            )
        } else {
            try await identityCoordinator.validateTransition(epoch: transitionEpoch)
        }
    }

    private func acquireCredentialMutationGate() async {
        guard credentialMutationLocked else {
            credentialMutationLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            credentialMutationWaiters.append(continuation)
#if DEBUG
            let observers = credentialMutationQueueObservers
            credentialMutationQueueObservers.removeAll()
            observers.forEach { $0.resume() }
#endif
        }
    }

    private func releaseCredentialMutationGate() {
        guard !credentialMutationWaiters.isEmpty else {
            credentialMutationLocked = false
            return
        }
        credentialMutationWaiters.removeFirst().resume()
    }

    /// Pauses the exact ordinary server generation before APIClient exposes a
    /// recovery error to AppState. This closes the actor-hop gap in which a
    /// second submit could otherwise capture Ready and commit a local retry
    /// record before AppState processed the first request's error.
    private func requireSessionRecovery(
        authorization: EstablishedAuthenticationAuthorization,
        authenticationGeneration generation: UUID
    ) async throws {
        let lease = authorization.identityLease
        switch authorization {
        case .serverOperation(let operationLease):
            try await identityCoordinator.pauseServerOperations(
                ifCurrent: operationLease
            )
            guard generation == authenticationGeneration else {
                throw CancellationError()
            }
            try await identityCoordinator.validateBoundary(operationLease)
        case .explicitRecovery:
            // Explicit recovery already owns the coordinator's recovering
            // state. A rejection relatches APIClient, then AppState returns
            // that exact recovery capability to Paused.
            try await validateBoundary(
                authorization,
                authenticationGeneration: generation
            )
        }
        guard generation == authenticationGeneration else {
            throw CancellationError()
        }
        recoveryRequiredLease = lease
        if let beforeReturningIdentityRecoveryRequired {
            await beforeReturningIdentityRecoveryRequired()
            try await validateBoundary(
                authorization,
                authenticationGeneration: generation
            )
        }
    }

    private func validate(
        _ lease: IdentityLease,
        authenticationGeneration generation: UUID
    ) async throws {
        try Task.checkCancellation()
        try await identityCoordinator.validate(lease)
        guard generation == authenticationGeneration else {
            throw CancellationError()
        }
    }

    private func validate(
        _ authorization: EstablishedAuthenticationAuthorization,
        authenticationGeneration generation: UUID
    ) async throws {
        try Task.checkCancellation()
        switch authorization {
        case .serverOperation(let operationLease):
            try await identityCoordinator.validate(operationLease)
        case .explicitRecovery(let identityLease):
            try await identityCoordinator.validate(identityLease)
        }
        guard generation == authenticationGeneration else {
            throw CancellationError()
        }
    }

    private func validateBoundary(
        _ authorization: EstablishedAuthenticationAuthorization,
        authenticationGeneration generation: UUID
    ) async throws {
        try Task.checkCancellation()
        switch authorization {
        case .serverOperation(let operationLease):
            try await identityCoordinator.validateBoundary(operationLease)
        case .explicitRecovery(let identityLease):
            try await identityCoordinator.validate(identityLease)
        }
        guard generation == authenticationGeneration else {
            throw CancellationError()
        }
    }

    private func currentServerOperationLease(
        for identityLease: IdentityLease
    ) async throws -> PrivateServerOperationLease {
        guard let operationLease =
                PrivateServerRequestContext.operationLease,
              operationLease.identityLease == identityLease else {
            throw IdentityCoordinatorError.staleIdentity
        }
        try await identityCoordinator.validate(operationLease)
        return operationLease
    }

    private func validateTransition(
        _ transitionEpoch: UInt64,
        authenticationGeneration generation: UUID
    ) async throws {
        try Task.checkCancellation()
        try await identityCoordinator.validateTransition(epoch: transitionEpoch)
        guard generation == authenticationGeneration else {
            throw CancellationError()
        }
    }

    private func sendAuthenticationRequest<Response: Decodable & Sendable>(
        path: String,
        body: Data?,
        installationID: String,
        authorization: EstablishedAuthenticationAuthorization? = nil,
        authenticationGeneration generation: UUID? = nil
    ) async throws -> Response {
        let request = try makeRequestWithoutCredentialLookup(
            path: path,
            method: "POST",
            body: body,
            bearerToken: nil,
            installationID: installationID,
            additionalHeaders: [:]
        )
        let data: Data
        let response: HTTPURLResponse
        if let authorization, let generation {
            try await validate(
                authorization,
                authenticationGeneration: generation
            )
            do {
                (data, response) = try await perform(request)
                try await validateBoundary(
                    authorization,
                    authenticationGeneration: generation
                )
            } catch {
                let requestError = error
                try await validateBoundary(
                    authorization,
                    authenticationGeneration: generation
                )
                throw requestError
            }
        } else {
            (data, response) = try await perform(request)
        }
        if response.statusCode == 401 {
            throw APIError.unauthorized
        }
        try validate(response: response, data: data)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding
        }
    }

    private func makeRequest(
        path: String,
        method: String,
        body: Data?,
        bearerToken: String?,
        additionalHeaders: [String: String],
        serverOperationLease: PrivateServerOperationLease
    ) async throws -> URLRequest {
        try await identityCoordinator.validate(serverOperationLease)
        let installationID: String
        do {
            installationID = try await credentialStore.installationIdentifier()
        } catch {
            let storeError = error
            try await identityCoordinator.validateBoundary(
                serverOperationLease
            )
            throw storeError
        }
        try await identityCoordinator.validate(serverOperationLease)
        return try makeRequestWithoutCredentialLookup(
            path: path,
            method: method,
            body: body,
            bearerToken: bearerToken,
            installationID: installationID,
            additionalHeaders: additionalHeaders
        )
    }

    private func makeRequestWithoutCredentialLookup(
        path: String,
        method: String,
        body: Data?,
        bearerToken: String?,
        installationID: String,
        additionalHeaders: [String: String]
    ) throws -> URLRequest {
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let pathAndQuery = normalizedPath.split(
            separator: "?",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        var url = configuration.baseURL.appending(path: String(pathAndQuery[0]))
        if pathAndQuery.count == 2,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = String(pathAndQuery[1])
            if let resolved = components.url {
                url = resolved
            }
        }
        var request = URLRequest(url: url, timeoutInterval: configuration.requestTimeout)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A locally generated installation identifier is not authentication
        // and the server does not consume it. Keep it off the wire so a
        // persistent device identifier is not collected without a purpose.
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        for (header, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }
        return request
    }

    private func perform(
        _ request: URLRequest,
        serverOperationLease: PrivateServerOperationLease
    ) async throws -> (Data, HTTPURLResponse) {
        try await identityCoordinator.validate(serverOperationLease)
        do {
            let result = try await perform(request)
            try await identityCoordinator.validateBoundary(
                serverOperationLease
            )
            return result
        } catch {
            let requestError = error
            try await identityCoordinator.validateBoundary(
                serverOperationLease
            )
            throw requestError
        }
    }

    private func perform(
        _ request: URLRequest,
        transitionEpoch: UInt64,
        authenticationGeneration generation: UUID
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            let result = try await perform(request)
            try await validateTransition(
                transitionEpoch,
                authenticationGeneration: generation
            )
            return result
        } catch {
            let requestError = error
            try await validateTransition(
                transitionEpoch,
                authenticationGeneration: generation
            )
            throw requestError
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            return (data, httpResponse)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw APIError.transport(code: error.code, message: Self.transportMessage(for: error.code))
        } catch {
            throw APIError.transport(code: .unknown, message: "The network request failed. Please try again.")
        }
    }

    private func validate(response: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            let details = Self.serverError(from: data, statusCode: response.statusCode)
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw APIError.http(
                statusCode: response.statusCode,
                code: details.code,
                message: details.message,
                retryAfter: retryAfter
            )
        }
    }

    private func sleep(_ delay: TimeInterval, noLaterThan deadline: Date) async throws {
        let remaining = deadline.timeIntervalSince(now())
        guard remaining > 0 else { return }
        let boundedDelay = min(delay, remaining)
        guard boundedDelay > 0 else {
            await Task.yield()
            return
        }
        try await Task.sleep(for: .seconds(boundedDelay))
    }

    private static func serverError(from data: Data, statusCode: Int) -> ServerErrorDetails {
        var code: String?
        var message: String?
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            code = object["code"] as? String
            message = object["message"] as? String
            if let detail = object["detail"] as? String {
                message = detail
            } else if let detail = object["detail"] as? [String: Any] {
                code = (detail["code"] as? String) ?? code
                message = (detail["message"] as? String) ?? message
            }
        }
        return ServerErrorDetails(
            code: code,
            message: message ?? defaultMessage(for: statusCode)
        )
    }

    private static func defaultMessage(for statusCode: Int) -> String {
        switch statusCode {
        case 400: return "The request was not valid."
        case 401, 403: return "You are not authorized to perform this action."
        case 404: return "The requested trip could not be found."
        case 408: return "The server took too long to respond."
        case 409: return "The trip could not be updated because it changed elsewhere."
        case 429: return "Too many requests. Please wait and try again."
        case 500...599: return "Itinera is temporarily unavailable. Please try again."
        default: return "The request failed (\(statusCode))."
        }
    }

    private static func transportMessage(for code: URLError.Code) -> String {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost:
            return "You appear to be offline. Your pending trips are saved on this device."
        case .timedOut:
            return "The request timed out. Please try again."
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return "Itinera could not reach the server. Please try again."
        default:
            return "The network request failed. Please try again."
        }
    }
}
