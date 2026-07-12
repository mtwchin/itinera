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
}

struct JobPollingPolicy: Sendable, Equatable {
    var initialDelay: TimeInterval = 1
    var maximumDelay: TimeInterval = 10
    var multiplier: Double = 1.8
    var jitterFraction: Double = 0.2
    var timeout: TimeInterval = 3 * 60

    func delay(forAttempt attempt: Int, randomUnit: Double = Double.random(in: 0...1)) -> TimeInterval {
        let exponential = min(maximumDelay, initialDelay * pow(multiplier, Double(max(attempt, 0))))
        let clampedRandom = min(max(randomUnit, 0), 1)
        let jitterMultiplier = 1 + ((clampedRandom * 2) - 1) * jitterFraction
        return max(0, exponential * jitterMultiplier)
    }
}

actor APIClient {
    private struct TokenResponse: Decodable, Sendable {
        let accessToken: String
        let refreshToken: String?
        let tokenType: String
        let expiresIn: TimeInterval
    }

    private struct RefreshRequest: Encodable, Sendable {
        let refreshToken: String
    }

    private struct ServerErrorDetails: Sendable {
        let code: String?
        let message: String
    }

    private let configuration: APIConfiguration
    private let session: URLSession
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

    func jobStatus(_ jobID: String) async throws -> JobStatusResponse {
        try await send(
            path: "/api/v1/itineraries/\(jobID)",
            as: JobStatusResponse.self
        )
    }

    func savedItineraries() async throws -> [SavedItinerary] {
        try await send(path: "/api/v1/itineraries", as: [SavedItinerary].self)
    }

    func awaitItinerary(
        _ jobID: String,
        policy: JobPollingPolicy = JobPollingPolicy()
    ) async throws -> Itinerary {
        let deadline = now().addingTimeInterval(policy.timeout)
        var attempt = 0

        while now() < deadline {
            try Task.checkCancellation()

            do {
                let status = try await jobStatus(jobID)
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
                attempt += 1
                continue
            }

            let delay = policy.delay(forAttempt: attempt)
            try await sleep(delay, noLaterThan: deadline)
            attempt += 1
        }

        throw APIError.pollingTimedOut(jobID: jobID)
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
            expiresAt: now().addingTimeInterval(response.expiresIn)
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
            try await credentialStore.clearCredentials()
            return try await performCreateGuestCredentials()
        }
        let credentials = AuthCredentials(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? current.refreshToken,
            tokenType: response.tokenType,
            expiresAt: now().addingTimeInterval(response.expiresIn)
        )
        try await credentialStore.saveCredentials(credentials)
        return credentials
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
        let url = configuration.baseURL.appending(path: normalizedPath)
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
