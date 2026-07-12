import Foundation
import XCTest
@testable import Itinera

final class APIClientTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testCreateItineraryAuthenticatesGuestAndSendsIdempotencyKey() async throws {
        let idempotencyKey = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let credentialStore = MemoryCredentialStore(installationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        let client = makeClient(credentialStore: credentialStore)

        URLProtocolStub.setHandler { request in
            switch request.url?.path {
            case "/api/v1/auth/guest":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "X-Installation-Id"),
                    "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
                )
                return .json(
                    statusCode: 200,
                    body: """
                    {
                      "access_token": "access-1",
                      "refresh_token": "refresh-1",
                      "token_type": "Bearer",
                      "expires_in": 3600
                    }
                    """
                )
            case "/api/v1/itineraries":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Idempotency-Key"),
                    idempotencyKey.uuidString.lowercased()
                )
                let body = try XCTUnwrap(request.bodyData)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(json["arrival_date"] as? String, "2026-08-01")
                return .json(
                    statusCode: 202,
                    body: """
                    {
                      "job_id": "job-123",
                      "stream_url": "/api/v1/itineraries/job-123/stream",
                      "status_url": "/api/v1/itineraries/job-123"
                    }
                    """
                )
            default:
                XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
                return .json(statusCode: 404, body: "{}")
            }
        }

        let accepted = try await client.createItinerary(sampleRequest, idempotencyKey: idempotencyKey)
        XCTAssertEqual(accepted.jobId, "job-123")
        let stored = try await credentialStore.loadCredentials()
        XCTAssertEqual(stored?.refreshToken, "refresh-1")
    }

    func testUnauthorizedResponseRefreshesOnceAndRetriesWithNewBearerToken() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            credentials: AuthCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-1",
                tokenType: "Bearer",
                expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
            )
        )
        let client = makeClient(credentialStore: credentialStore)
        let lock = NSLock()
        var itineraryRequests = 0
        var refreshRequests = 0

        URLProtocolStub.setHandler { request in
            switch request.url?.path {
            case "/api/v1/itineraries":
                lock.lock()
                itineraryRequests += 1
                let requestNumber = itineraryRequests
                lock.unlock()
                if requestNumber == 1 {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old-access")
                    return .json(statusCode: 401, body: #"{"detail":"expired"}"#)
                }
                XCTAssertEqual(requestNumber, 2)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
                return .json(statusCode: 200, body: "[]")
            case "/api/v1/auth/refresh":
                lock.lock()
                refreshRequests += 1
                lock.unlock()
                XCTAssertEqual(request.httpMethod, "POST")
                return .json(
                    statusCode: 200,
                    body: """
                    {
                      "access_token": "new-access",
                      "refresh_token": "refresh-2",
                      "token_type": "Bearer",
                      "expires_in": 3600
                    }
                    """
                )
            default:
                XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
                return .json(statusCode: 404, body: "{}")
            }
        }

        let trips = try await client.savedItineraries()
        XCTAssertTrue(trips.isEmpty)
        XCTAssertEqual(itineraryRequests, 2)
        XCTAssertEqual(refreshRequests, 1)
        let stored = try await credentialStore.loadCredentials()
        XCTAssertEqual(stored?.accessToken, "new-access")
        XCTAssertEqual(stored?.refreshToken, "refresh-2")
    }

    func testConcurrentExpiredRequestsShareOneRotatingRefresh() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            credentials: AuthCredentials(
                accessToken: "expired-access",
                refreshToken: "refresh-1",
                tokenType: "bearer",
                expiresAt: Date(timeIntervalSince1970: 1_000)
            )
        )
        let client = makeClient(credentialStore: credentialStore)
        let lock = NSLock()
        var refreshRequests = 0
        var itineraryRequests = 0

        URLProtocolStub.setHandler { request in
            switch request.url?.path {
            case "/api/v1/auth/refresh":
                lock.lock()
                refreshRequests += 1
                lock.unlock()
                Thread.sleep(forTimeInterval: 0.05)
                return .json(
                    statusCode: 200,
                    body: """
                    {
                      "access_token": "new-access",
                      "refresh_token": "refresh-2",
                      "token_type": "bearer",
                      "expires_in": 3600
                    }
                    """
                )
            case "/api/v1/itineraries":
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer new-access"
                )
                lock.lock()
                itineraryRequests += 1
                lock.unlock()
                return .json(statusCode: 200, body: "[]")
            default:
                XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
                return .json(statusCode: 404, body: "{}")
            }
        }

        async let first = client.savedItineraries()
        async let second = client.savedItineraries()
        let firstResult = try await first
        let secondResult = try await second

        XCTAssertTrue(firstResult.isEmpty)
        XCTAssertTrue(secondResult.isEmpty)
        XCTAssertEqual(refreshRequests, 1)
        XCTAssertEqual(itineraryRequests, 2)
    }

    func testRejectedRefreshClearsCredentialsAndBootstrapsNewGuest() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            credentials: AuthCredentials(
                accessToken: "expired-access",
                refreshToken: "revoked-refresh",
                tokenType: "bearer",
                expiresAt: Date(timeIntervalSince1970: 1_000)
            )
        )
        let client = makeClient(credentialStore: credentialStore)

        URLProtocolStub.setHandler { request in
            switch request.url?.path {
            case "/api/v1/auth/refresh":
                return .json(statusCode: 401, body: #"{"detail":"revoked"}"#)
            case "/api/v1/auth/guest":
                return .json(
                    statusCode: 201,
                    body: """
                    {
                      "access_token": "guest-access",
                      "refresh_token": "guest-refresh",
                      "token_type": "bearer",
                      "expires_in": 3600
                    }
                    """
                )
            case "/api/v1/itineraries":
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer guest-access"
                )
                return .json(statusCode: 200, body: "[]")
            default:
                XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
                return .json(statusCode: 404, body: "{}")
            }
        }

        let trips = try await client.savedItineraries()
        XCTAssertTrue(trips.isEmpty)
        let stored = try await credentialStore.loadCredentials()
        XCTAssertEqual(stored?.refreshToken, "guest-refresh")
    }

    func testPollingDelayIsExponentiallyBoundedAndJittered() {
        let policy = JobPollingPolicy(
            initialDelay: 1,
            maximumDelay: 5,
            multiplier: 2,
            jitterFraction: 0.2,
            timeout: 30
        )

        XCTAssertEqual(policy.delay(forAttempt: 0, randomUnit: 0), 0.8, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(forAttempt: 2, randomUnit: 0.5), 4, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(forAttempt: 20, randomUnit: 1), 6, accuracy: 0.0001)
    }

    private func makeClient(credentialStore: MemoryCredentialStore) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return APIClient(
            configuration: APIConfiguration(
                baseURL: URL(string: "https://example.test")!,
                requestTimeout: 2,
                resourceTimeout: 3
            ),
            session: URLSession(configuration: configuration),
            credentialStore: credentialStore,
            now: { Date(timeIntervalSince1970: 2_000_000_000) }
        )
    }

    private var sampleRequest: GenerateItineraryRequest {
        GenerateItineraryRequest(
            city: "Lisbon",
            country: "Portugal",
            accommodation: Accommodation(address: "Rua Augusta", lat: 38.7, lng: -9.1),
            arrivalDate: "2026-08-01",
            departureDate: "2026-08-04",
            groupSize: 2,
            wakeUpTime: "08:00",
            foodPreferences: nil,
            mustDo: nil,
            budget: "Medium"
        )
    }
}

private actor MemoryCredentialStore: CredentialStoring {
    private let installationID: String
    private var credentials: AuthCredentials?

    init(installationID: String, credentials: AuthCredentials? = nil) {
        self.installationID = installationID
        self.credentials = credentials
    }

    func loadCredentials() -> AuthCredentials? { credentials }
    func saveCredentials(_ credentials: AuthCredentials) { self.credentials = credentials }
    func clearCredentials() { credentials = nil }
    func installationIdentifier() -> String { installationID }
}

private final class URLProtocolStub: URLProtocol {
    struct StubResponse {
        let statusCode: Int
        let headers: [String: String]
        let data: Data

        static func json(statusCode: Int, body: String, headers: [String: String] = [:]) -> StubResponse {
            var headers = headers
            headers["Content-Type"] = "application/json"
            return StubResponse(statusCode: statusCode, headers: headers, data: Data(body.utf8))
        }
    }

    private static let storage = HandlerStorage()

    static func setHandler(_ handler: @escaping (URLRequest) throws -> StubResponse) {
        storage.set(handler)
    }

    static func reset() {
        storage.set(nil)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.storage.get() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let stub = try handler(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class HandlerStorage: @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> URLProtocolStub.StubResponse

    private let lock = NSLock()
    private var handler: Handler?

    func set(_ handler: Handler?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func get() -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }
}

private extension URLRequest {
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let httpBodyStream else { return nil }
        httpBodyStream.open()
        defer { httpBodyStream.close() }
        var data = Data()
        let bufferSize = 1_024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while httpBodyStream.hasBytesAvailable {
            let count = httpBodyStream.read(buffer, maxLength: bufferSize)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
