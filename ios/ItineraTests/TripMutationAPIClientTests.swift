import Foundation
import XCTest
@testable import Itinera

final class TripMutationAPIClientTests: XCTestCase {
    override func tearDown() {
        TripMutationURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testUpdateTripSendsPatchAndDecodesMutationResponse() async throws {
        let client = makeClient()
        TripMutationURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/itineraries/job-123")
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer access-token"
            )
            let body = try XCTUnwrap(request.tripMutationBodyData)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(json["title"] as? String, "Summer in Lisbon")
            XCTAssertNil(json["archived"])
            return .init(
                statusCode: 200,
                data: Data(
                    """
                    {
                      "job_id": "job-123",
                      "title": "Summer in Lisbon",
                      "archived_at": null,
                      "version": 2
                    }
                    """.utf8
                )
            )
        }

        let response = try await client.updateTrip(
            "job-123",
            title: "Summer in Lisbon"
        )
        XCTAssertEqual(response.jobId, "job-123")
        XCTAssertEqual(response.title, "Summer in Lisbon")
        XCTAssertEqual(response.version, 2)
    }

    func testArchiveSendsArchivedFlag() async throws {
        let client = makeClient()
        TripMutationURLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            let body = try XCTUnwrap(request.tripMutationBodyData)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(json["archived"] as? Bool, true)
            XCTAssertNil(json["title"])
            return .init(
                statusCode: 200,
                data: Data(
                    """
                    {
                      "job_id": "job-123",
                      "title": "Lisbon",
                      "archived_at": "2026-07-12T12:00:00Z",
                      "version": 3
                    }
                    """.utf8
                )
            )
        }

        let response = try await client.updateTrip("job-123", archived: true)
        XCTAssertNotNil(response.archivedAt)
    }

    func testDeleteTripAcceptsEmptyNoContentResponse() async throws {
        let client = makeClient()
        TripMutationURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/itineraries/job-123")
            XCTAssertEqual(request.httpMethod, "DELETE")
            return .init(statusCode: 204, data: Data())
        }

        try await client.deleteTrip("job-123")
    }

    func testArchivedLibraryUsesIncludeArchivedQueryAndDecodesFlag() async throws {
        let client = makeClient()
        TripMutationURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/itineraries")
            XCTAssertEqual(request.url?.query, "include_archived=true")
            XCTAssertEqual(request.httpMethod, "GET")
            return .init(
                statusCode: 200,
                data: Data(
                    """
                    [
                      {
                        "job_id": "job-archived",
                        "status": "succeeded",
                        "title": "Archived Lisbon",
                        "city": "Lisbon",
                        "country": "Portugal",
                        "arrival_date": "2026-08-01",
                        "departure_date": "2026-08-03",
                        "result": null,
                        "error": null,
                        "archived_at": "2026-07-12T12:00:00Z",
                        "version": 2,
                        "created_at": "2026-01-01T00:00:00Z"
                      }
                    ]
                    """.utf8
                )
            )
        }

        let trips = try await client.savedItineraries(includeArchived: true)

        XCTAssertEqual(trips.map(\.jobId), ["job-archived"])
        XCTAssertNotNil(trips.first?.archivedAt)
    }

    func testRestoreSendsArchivedFalse() async throws {
        let client = makeClient()
        TripMutationURLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            let body = try XCTUnwrap(request.tripMutationBodyData)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(json["archived"] as? Bool, false)
            return .init(
                statusCode: 200,
                data: Data(
                    """
                    {
                      "job_id": "job-123",
                      "title": "Lisbon",
                      "archived_at": null,
                      "version": 4
                    }
                    """.utf8
                )
            )
        }

        let response = try await client.updateTrip("job-123", archived: false)

        XCTAssertNil(response.archivedAt)
        XCTAssertEqual(response.version, 4)
    }

    @MainActor
    func testArchivePreservesProgressAndRestoreRepopulatesOfflineCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = CompletedTripCache(
            fileURL: root.appending(path: "completed.json")
        )
        let progressStore = TripProgressStore(
            fileURL: root.appending(path: "progress.json")
        )
        let archivedTrip = makeSavedTrip(archivedAt: nil)
        _ = try await cache.replace(with: [archivedTrip])
        let activity = try XCTUnwrap(
            archivedTrip.result?.itinerary.first?.activities.first
        )
        let stopID = TripStopID(
            tripID: archivedTrip.jobId,
            day: 1,
            activity: activity
        )
        try await progressStore.set(.completed, for: stopID)

        let appState = AppState(
            apiClient: makeClient(),
            pendingJobStore: PendingJobStore(
                fileURL: root.appending(path: "pending.json")
            ),
            pendingSubmissionStore: PendingSubmissionStore(
                fileURL: root.appending(path: "submissions.json")
            ),
            completedTripCache: cache,
            tripProgressStore: progressStore
        )
        TripMutationURLProtocolStub.handler = { request in
            let body = try XCTUnwrap(request.tripMutationBodyData)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let isArchiving = json["archived"] as? Bool == true
            return .init(
                statusCode: 200,
                data: Data(
                    """
                    {
                      "job_id": "job-123",
                      "title": "Lisbon",
                      "archived_at": \(isArchiving ? "\"2026-07-12T12:00:00Z\"" : "null"),
                      "version": \(isArchiving ? 2 : 3)
                    }
                    """.utf8
                )
            )
        }

        try await appState.archiveTrip(jobID: archivedTrip.jobId)
        let statusAfterArchive = try await progressStore.status(for: stopID)
        let cacheAfterArchive = try await cache.load()
        XCTAssertEqual(statusAfterArchive, .completed)
        XCTAssertEqual(cacheAfterArchive?.trips.map(\.jobId), ["job-123"])
        XCTAssertNotNil(cacheAfterArchive?.trips.first?.archivedAt)
        XCTAssertTrue(appState.cachedTrips.isEmpty)

        var serverArchivedTrip = archivedTrip
        serverArchivedTrip.archivedAt = "2026-07-12T12:00:00Z"
        try await appState.restoreTrip(serverArchivedTrip)
        let cacheAfterRestore = try await cache.load()
        XCTAssertEqual(cacheAfterRestore?.trips.map(\.jobId), ["job-123"])
        XCTAssertNil(cacheAfterRestore?.trips.first?.archivedAt)
        XCTAssertEqual(cacheAfterRestore?.trips.first?.version, 3)
    }

    @MainActor
    func testCompletedGenerationCachesAuthoritativeLibraryMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = CompletedTripCache(
            fileURL: root.appending(path: "completed.json")
        )
        let appState = makeAppState(root: root, cache: cache)
        var authoritative = makeSavedTrip(archivedAt: nil)
        authoritative.title = "Authoritative Lisbon"
        authoritative.city = "Lisbon"
        authoritative.country = "Portugal"
        authoritative.arrivalDate = "2026-09-10"
        authoritative.departureDate = "2026-09-13"
        authoritative.version = 7
        var authoritativeResult = Itinerary.preview
        authoritativeResult.itinerary[0].theme = "Authoritative result"
        authoritative.result = authoritativeResult

        TripMutationURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/itineraries")
            XCTAssertEqual(request.httpMethod, "GET")
            return .init(
                statusCode: 200,
                data: try Self.apiEncoder.encode([authoritative])
            )
        }

        await appState.cacheCompletedTrip(
            jobID: authoritative.jobId,
            itinerary: .preview
        )

        let snapshot = try await cache.load()
        let trip = try XCTUnwrap(snapshot?.trips.first)
        XCTAssertEqual(trip.title, "Authoritative Lisbon")
        XCTAssertEqual(trip.city, "Lisbon")
        XCTAssertEqual(trip.country, "Portugal")
        XCTAssertEqual(trip.arrivalDate, "2026-09-10")
        XCTAssertEqual(trip.departureDate, "2026-09-13")
        XCTAssertEqual(trip.version, 7)
        XCTAssertEqual(trip.result?.itinerary.first?.theme, "Authoritative result")
        XCTAssertEqual(appState.cachedTrips.first?.version, 7)
        XCTAssertEqual(appState.libraryRevision, 1)
    }

    @MainActor
    func testCompletedGenerationFallsBackToPolledResultWhenLibraryRefreshFails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = CompletedTripCache(
            fileURL: root.appending(path: "completed.json")
        )
        let appState = makeAppState(root: root, cache: cache)
        await appState.registerPending(jobID: "job-123", title: "Offline Lisbon")
        var fallbackResult = Itinerary.preview
        fallbackResult.itinerary[0].theme = "Polled fallback"

        TripMutationURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/itineraries")
            return .init(
                statusCode: 503,
                data: Data(#"{"detail":"temporarily unavailable"}"#.utf8)
            )
        }

        await appState.cacheCompletedTrip(
            jobID: "job-123",
            itinerary: fallbackResult
        )

        let snapshot = try await cache.load()
        let trip = try XCTUnwrap(snapshot?.trips.first)
        XCTAssertEqual(trip.jobId, "job-123")
        XCTAssertEqual(trip.title, "Offline Lisbon")
        XCTAssertEqual(trip.result?.itinerary.first?.theme, "Polled fallback")
        XCTAssertEqual(trip.version, 1)
        XCTAssertEqual(appState.cachedTrips.map(\.jobId), ["job-123"])
    }

    @MainActor
    func testAcceptedRevisionUpdatesOfflineSnapshotAndPublishedLibrary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = CompletedTripCache(
            fileURL: root.appending(path: "completed.json")
        )
        let original = makeSavedTrip(archivedAt: nil)
        _ = try await cache.replace(with: [original])
        let appState = makeAppState(root: root, cache: cache)
        var revisedResult = Itinerary.preview
        revisedResult.itinerary[0].theme = "Latest offline revision"
        let revision = ItineraryRevisionResponse(
            id: "revision-2",
            jobId: original.jobId,
            fromVersion: 1,
            toVersion: 2,
            operations: [],
            result: revisedResult,
            createdAt: "2026-07-12T20:00:00Z"
        )

        TripMutationURLProtocolStub.handler = { request in
            XCTAssertEqual(
                request.url?.path,
                "/api/v1/itineraries/job-123/revisions"
            )
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(request.tripMutationBodyData)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(json["expected_version"] as? Int, 1)
            return .init(
                statusCode: 200,
                data: try Self.apiEncoder.encode(revision)
            )
        }

        let response = try await appState.reviseTrip(
            jobID: original.jobId,
            expectedVersion: 1,
            operations: [
                .reorderActivity(day: 1, fromIndex: 0, toIndex: 1)
            ]
        )

        XCTAssertEqual(response.toVersion, 2)
        let snapshot = try await cache.load()
        let stored = try XCTUnwrap(snapshot?.trips.first)
        XCTAssertEqual(stored.city, "Lisbon")
        XCTAssertEqual(stored.arrivalDate, "2026-08-01")
        XCTAssertEqual(stored.version, 2)
        XCTAssertEqual(
            stored.result?.itinerary.first?.theme,
            "Latest offline revision"
        )
        XCTAssertEqual(appState.cachedTrips.first?.version, 2)
        XCTAssertEqual(
            appState.cachedTrips.first?.result?.itinerary.first?.theme,
            "Latest offline revision"
        )
        XCTAssertEqual(appState.libraryRevision, 1)
    }

    private func makeClient() -> APIClient {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [TripMutationURLProtocolStub.self]
        return APIClient(
            configuration: APIConfiguration(
                baseURL: URL(string: "https://example.test")!,
                requestTimeout: 2,
                resourceTimeout: 3
            ),
            session: URLSession(configuration: sessionConfiguration),
            credentialStore: TripMutationCredentialStore(),
            now: { Date(timeIntervalSince1970: 2_000_000_000) }
        )
    }

    @MainActor
    private func makeAppState(
        root: URL,
        cache: CompletedTripCache
    ) -> AppState {
        AppState(
            apiClient: makeClient(),
            pendingJobStore: PendingJobStore(
                fileURL: root.appending(path: "pending.json")
            ),
            pendingSubmissionStore: PendingSubmissionStore(
                fileURL: root.appending(path: "submissions.json")
            ),
            completedTripCache: cache,
            tripProgressStore: TripProgressStore(
                fileURL: root.appending(path: "progress.json")
            )
        )
    }

    private static var apiEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    private func makeSavedTrip(archivedAt: String?) -> SavedItinerary {
        SavedItinerary(
            jobId: "job-123",
            status: .succeeded,
            title: "Lisbon",
            sourcePublicItineraryId: nil,
            city: "Lisbon",
            country: "Portugal",
            arrivalDate: "2026-08-01",
            departureDate: "2026-08-03",
            result: .preview,
            error: nil,
            archivedAt: archivedAt,
            version: 1,
            createdAt: "2026-01-01T00:00:00Z"
        )
    }
}

private actor TripMutationCredentialStore: CredentialStoring {
    private var credentials = AuthCredentials(
        accessToken: "access-token",
        refreshToken: "refresh-token",
        tokenType: "Bearer",
        expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
    )

    func loadCredentials() -> AuthCredentials? { credentials }
    func saveCredentials(_ credentials: AuthCredentials) {
        self.credentials = credentials
    }
    func clearCredentials() {}
    func installationIdentifier() -> String { "installation-id" }
}

private final class TripMutationURLProtocolStub: URLProtocol {
    struct Response {
        let statusCode: Int
        let data: Data
    }

    private static let storage = TripMutationHandlerStorage()

    static var handler: ((URLRequest) throws -> Response)? {
        get { storage.get() }
        set { storage.set(newValue) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        do {
            let stub = try handler(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            if !stub.data.isEmpty {
                client?.urlProtocol(self, didLoad: stub.data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class TripMutationHandlerStorage: @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> TripMutationURLProtocolStub.Response

    private let lock = NSLock()
    private var handler: Handler?

    func get() -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }

    func set(_ handler: Handler?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }
}

private extension URLRequest {
    var tripMutationBodyData: Data? {
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
