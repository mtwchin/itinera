import Foundation

enum APIError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case decoding
    case transport(code: URLError.Code, message: String)
    case unauthorized
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

    var requiresIdentityRecovery: Bool {
        if case .authenticationFailed = self { return true }
        return false
    }
}

enum AppleAccountConnectionOutcome: Sendable, Equatable {
    case linked
    case recoveredExistingLibrary
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

struct JobStreamingPolicy: Sendable, Equatable {
    /// Each connection is resource-bounded to two minutes; two attempts leave
    /// most of the ten-minute generation budget for the polling fallback.
    var maximumConnections = 2
}

struct ItinerarySSEEventDecoder {
    private let decoder: JSONDecoder
    private var eventName: String?
    private var dataLines: [String] = []

    init() {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    mutating func consume(line: String) throws -> JobStatusResponse? {
        guard !line.isEmpty else {
            defer {
                eventName = nil
                dataLines.removeAll(keepingCapacity: true)
            }
            guard eventName == "status" || eventName == "result",
                  !dataLines.isEmpty
            else { return nil }
            return try decoder.decode(
                JobStatusResponse.self,
                from: Data(dataLines.joined(separator: "\n").utf8)
            )
        }
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("event:") {
            eventName = String(line.dropFirst("event:".count))
                .trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            dataLines.append(
                String(line.dropFirst("data:".count))
                    .trimmingCharacters(in: .whitespaces)
            )
        }
        return nil
    }

    /// `URLSession.AsyncBytes.lines` may omit the final empty line when a
    /// server closes immediately after a correctly terminated SSE frame.
    /// Flush any buffered frame at EOF so a terminal event is not discarded
    /// and needlessly recovered through polling.
    mutating func finish() throws -> JobStatusResponse? {
        guard !dataLines.isEmpty else { return nil }
        return try consume(line: "")
    }
}

actor APIClient {
    private struct TokenResponse: Decodable, Sendable {
        // JSONDecoder's `.convertFromSnakeCase` maps `user_id` to `userId`,
        // not `userID`. Keep this spelling aligned with the decoded key so a
        // valid session response does not fail before identity validation.
        let userId: String
        let accessToken: String
        let refreshToken: String?
        let tokenType: String
        let expiresIn: TimeInterval
    }

    private struct RefreshRequest: Encodable, Sendable {
        let refreshToken: String
    }

    private struct AppleIdentityRequest: Encodable, Sendable {
        let identityToken: String
    }

    private struct AIConsentRequest: Encodable, Sendable {
        let version: Int
    }

    private struct ServerErrorDetails: Sendable {
        let code: String?
        let message: String
    }

    private let configuration: APIConfiguration
    private let session: URLSession
    private let streamSession: URLSession
    private let credentialStore: any CredentialStoring
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let now: @Sendable () -> Date
    private var authenticationTask: Task<AuthCredentials, Error>?

    init(
        configuration: APIConfiguration,
        session: URLSession,
        credentialStore: any CredentialStoring,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.session = session
        let streamConfiguration = session.configuration
        streamConfiguration.timeoutIntervalForResource = 120
        streamConfiguration.timeoutIntervalForRequest = max(
            configuration.requestTimeout,
            30
        )
        self.streamSession = URLSession(configuration: streamConfiguration)
        self.credentialStore = credentialStore
        self.now = now

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = encoder
    }

    func createItinerary(
        _ payload: GenerateItineraryRequest,
        idempotencyKey: UUID = UUID()
    ) async throws -> JobAccepted {
        try await send(
            path: "/api/v1/itineraries",
            method: "POST",
            body: encoder.encode(payload),
            additionalHeaders: ["Idempotency-Key": idempotencyKey.uuidString.lowercased()],
            as: JobAccepted.self
        )
    }

    func grantAIConsent(version: Int) async throws {
        try await sendWithoutResponse(
            path: "/api/v1/auth/ai-consent",
            method: "POST",
            body: encoder.encode(AIConsentRequest(version: version))
        )
    }

    func withdrawAIConsent() async throws {
        try await sendWithoutResponse(
            path: "/api/v1/auth/ai-consent",
            method: "DELETE"
        )
    }

    func jobStatus(_ jobID: String) async throws -> JobStatusResponse {
        try await send(
            path: "/api/v1/itineraries/\(jobID)",
            as: JobStatusResponse.self
        )
    }

    func savedItineraries(includeArchived: Bool = false) async throws -> [SavedItinerary] {
        let path = includeArchived
            ? "/api/v1/itineraries?include_archived=true"
            : "/api/v1/itineraries"
        return try await send(path: path, as: [SavedItinerary].self)
    }

    func updateTrip(
        _ jobID: String,
        title: String? = nil,
        archived: Bool? = nil
    ) async throws -> TripMutationResponse {
        try await send(
            path: "/api/v1/itineraries/\(jobID)",
            method: "PATCH",
            body: encoder.encode(
                TripUpdateRequest(title: title, archived: archived)
            ),
            as: TripMutationResponse.self
        )
    }

    func deleteTrip(_ jobID: String) async throws {
        try await sendWithoutResponse(
            path: "/api/v1/itineraries/\(jobID)",
            method: "DELETE"
        )
    }

    func duplicateTrip(_ jobID: String) async throws -> SavedItinerary {
        try await send(
            path: "/api/v1/itineraries/\(jobID)/duplicate",
            method: "POST",
            as: SavedItinerary.self
        )
    }

    func reviseTrip(
        _ jobID: String,
        expectedVersion: Int,
        mutationId: String,
        operations: [TripRevisionOperation]
    ) async throws -> ItineraryRevisionResponse {
        try await send(
            path: "/api/v1/itineraries/\(jobID)/revisions",
            method: "POST",
            body: encoder.encode(
                ItineraryRevisionCreate(
                    expectedVersion: expectedVersion,
                    mutationId: mutationId,
                    operations: operations
                )
            ),
            as: ItineraryRevisionResponse.self
        )
    }

    func aiEditTrip(
        _ jobID: String,
        message: String,
        day: Int?,
        expectedVersion: Int
    ) async throws -> ItineraryRevisionResponse {
        try await send(
            path: "/api/v1/itineraries/\(jobID)/ai-edit",
            method: "POST",
            body: encoder.encode(AIEditRequest(message: message, expectedVersion: expectedVersion, day: day)),
            as: ItineraryRevisionResponse.self
        )
    }

    func revisionHistory(_ jobID: String) async throws -> [ItineraryRevisionResponse] {
        try await send(
            path: "/api/v1/itineraries/\(jobID)/revisions",
            as: [ItineraryRevisionResponse].self
        )
    }

    func reservations(_ jobID: String) async throws -> [TripReservation] {
        try await send(path: "/api/v1/itineraries/\(jobID)/reservations", as: [TripReservation].self)
    }

    func createReservation(_ jobID: String, input: TripReservationCreate) async throws -> TripReservation {
        try await send(path: "/api/v1/itineraries/\(jobID)/reservations", method: "POST", body: encoder.encode(input), as: TripReservation.self)
    }

    func deleteReservation(_ jobID: String, reservationID: String) async throws {
        try await sendWithoutResponse(path: "/api/v1/itineraries/\(jobID)/reservations/\(reservationID)", method: "DELETE")
    }

    func checklist(_ jobID: String) async throws -> [TripChecklistItem] {
        try await send(path: "/api/v1/itineraries/\(jobID)/checklist", as: [TripChecklistItem].self)
    }

    func createChecklistItem(_ jobID: String, input: TripChecklistItemCreate) async throws -> TripChecklistItem {
        try await send(path: "/api/v1/itineraries/\(jobID)/checklist", method: "POST", body: encoder.encode(input), as: TripChecklistItem.self)
    }

    func updateChecklistItem(_ jobID: String, itemID: String, input: TripChecklistItemUpdate) async throws -> TripChecklistItem {
        try await send(path: "/api/v1/itineraries/\(jobID)/checklist/\(itemID)", method: "PATCH", body: encoder.encode(input), as: TripChecklistItem.self)
    }

    func deleteChecklistItem(_ jobID: String, itemID: String) async throws {
        try await sendWithoutResponse(path: "/api/v1/itineraries/\(jobID)/checklist/\(itemID)", method: "DELETE")
    }

    func expenses(_ jobID: String) async throws -> [TripExpense] {
        try await send(path: "/api/v1/itineraries/\(jobID)/expenses", as: [TripExpense].self)
    }

    func createExpense(_ jobID: String, input: TripExpenseCreate) async throws -> TripExpense {
        try await send(path: "/api/v1/itineraries/\(jobID)/expenses", method: "POST", body: encoder.encode(input), as: TripExpense.self)
    }

    func deleteExpense(_ jobID: String, expenseID: String) async throws {
        try await sendWithoutResponse(path: "/api/v1/itineraries/\(jobID)/expenses/\(expenseID)", method: "DELETE")
    }

    func collaborators(_ jobID: String) async throws -> [TripCollaborator] {
        try await send(path: "/api/v1/itineraries/\(jobID)/collaborators", as: [TripCollaborator].self)
    }

    func createCollaborationInvite(_ jobID: String, input: CollaborationInviteCreate) async throws -> CollaborationInvite {
        try await send(path: "/api/v1/itineraries/\(jobID)/collaboration-invites", method: "POST", body: encoder.encode(input), as: CollaborationInvite.self)
    }

    func removeCollaborator(_ jobID: String, collaboratorID: String) async throws {
        try await sendWithoutResponse(path: "/api/v1/itineraries/\(jobID)/collaborators/\(collaboratorID)", method: "DELETE")
    }

    func acceptCollaborationInvite(token: String) async throws -> TripCollaborator {
        try await send(path: "/api/v1/collaboration-invites/accept", method: "POST", body: encoder.encode(CollaborationInviteAccept(token: token)), as: TripCollaborator.self)
    }

    func placeReports(_ jobID: String) async throws -> [PlaceReport] {
        try await send(path: "/api/v1/itineraries/\(jobID)/place-reports", as: [PlaceReport].self)
    }

    func createPlaceReport(_ jobID: String, input: PlaceReportCreate) async throws -> PlaceReport {
        try await send(path: "/api/v1/itineraries/\(jobID)/place-reports", method: "POST", body: encoder.encode(input), as: PlaceReport.self)
    }

    func deleteMyData() async throws {
        try await sendDeletionRequest(
            path: "/api/v1/auth/me",
            method: "DELETE",
            body: encoder.encode(["confirmation": "DELETE"])
        )
    }

    func registerDeviceToken(_ token: String) async throws {
        struct Payload: Encodable { let token: String; let platform: String }
        let body = try encoder.encode(Payload(token: token, platform: "apns"))
        try await sendWithoutResponse(
            path: "/api/v1/notifications/device-token",
            method: "POST",
            body: body
        )
    }

    /// Returns the stable server principal before the caller reads or writes
    /// principal-scoped device state. Legacy credentials are refreshed once to
    /// enrich them with the now-required `user_id` contract.
    func ensurePrincipalID() async throws -> String {
        let credentials = try await credentialsForRequest()
        if let userID = credentials.userID { return userID }
        let refreshed = try await refreshCredentials(current: credentials)
        guard let userID = refreshed.userID else {
            throw APIError.authenticationFailed(
                "Your session needs recovery before private trips can be opened."
            )
        }
        return userID
    }

    /// Finalizes a server-confirmed deletion only after device-local cleanup
    /// has completed, leaving a safe replay credential if that cleanup fails.
    func finalizeDeletedAccountOnDevice() async throws {
        try await credentialStore.clearAccountState()
    }

    func connectAppleAccount(identityToken: String) async throws -> AppleAccountConnectionOutcome {
        let body = try encoder.encode(AppleIdentityRequest(identityToken: identityToken))
        let response: TokenResponse
        let outcome: AppleAccountConnectionOutcome
        do {
            response = try await send(
                path: "/api/v1/auth/apple/link",
                method: "POST",
                body: body,
                as: TokenResponse.self
            )
            outcome = .linked
        } catch APIError.http(
            let statusCode,
            let code,
            _,
            _
        ) where statusCode == 409 && code == "apple_account_exists" {
            let installationID = try await credentialStore.installationIdentifier()
            response = try await sendAuthenticationRequest(
                path: "/api/v1/auth/apple",
                body: body,
                installationID: installationID
            )
            outcome = .recoveredExistingLibrary
        }
        guard let refreshToken = response.refreshToken, !refreshToken.isEmpty else {
            throw APIError.authenticationFailed("Apple sign-in did not return a recoverable session.")
        }
        try await credentialStore.saveCredentials(
            AuthCredentials(
                accessToken: response.accessToken,
                refreshToken: refreshToken,
                tokenType: response.tokenType,
                expiresAt: now().addingTimeInterval(response.expiresIn),
                userID: try resolvedUserID(from: response)
            )
        )
        return outcome
    }

    func popularItineraries() async throws -> [PopularItinerarySummary] {
        try await send(
            path: "/api/v1/popular-itineraries",
            as: [PopularItinerarySummary].self
        )
    }

    func popularItinerary(_ itineraryID: String) async throws -> PopularItineraryDetail {
        try await send(
            path: "/api/v1/popular-itineraries/\(itineraryID)",
            as: PopularItineraryDetail.self
        )
    }

    func savePopularItinerary(_ itineraryID: String) async throws -> SavePopularItineraryResponse {
        try await send(
            path: "/api/v1/popular-itineraries/\(itineraryID)/saved",
            method: "PUT",
            as: SavePopularItineraryResponse.self
        )
    }

    func awaitItinerary(
        _ jobID: String,
        policy: JobPollingPolicy = JobPollingPolicy(),
        streamingPolicy: JobStreamingPolicy = JobStreamingPolicy()
    ) async throws -> Itinerary {
        let deadline = now().addingTimeInterval(policy.timeout)
        for _ in 0..<max(0, streamingPolicy.maximumConnections) {
            guard now() < deadline else { break }
            do {
                if let status = try await streamTerminalStatus(jobID) {
                    return try itinerary(from: status)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as APIError where error == .unauthorized {
                throw error
            } catch {
                // A bounded stream is a latency optimization. The status
                // endpoint remains authoritative when it closes or fails.
            }
        }
        return try await pollItinerary(jobID, policy: policy, deadline: deadline)
    }

    private func pollItinerary(
        _ jobID: String,
        policy: JobPollingPolicy,
        deadline: Date
    ) async throws -> Itinerary {
        var attempt = 0

        while now() < deadline {
            try Task.checkCancellation()

            do {
                let status = try await jobStatus(jobID)
                if status.status == .succeeded || status.status == .failed {
                    return try itinerary(from: status)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as APIError where error.isRetryable {
                let delay = max(policy.delay(forAttempt: attempt), error.retryAfter ?? 0)
                try await sleep(delay, noLaterThan: deadline)
                attempt += 1
                continue
            }

            let delay = policy.delay(forAttempt: attempt)
            try await sleep(delay, noLaterThan: deadline)
            attempt += 1
        }

        throw APIError.pollingTimedOut(jobID: jobID)
    }

    private func itinerary(from status: JobStatusResponse) throws -> Itinerary {
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
                code: status.errorCode ?? "generation_failed",
                message: status.error ?? "Itinerary generation failed."
            )
        case .pending, .running:
            throw APIError.invalidResponse
        }
    }

    private func streamTerminalStatus(
        _ jobID: String
    ) async throws -> JobStatusResponse? {
        var credentials = try await credentialsForRequest()
        var request = try await makeRequest(
            path: "/api/v1/itineraries/\(jobID)/stream",
            method: "GET",
            body: nil,
            bearerToken: credentials.accessToken,
            additionalHeaders: ["Accept": "text/event-stream"]
        )
        var opened = try await streamSession.bytes(for: request)
        var response = try streamHTTPResponse(opened.1)
        if response.statusCode == 401 {
            credentials = try await refreshCredentials(current: credentials)
            request.setValue(
                "Bearer \(credentials.accessToken)",
                forHTTPHeaderField: "Authorization"
            )
            opened = try await streamSession.bytes(for: request)
            response = try streamHTTPResponse(opened.1)
            if response.statusCode == 401 { throw APIError.unauthorized }
        }
        try validateStreamResponse(response)

        var decoder = ItinerarySSEEventDecoder()
        for try await line in opened.0.lines {
            try Task.checkCancellation()
            if let status = try decoder.consume(line: line),
               status.status == .succeeded || status.status == .failed {
                return status
            }
        }
        if let status = try decoder.finish(),
           status.status == .succeeded || status.status == .failed {
            return status
        }
        return nil
    }

    private func streamHTTPResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        return response
    }

    private func validateStreamResponse(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.http(
                statusCode: response.statusCode,
                code: nil,
                message: Self.defaultMessage(for: response.statusCode),
                retryAfter: response.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(TimeInterval.init)
            )
        }
        guard response.value(forHTTPHeaderField: "Content-Type")?
            .localizedCaseInsensitiveContains("text/event-stream") == true
        else { throw APIError.invalidResponse }
    }

    private func send<Response: Decodable & Sendable>(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        additionalHeaders: [String: String] = [:],
        as type: Response.Type
    ) async throws -> Response {
        var credentials = try await credentialsForRequest()
        var request = try await makeRequest(
            path: path,
            method: method,
            body: body,
            bearerToken: credentials.accessToken,
            additionalHeaders: additionalHeaders
        )

        var (data, response) = try await perform(request)
        if response.statusCode == 401 {
            credentials = try await refreshCredentials(current: credentials)
            request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
            (data, response) = try await perform(request)
            if response.statusCode == 401 {
                throw APIError.unauthorized
            }
        }

        try validate(response: response, data: data)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding
        }
    }

    private func sendWithoutResponse(
        path: String,
        method: String,
        body: Data? = nil,
        additionalHeaders: [String: String] = [:]
    ) async throws {
        var credentials = try await credentialsForRequest()
        var request = try await makeRequest(
            path: path,
            method: method,
            body: body,
            bearerToken: credentials.accessToken,
            additionalHeaders: additionalHeaders
        )

        var (data, response) = try await perform(request)
        if response.statusCode == 401 {
            credentials = try await refreshCredentials(current: credentials)
            request.setValue(
                "Bearer \(credentials.accessToken)",
                forHTTPHeaderField: "Authorization"
            )
            (data, response) = try await perform(request)
            if response.statusCode == 401 {
                throw APIError.unauthorized
            }
        }
        try validate(response: response, data: data)
    }

    /// Account deletion has an intentionally idempotent backend contract. It
    /// must not create a new guest identity while replaying a deletion after a
    /// prior server-side success, so it bypasses the normal auth refresh path.
    private func sendDeletionRequest(
        path: String,
        method: String,
        body: Data?
    ) async throws {
        let credentials: AuthCredentials
        do {
            guard let stored = try await credentialStore.loadCredentials() else {
                throw APIError.unauthorized
            }
            credentials = stored
        } catch KeychainError.invalidData {
            try await credentialStore.clearCredentials()
            throw APIError.unauthorized
        }
        var request = try await makeRequest(
            path: path,
            method: method,
            body: body,
            bearerToken: credentials.accessToken,
            additionalHeaders: [:]
        )
        var (data, response) = try await perform(request)
        if response.statusCode == 401 {
            let refreshed = try await refreshCredentials(current: credentials)
            request.setValue(
                "Bearer \(refreshed.accessToken)",
                forHTTPHeaderField: "Authorization"
            )
            (data, response) = try await perform(request)
            if response.statusCode == 401 {
                throw APIError.unauthorized
            }
        }
        try validate(response: response, data: data)
    }

    private func credentialsForRequest() async throws -> AuthCredentials {
        if let authenticationTask {
            return try await authenticationTask.value
        }

        let task = Task { try await self.loadOrCreateCredentials() }
        authenticationTask = task
        do {
            let credentials = try await task.value
            authenticationTask = nil
            return credentials
        } catch {
            authenticationTask = nil
            throw error
        }
    }

    private func loadOrCreateCredentials() async throws -> AuthCredentials {
        do {
            if let credentials = try await credentialStore.loadCredentials() {
                if credentials.isExpired(at: now()) {
                    return try await performRefreshCredentials(current: credentials)
                }
                return credentials
            }
        } catch KeychainError.invalidData {
            try await credentialStore.clearCredentials()
        }
        return try await performCreateGuestCredentials()
    }

    private func performCreateGuestCredentials() async throws -> AuthCredentials {
        let installationID = try await credentialStore.installationIdentifier()
        let response: TokenResponse = try await sendAuthenticationRequest(
            path: "/api/v1/auth/guest",
            body: nil,
            installationID: installationID
        )
        guard let refreshToken = response.refreshToken, !refreshToken.isEmpty else {
            throw APIError.authenticationFailed("The server did not create a complete guest session.")
        }
        let credentials = AuthCredentials(
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            tokenType: response.tokenType,
            expiresAt: now().addingTimeInterval(response.expiresIn),
            userID: try resolvedUserID(from: response)
        )
        try await credentialStore.saveCredentials(credentials)
        return credentials
    }

    private func refreshCredentials(current: AuthCredentials) async throws -> AuthCredentials {
        if let authenticationTask {
            return try await authenticationTask.value
        }

        let task = Task { try await self.refreshIfCurrent(current) }
        authenticationTask = task
        do {
            let credentials = try await task.value
            authenticationTask = nil
            return credentials
        } catch {
            authenticationTask = nil
            throw error
        }
    }

    private func refreshIfCurrent(_ current: AuthCredentials) async throws -> AuthCredentials {
        if let stored = try await credentialStore.loadCredentials(),
           stored.accessToken != current.accessToken {
            return stored
        }
        return try await performRefreshCredentials(current: current)
    }

    private func performRefreshCredentials(current: AuthCredentials) async throws -> AuthCredentials {
        let installationID = try await credentialStore.installationIdentifier()
        let requestBody = try encoder.encode(RefreshRequest(refreshToken: current.refreshToken))
        let response: TokenResponse
        do {
            response = try await sendAuthenticationRequest(
                path: "/api/v1/auth/refresh",
                body: requestBody,
                installationID: installationID
            )
        } catch APIError.unauthorized {
            // A rejected refresh can mean this device still owns a library
            // that needs explicit recovery. Never hide it behind a silently
            // created guest account.
            throw APIError.authenticationFailed(
                "Your session needs recovery. Your saved trips remain on this device."
            )
        }
        guard let refreshToken = response.refreshToken, !refreshToken.isEmpty else {
            throw APIError.authenticationFailed(
                "The server did not refresh this account session."
            )
        }
        let credentials = AuthCredentials(
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            tokenType: response.tokenType,
            expiresAt: now().addingTimeInterval(response.expiresIn),
            userID: try resolvedUserID(
                from: response,
                existingUserID: current.userID
            )
        )
        try await credentialStore.saveCredentials(credentials)
        return credentials
    }

    private func resolvedUserID(
        from response: TokenResponse,
        existingUserID: String? = nil
    ) throws -> String? {
        guard let userID = UUID(uuidString: response.userId) else {
            throw APIError.decoding
        }
        let normalizedUserID = userID.uuidString.lowercased()
        if let existingUserID,
           existingUserID.lowercased() != normalizedUserID {
            throw APIError.authenticationFailed(
                "Your account identity changed during session refresh. Please recover your library."
            )
        }
        return normalizedUserID
    }

    private func sendAuthenticationRequest<Response: Decodable & Sendable>(
        path: String,
        body: Data?,
        installationID: String
    ) async throws -> Response {
        let request = try makeRequestWithoutCredentialLookup(
            path: path,
            method: "POST",
            body: body,
            bearerToken: nil,
            installationID: installationID,
            additionalHeaders: [:]
        )
        let (data, response) = try await perform(request)
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
        additionalHeaders: [String: String]
    ) async throws -> URLRequest {
        let installationID = try await credentialStore.installationIdentifier()
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
        request.setValue(installationID, forHTTPHeaderField: "X-Installation-Id")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        for (header, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }
        return request
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
                message: Self.messageWithSupportReference(
                    details.message,
                    response.value(forHTTPHeaderField: "X-Request-ID")
                ),
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

    private static func messageWithSupportReference(
        _ message: String,
        _ requestID: String?
    ) -> String {
        guard let requestID,
              requestID.count == 32,
              requestID.allSatisfy({ $0.isASCII && $0.isHexDigit })
        else {
            return message
        }
        return "\(message) Reference ID: \(requestID.lowercased())."
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
