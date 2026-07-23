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
                      "user_id": "11111111-2222-3333-4444-555555555555",
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
                XCTAssertEqual(
                    json["transportation_modes"] as? [String],
                    ["Walking", "Transit"]
                )
                XCTAssertEqual(
                    json["accessibility_categories"] as? [String],
                    ["Step-free routes", "Limited walking"]
                )
                let reservations = try XCTUnwrap(
                    json["fixed_reservations"] as? [[String: Any]]
                )
                XCTAssertEqual(reservations.first?["title"] as? String, "Museum entry")
                let unavailable = try XCTUnwrap(
                    json["unavailable_times"] as? [[String: Any]]
                )
                XCTAssertEqual(unavailable.first?["starts_at"] as? String, "13:00")
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

        var request = sampleRequest
        request.transportationModes = ["Walking", "Transit"]
        request.accessibilityCategories = ["Step-free routes", "Limited walking"]
        request.fixedReservations = [
            FixedReservationInput(
                title: "Museum entry",
                startsAt: "2026-08-02T10:00:00+01:00",
                endsAt: "2026-08-02T11:00:00+01:00"
            )
        ]
        request.unavailableTimes = [
            UnavailableTimeInput(
                date: "2026-08-03",
                startsAt: "13:00",
                endsAt: "15:00"
            )
        ]
        let accepted = try await client.createItinerary(request, idempotencyKey: idempotencyKey)
        XCTAssertEqual(accepted.jobId, "job-123")
        let stored = await credentialStore.loadCredentials()
        XCTAssertEqual(stored?.refreshToken, "refresh-1")
        XCTAssertEqual(stored?.userID, "11111111-2222-3333-4444-555555555555")
    }

    func testSessionResponseWithoutPrincipalIdentifierIsRejected() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        let client = makeClient(credentialStore: credentialStore)
        URLProtocolStub.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/v1/auth/guest")
            return .json(
                statusCode: 200,
                body: #"{"access_token":"access-1","refresh_token":"refresh-1","token_type":"bearer","expires_in":3600}"#
            )
        }

        do {
            _ = try await client.savedItineraries()
            XCTFail("Expected an incomplete session response to be rejected")
        } catch let error as APIError {
            XCTAssertEqual(error, .decoding)
        }
        let storedCredentials = await credentialStore.loadCredentials()
        XCTAssertNil(storedCredentials)
    }

    func testEnsurePrincipalIDRefreshesLegacyCredentialWithoutCreatingGuest() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            credentials: AuthCredentials(
                accessToken: "legacy-access",
                refreshToken: "legacy-refresh",
                tokenType: "Bearer",
                expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
            )
        )
        let client = makeClient(credentialStore: credentialStore)
        URLProtocolStub.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/v1/auth/refresh")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: String]
            )
            XCTAssertEqual(payload["refresh_token"], "legacy-refresh")
            return .json(
                statusCode: 200,
                body: #"{"user_id":"11111111-2222-3333-4444-555555555555","access_token":"refreshed-access","refresh_token":"refreshed-refresh","token_type":"Bearer","expires_in":3600}"#
            )
        }

        let userID = try await client.ensurePrincipalID()

        XCTAssertEqual(userID, "11111111-2222-3333-4444-555555555555")
        let refreshed = await credentialStore.loadCredentials()
        XCTAssertEqual(refreshed?.accessToken, "refreshed-access")
        XCTAssertEqual(refreshed?.userID, userID)
    }

    func testAIConsentRequestsAreAuthenticatedAndVersioned() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            credentials: validCredentials
        )
        let client = makeClient(credentialStore: credentialStore)

        URLProtocolStub.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/v1/auth/ai-consent")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
            switch request.httpMethod {
            case "POST":
                let body = try XCTUnwrap(request.bodyData)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Int])
                XCTAssertEqual(json["version"], SettingsConsentVersion.current)
                return .json(statusCode: 200, body: #"{"action":"granted","version":2,"recorded_at":"2026-07-16T00:00:00Z"}"#)
            case "DELETE":
                XCTAssertNil(request.bodyData)
                return .json(statusCode: 200, body: #"{"action":"withdrawn","version":2,"recorded_at":"2026-07-16T00:00:00Z"}"#)
            default:
                XCTFail("Unexpected method: \(request.httpMethod ?? "nil")")
                return .json(statusCode: 405, body: "{}")
            }
        }

        try await client.grantAIConsent(version: SettingsConsentVersion.current)
        try await client.withdrawAIConsent()
    }

    func testAccountDeletionRetainsRetryStateUntilLocalCleanupFinishes() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            credentials: validCredentials
        )
        let client = makeClient(credentialStore: credentialStore)
        let installationIDBeforeDeletion = await credentialStore.installationIdentifier()

        URLProtocolStub.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/v1/auth/me")
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer access-1"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Installation-Id"),
                installationIDBeforeDeletion
            )
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: String]
            )
            XCTAssertEqual(payload["confirmation"], "DELETE")
            return .json(statusCode: 204, body: "")
        }

        try await client.deleteMyData()

        let remainingCredentials = await credentialStore.loadCredentials()
        let installationIDAfterDeletion = await credentialStore.installationIdentifier()
        XCTAssertEqual(remainingCredentials, validCredentials)
        XCTAssertEqual(installationIDAfterDeletion, installationIDBeforeDeletion)

        try await client.finalizeDeletedAccountOnDevice()

        let finalCredentials = await credentialStore.loadCredentials()
        let finalInstallationID = await credentialStore.installationIdentifier()
        XCTAssertNil(finalCredentials)
        XCTAssertNotEqual(finalInstallationID, installationIDBeforeDeletion)
    }

    func testAccountDeletionRetainsAccountStateWhenServerRejects() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            credentials: validCredentials
        )
        let client = makeClient(credentialStore: credentialStore)
        let installationIDBeforeDeletion = await credentialStore.installationIdentifier()

        URLProtocolStub.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/v1/auth/me")
            return .json(
                statusCode: 503,
                body: #"{"detail":"Deletion is temporarily unavailable."}"#
            )
        }

        do {
            try await client.deleteMyData()
            XCTFail("Expected deletion to fail")
        } catch let error as APIError {
            XCTAssertEqual(error.retryAfter, nil)
        }

        let remainingCredentials = await credentialStore.loadCredentials()
        let installationIDAfterFailure = await credentialStore.installationIdentifier()
        XCTAssertEqual(remainingCredentials, validCredentials)
        XCTAssertEqual(installationIDAfterFailure, installationIDBeforeDeletion)
    }

    func testAccountDeletionRefreshesExpiredSessionWithoutCreatingGuest() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            credentials: AuthCredentials(
                accessToken: "expired-access",
                refreshToken: "refresh-1",
                tokenType: "Bearer",
                expiresAt: Date(timeIntervalSince1970: 1)
            )
        )
        let client = makeClient(credentialStore: credentialStore)

        URLProtocolStub.setHandler { request in
            switch request.url?.path {
            case "/api/v1/auth/me":
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer expired-access" {
                    return .json(statusCode: 401, body: #"{"detail":"expired"}"#)
                }
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer refreshed-access"
                )
                return .json(statusCode: 204, body: "")
            case "/api/v1/auth/refresh":
                let body = try XCTUnwrap(request.bodyData)
                let payload = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: String]
                )
                XCTAssertEqual(payload["refresh_token"], "refresh-1")
                return .json(
                    statusCode: 200,
                    body: #"{"user_id":"11111111-2222-3333-4444-555555555555","access_token":"refreshed-access","refresh_token":"refresh-2","token_type":"Bearer","expires_in":3600}"#
                )
            case "/api/v1/auth/guest":
                XCTFail("Deletion must not create a guest account")
                return .json(statusCode: 500, body: "{}")
            default:
                XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
                return .json(statusCode: 404, body: "{}")
            }
        }

        try await client.deleteMyData()

        let refreshedCredentials = await credentialStore.loadCredentials()
        XCTAssertEqual(refreshedCredentials?.accessToken, "refreshed-access")
        XCTAssertEqual(refreshedCredentials?.refreshToken, "refresh-2")
    }

    func testHTTPErrorPresentsOnlyAValidatedServerSupportReference() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            credentials: validCredentials
        )
        let client = makeClient(credentialStore: credentialStore)
        let requestID = "0123456789abcdef0123456789abcdef"

        URLProtocolStub.setHandler { _ in
            .json(
                statusCode: 503,
                body: #"{"detail":"Generation is temporarily unavailable."}"#,
                headers: ["X-Request-ID": requestID]
            )
        }

        do {
            _ = try await client.savedItineraries()
            XCTFail("Expected HTTP error")
        } catch let error as APIError {
            XCTAssertEqual(
                error.errorDescription,
                "Generation is temporarily unavailable. Reference ID: \(requestID)."
            )
        }
    }

    func testHTTPErrorDiscardsMalformedSupportReference() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            credentials: validCredentials
        )
        let client = makeClient(credentialStore: credentialStore)

        URLProtocolStub.setHandler { _ in
            .json(
                statusCode: 503,
                body: #"{"detail":"Generation is temporarily unavailable."}"#,
                headers: ["X-Request-ID": "<untrusted-value>"]
            )
        }

        do {
            _ = try await client.savedItineraries()
            XCTFail("Expected HTTP error")
        } catch let error as APIError {
            XCTAssertEqual(error.errorDescription, "Generation is temporarily unavailable.")
        }
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
                      "user_id": "11111111-2222-3333-4444-555555555555",
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
        let stored = await credentialStore.loadCredentials()
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
                      "user_id": "11111111-2222-3333-4444-555555555555",
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

    func testConcurrentDeletionAndLibraryRefreshShareOneRotatingRefresh() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            credentials: AuthCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-1",
                tokenType: "bearer",
                expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
            )
        )
        let client = makeClient(credentialStore: credentialStore)
        let lock = NSLock()
        var refreshRequests = 0

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
                      "user_id": "11111111-2222-3333-4444-555555555555",
                      "access_token": "new-access",
                      "refresh_token": "refresh-2",
                      "token_type": "bearer",
                      "expires_in": 3600
                    }
                    """
                )
            case "/api/v1/auth/me":
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer old-access" {
                    return .json(statusCode: 401, body: #"{"detail":"expired"}"#)
                }
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer new-access"
                )
                return .json(statusCode: 204, body: "")
            case "/api/v1/itineraries":
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer old-access" {
                    return .json(statusCode: 401, body: #"{"detail":"expired"}"#)
                }
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer new-access"
                )
                return .json(statusCode: 200, body: "[]")
            case "/api/v1/auth/guest":
                XCTFail("Deletion retry must not create a guest account")
                return .json(statusCode: 500, body: "{}")
            default:
                XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
                return .json(statusCode: 404, body: "{}")
            }
        }

        async let deletion: Void = client.deleteMyData()
        async let library = client.savedItineraries()
        try await deletion
        let trips = try await library
        XCTAssertTrue(trips.isEmpty)
        XCTAssertEqual(refreshRequests, 1)
        let stored = await credentialStore.loadCredentials()
        XCTAssertEqual(stored?.refreshToken, "refresh-2")
    }

    func testRejectedRefreshPreservesExistingIdentityForRecovery() async throws {
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
        let recorder = RequestPathRecorder()

        URLProtocolStub.setHandler { request in
            recorder.record(request.url?.path ?? "")
            switch request.url?.path {
            case "/api/v1/auth/refresh":
                return .json(statusCode: 401, body: #"{"detail":"revoked"}"#)
            default:
                XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
                return .json(statusCode: 404, body: "{}")
            }
        }

        for _ in 0..<2 {
            do {
                _ = try await client.savedItineraries()
                XCTFail("Expected recovery error")
            } catch let error as APIError {
                XCTAssertEqual(
                    error.errorDescription,
                    "Your session needs recovery. Your saved trips remain on this device."
                )
            }
        }
        let stored = await credentialStore.loadCredentials()
        XCTAssertEqual(stored?.refreshToken, "revoked-refresh")
        XCTAssertEqual(recorder.paths, ["/api/v1/auth/refresh", "/api/v1/auth/refresh"])
    }

    func testRefreshRejectsAnUnexpectedPrincipalChange() async throws {
        let originalCredentials = AuthCredentials(
            accessToken: "expired-access",
            refreshToken: "refresh-1",
            tokenType: "bearer",
            expiresAt: Date(timeIntervalSince1970: 1_000),
            userID: "11111111-2222-3333-4444-555555555555"
        )
        let credentialStore = MemoryCredentialStore(
            installationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            credentials: originalCredentials
        )
        let client = makeClient(credentialStore: credentialStore)

        URLProtocolStub.setHandler { request in
            switch request.url?.path {
            case "/api/v1/auth/refresh":
                return .json(
                    statusCode: 200,
                    body: """
                    {
                      "user_id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                      "access_token": "new-access",
                      "refresh_token": "refresh-2",
                      "token_type": "bearer",
                      "expires_in": 3600
                    }
                    """
                )
            default:
                XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
                return .json(statusCode: 404, body: "{}")
            }
        }

        do {
            _ = try await client.savedItineraries()
            XCTFail("Expected the principal mismatch to be rejected")
        } catch let error as APIError {
            XCTAssertEqual(
                error.errorDescription,
                "Your account identity changed during session refresh. Please recover your library."
            )
        }
        let storedCredentials = await credentialStore.loadCredentials()
        XCTAssertEqual(storedCredentials, originalCredentials)
    }

    func testPopularItineraryEndpointsDecodeSnakeCaseResponses() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            credentials: validCredentials
        )
        let client = makeClient(credentialStore: credentialStore)

        URLProtocolStub.setHandler { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
            switch request.url?.path {
            case "/api/v1/popular-itineraries":
                return .json(
                    statusCode: 200,
                    body: """
                    [
                      {
                        "id": "11111111-2222-3333-4444-555555555555",
                        "title": "Lisbon in Three Days",
                        "summary": "A walkable city route.",
                        "city": "Lisbon",
                        "country": "Portugal",
                        "location_key": "lisbon/portugal",
                        "duration_days": 3,
                        "save_count": 42,
                        "is_saved": false
                      }
                    ]
                    """
                )
            case "/api/v1/popular-itineraries/11111111-2222-3333-4444-555555555555":
                return .json(statusCode: 200, body: self.popularDetailJSON)
            default:
                XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
                return .json(statusCode: 404, body: "{}")
            }
        }

        let summaries = try await client.popularItineraries()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].locationName, "Lisbon, Portugal")
        XCTAssertEqual(summaries[0].durationDays, 3)
        XCTAssertEqual(summaries[0].saveCount, 42)

        let detail = try await client.popularItinerary(summaries[0].id)
        XCTAssertEqual(detail.title, "Lisbon in Three Days")
        XCTAssertEqual(detail.result.itinerary.first?.activities.first?.name, "Praça do Comércio")
    }

    func testSavePopularItineraryUsesPutAndDecodesLibraryCopy() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            credentials: validCredentials
        )
        let client = makeClient(credentialStore: credentialStore)

        URLProtocolStub.setHandler { request in
            XCTAssertEqual(
                request.url?.path,
                "/api/v1/popular-itineraries/11111111-2222-3333-4444-555555555555/saved"
            )
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertNil(request.bodyData)
            return .json(
                statusCode: 200,
                body: """
                {
                  "created": true,
                  "saved_itinerary": {
                    "job_id": "saved-popular-1",
                    "status": "succeeded",
                    "title": "Lisbon in Three Days",
                    "source_public_itinerary_id": "11111111-2222-3333-4444-555555555555",
                    "city": "Lisbon",
                    "country": "Portugal",
                    "arrival_date": null,
                    "departure_date": null,
                    "result": null,
                    "error": null,
                    "archived_at": null,
                    "version": 1,
                    "created_at": "2026-07-12T12:00:00Z"
                  }
                }
                """
            )
        }

        let response = try await client.savePopularItinerary(
            "11111111-2222-3333-4444-555555555555"
        )
        XCTAssertTrue(response.created)
        XCTAssertEqual(response.savedItinerary.displayTitle, "Lisbon in Three Days")
        XCTAssertEqual(
            response.savedItinerary.sourcePublicItineraryId,
            "11111111-2222-3333-4444-555555555555"
        )
    }

    func testLegacyTripResponsesDefaultMissingVersionToOne() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let saved = try decoder.decode(
            SavedItinerary.self,
            from: Data(
                """
                {
                  "job_id": "legacy-trip",
                  "status": "succeeded",
                  "title": "Legacy Lisbon",
                  "created_at": "2026-01-01T00:00:00Z"
                }
                """.utf8
            )
        )
        let status = try decoder.decode(
            JobStatusResponse.self,
            from: Data(
                """
                {
                  "job_id": "legacy-trip",
                  "status": "running",
                  "result": null,
                  "error": null
                }
                """.utf8
            )
        )

        XCTAssertEqual(saved.version, 1)
        XCTAssertNil(saved.archivedAt)
        XCTAssertEqual(status.version, 1)
        XCTAssertNil(status.errorCode)
    }

    func testGenerationFailureCodeDecodesFromTheServerContract() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let status = try decoder.decode(
            JobStatusResponse.self,
            from: Data(
                """
                {
                  "job_id": "failed-trip",
                  "status": "failed",
                  "error": "Itinera's planning service is temporarily unavailable. Please try again in a few minutes.",
                  "error_code": "generation_unavailable"
                }
                """.utf8
            )
        )

        XCTAssertEqual(status.errorCode, "generation_unavailable")
    }

    func testSSEDecoderEmitsOnlyCompletedFrames() throws {
        var decoder = ItinerarySSEEventDecoder()

        XCTAssertNil(try decoder.consume(line: ": keepalive"))
        XCTAssertNil(try decoder.consume(line: "event: status"))
        XCTAssertNil(try decoder.consume(line: "data: {\"job_id\":\"job-123\",\"status\":\"running\"}"))
        let running = try decoder.consume(line: "")
        XCTAssertEqual(running?.jobId, "job-123")
        XCTAssertEqual(running?.status, .running)

        XCTAssertNil(try decoder.consume(line: "event: ignored"))
        XCTAssertNil(try decoder.consume(line: "data: {\"ignored\":true}"))
        XCTAssertNil(try decoder.consume(line: ""))
    }

    func testAwaitItineraryConsumesAuthenticatedTerminalStream() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            credentials: validCredentials
        )
        let client = makeClient(credentialStore: credentialStore)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let terminal = JobStatusResponse(
            jobId: "job-123",
            status: .succeeded,
            result: .preview,
            error: nil
        )

        URLProtocolStub.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/v1/itineraries/job-123/stream")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
            return .eventStream(
                statusCode: 200,
                body: "event: result\ndata: \(String(decoding: try encoder.encode(terminal), as: UTF8.self))\n\n"
            )
        }

        let itinerary = try await client.awaitItinerary(
            "job-123",
            policy: JobPollingPolicy(timeout: 2),
            streamingPolicy: JobStreamingPolicy(maximumConnections: 1)
        )

        XCTAssertEqual(itinerary, .preview)
    }

    func testAwaitItineraryFallsBackToPollingWhenStreamClosesNonterminal() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            credentials: validCredentials
        )
        let client = makeClient(credentialStore: credentialStore)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let terminal = JobStatusResponse(
            jobId: "job-123",
            status: .succeeded,
            result: .preview,
            error: nil
        )

        URLProtocolStub.setHandler { request in
            switch request.url?.path {
            case "/api/v1/itineraries/job-123/stream":
                return .eventStream(
                    statusCode: 200,
                    body: "event: status\ndata: {\"job_id\":\"job-123\",\"status\":\"running\"}\n\n"
                )
            case "/api/v1/itineraries/job-123":
                return .json(
                    statusCode: 200,
                    body: String(
                        decoding: try encoder.encode(terminal),
                        as: UTF8.self
                    )
                )
            default:
                XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
                return .json(statusCode: 404, body: "{}")
            }
        }

        let itinerary = try await client.awaitItinerary(
            "job-123",
            policy: JobPollingPolicy(timeout: 2),
            streamingPolicy: JobStreamingPolicy(maximumConnections: 1)
        )

        XCTAssertEqual(itinerary, .preview)
    }

    func testAwaitItineraryBoundsStreamReconnectsBeforePolling() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            credentials: validCredentials
        )
        let client = makeClient(credentialStore: credentialStore)
        let recorder = RequestPathRecorder()
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let terminal = JobStatusResponse(
            jobId: "job-123",
            status: .succeeded,
            result: .preview,
            error: nil
        )

        URLProtocolStub.setHandler { request in
            let path = request.url?.path ?? ""
            recorder.record(path)
            if path == "/api/v1/itineraries/job-123/stream" {
                return .eventStream(
                    statusCode: 200,
                    body: "event: status\ndata: {\"job_id\":\"job-123\",\"status\":\"running\"}\n\n"
                )
            }
            if path == "/api/v1/itineraries/job-123" {
                return .json(
                    statusCode: 200,
                    body: String(
                        decoding: try encoder.encode(terminal),
                        as: UTF8.self
                    )
                )
            }
            XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
            return .json(statusCode: 404, body: "{}")
        }

        let itinerary = try await client.awaitItinerary(
            "job-123",
            policy: JobPollingPolicy(timeout: 2)
        )

        XCTAssertEqual(itinerary, .preview)
        XCTAssertEqual(
            recorder.paths.filter { $0.hasSuffix("/stream") }.count,
            JobStreamingPolicy().maximumConnections
        )
        XCTAssertEqual(
            recorder.paths.filter { $0 == "/api/v1/itineraries/job-123" }.count,
            1
        )
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
        XCTAssertEqual(JobPollingPolicy().timeout, 10 * 60)
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

    private var validCredentials: AuthCredentials {
        AuthCredentials(
            accessToken: "access-1",
            refreshToken: "refresh-1",
            tokenType: "Bearer",
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
        )
    }

    private var popularDetailJSON: String {
        """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "title": "Lisbon in Three Days",
          "summary": "A walkable city route.",
          "city": "Lisbon",
          "country": "Portugal",
          "location_key": "lisbon/portugal",
          "duration_days": 3,
          "save_count": 42,
          "is_saved": false,
          "result": {
            "itinerary": [
              {
                "day": 1,
                "theme": "Historic Lisbon",
                "activities": [
                  {
                    "time": "09:00",
                    "name": "Praça do Comércio",
                    "type": "culture",
                    "duration": "1 hour",
                    "description": "Explore the riverside square.",
                    "address": "Praça do Comércio, Lisbon",
                    "coordinates": {"lat": 38.7078, "lng": -9.1366}
                  }
                ]
              }
            ],
            "tips": ["Wear comfortable shoes."],
            "accommodation_info": {
              "morning_start": "09:00",
              "evening_return": "18:00",
              "transportation_tips": "Walk and use the metro."
            },
            "estimated_budget": "$150 per person"
          }
        }
        """
    }
}

private actor MemoryCredentialStore: CredentialStoring {
    private var installationID: String
    private var credentials: AuthCredentials?

    init(installationID: String, credentials: AuthCredentials? = nil) {
        self.installationID = installationID
        self.credentials = credentials
    }

    func loadCredentials() -> AuthCredentials? { credentials }
    func saveCredentials(_ credentials: AuthCredentials) { self.credentials = credentials }
    func clearCredentials() { credentials = nil }
    func clearAccountState() {
        credentials = nil
        installationID = UUID().uuidString.lowercased()
    }
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

        static func eventStream(statusCode: Int, body: String) -> StubResponse {
            StubResponse(
                statusCode: statusCode,
                headers: ["Content-Type": "text/event-stream"],
                data: Data(body.utf8)
            )
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

private final class RequestPathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPaths: [String] = []

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPaths
    }

    func record(_ path: String) {
        lock.lock()
        recordedPaths.append(path)
        lock.unlock()
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
