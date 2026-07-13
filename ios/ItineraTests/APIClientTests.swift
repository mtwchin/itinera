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
        let harness = makeClient(
            credentialStore: credentialStore,
            establishedUserID: nil
        )
        let client = harness.client

        URLProtocolStub.setHandler { request in
            switch request.url?.path {
            case "/api/v1/auth/guest":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertNil(
                    request.value(forHTTPHeaderField: "X-Installation-Id")
                )
                return .json(
                    statusCode: 200,
                    body: """
                    {
                      "user_id": "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB",
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

        let transitionEpoch = try await harness.coordinator.beginTransition()
        let principal = try await client.createGuestCredentials(at: transitionEpoch)
        let lease = try await harness.coordinator.establish(
            principal.identity.scope,
            presentationSessionID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            at: transitionEpoch
        )
        let privateAPI = client.bound(to: lease)

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
        let accepted = try await privateAPI.createItinerary(
            request,
            idempotencyKey: idempotencyKey
        )
        XCTAssertEqual(accepted.jobId, "job-123")
        let stored = await credentialStore.loadCredentials()
        XCTAssertEqual(stored?.refreshToken, "refresh-1")
        XCTAssertEqual(stored?.userID, testUserIDA)
    }

    func testGuestResponseWithoutUserIDIsRejectedAndNotSaved() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "installation-id"
        )
        let harness = makeClient(
            credentialStore: credentialStore,
            establishedUserID: nil
        )
        URLProtocolStub.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/v1/auth/guest")
            return .json(
                statusCode: 201,
                body: """
                {
                  "access_token": "access-without-owner",
                  "refresh_token": "refresh-without-owner",
                  "token_type": "bearer",
                  "expires_in": 3600
                }
                """
            )
        }

        let epoch = try await harness.coordinator.beginTransition()
        do {
            _ = try await harness.client.createGuestCredentials(at: epoch)
            XCTFail("Authentication responses must include the server user_id")
        } catch let error as APIError {
            XCTAssertEqual(error, .decoding)
        }
        let stored = await credentialStore.loadCredentials()
        XCTAssertNil(stored)
    }

    func testUnauthorizedResponseRefreshesOnceAndRetriesWithNewBearerToken() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            credentials: AuthCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-1",
                tokenType: "Bearer",
                expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
                userID: testUserIDA
            )
        )
        let client = makeClient(credentialStore: credentialStore).establishedAPI!
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
                      "user_id": "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb",
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

    func testTerminalRead401AfterVerifiedRefreshLatchesExactRecovery() async throws {
        let original = AuthCredentials(
            accessToken: "old-access",
            refreshToken: "refresh-1",
            tokenType: "Bearer",
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
            userID: testUserIDA
        )
        let credentialStore = MemoryCredentialStore(
            installationID: "installation-id",
            credentials: original
        )
        let client = makeClient(
            credentialStore: credentialStore
        ).establishedAPI!
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
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    requestNumber == 1
                        ? "Bearer old-access"
                        : "Bearer refreshed-access"
                )
                return .json(statusCode: 401, body: #"{"detail":"rejected"}"#)
            case "/api/v1/auth/refresh":
                lock.lock()
                refreshRequests += 1
                lock.unlock()
                return .json(
                    statusCode: 200,
                    body: """
                    {
                      "user_id": "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb",
                      "access_token": "refreshed-access",
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

        for _ in 0..<2 {
            do {
                _ = try await client.savedItineraries()
                XCTFail("A terminal authenticated 401 must require recovery")
            } catch let error as APIError {
                XCTAssertEqual(error, .identityRecoveryRequired)
            }
        }

        XCTAssertEqual(itineraryRequests, 2)
        XCTAssertEqual(refreshRequests, 1)
        let stored = await credentialStore.loadCredentials()
        XCTAssertEqual(stored?.accessToken, "refreshed-access")
        XCTAssertEqual(stored?.userID, testUserIDA)
    }

    func testTerminalMutation401AfterVerifiedRefreshLatchesExactRecovery() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "installation-id",
            credentials: AuthCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-1",
                tokenType: "Bearer",
                expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
                userID: testUserIDA
            )
        )
        let client = makeClient(
            credentialStore: credentialStore
        ).establishedAPI!
        let lock = NSLock()
        var deleteRequests = 0
        var refreshRequests = 0

        URLProtocolStub.setHandler { request in
            switch request.url?.path {
            case "/api/v1/itineraries/trip-1":
                lock.lock()
                deleteRequests += 1
                lock.unlock()
                XCTAssertEqual(request.httpMethod, "DELETE")
                return .json(statusCode: 401, body: #"{"detail":"rejected"}"#)
            case "/api/v1/auth/refresh":
                lock.lock()
                refreshRequests += 1
                lock.unlock()
                return .json(
                    statusCode: 200,
                    body: """
                    {
                      "user_id": "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb",
                      "access_token": "refreshed-access",
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

        for _ in 0..<2 {
            do {
                try await client.deleteTrip("trip-1")
                XCTFail("A terminal mutation 401 must require recovery")
            } catch let error as APIError {
                XCTAssertEqual(error, .identityRecoveryRequired)
            }
        }

        XCTAssertEqual(deleteRequests, 2)
        XCTAssertEqual(refreshRequests, 1)
    }

    func testConcurrentExpiredRequestsShareOneRotatingRefresh() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            credentials: AuthCredentials(
                accessToken: "expired-access",
                refreshToken: "refresh-1",
                tokenType: "bearer",
                expiresAt: Date(timeIntervalSince1970: 1_000),
                userID: testUserIDA
            )
        )
        let client = makeClient(credentialStore: credentialStore).establishedAPI!
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
                      "user_id": "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb",
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

    func testKnownPrincipalRestoreIsOfflineEvenWhenAccessTokenExpired() async throws {
        let original = AuthCredentials(
            accessToken: "expired-access",
            refreshToken: "refresh-1",
            tokenType: "bearer",
            expiresAt: Date(timeIntervalSince1970: 1_000),
            userID: testUserIDA.uppercased()
        )
        let credentialStore = MemoryCredentialStore(
            installationID: "installation-id",
            credentials: original
        )
        let harness = makeClient(
            credentialStore: credentialStore,
            establishedUserID: nil
        )
        let lock = NSLock()
        var networkRequests = 0
        URLProtocolStub.setHandler { _ in
            lock.lock()
            networkRequests += 1
            lock.unlock()
            throw URLError(.notConnectedToInternet)
        }

        let epoch = try await harness.coordinator.beginTransition()
        let restoredValue = try await harness.client.restoreCredentials(at: epoch)
        let restored = try XCTUnwrap(restoredValue)

        XCTAssertEqual(restored.identity.serverUserID, testUserIDA)
        XCTAssertEqual(restored.credentials.userID, testUserIDA)
        XCTAssertEqual(networkRequests, 0)
        let canonicalStored = await credentialStore.loadCredentials()
        XCTAssertEqual(canonicalStored?.userID, testUserIDA)
    }

    func testLegacyCredentialUpgradeObtainsUserIDFromRefresh() async throws {
        let legacy = AuthCredentials(
            accessToken: "legacy-access",
            refreshToken: "legacy-refresh",
            tokenType: "bearer",
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
        )
        let credentialStore = MemoryCredentialStore(
            installationID: "installation-id",
            credentials: legacy
        )
        let harness = makeClient(
            credentialStore: credentialStore,
            establishedUserID: nil
        )
        URLProtocolStub.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/v1/auth/refresh")
            return .json(
                statusCode: 200,
                body: """
                {
                  "user_id": "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb",
                  "access_token": "upgraded-access",
                  "refresh_token": "upgraded-refresh",
                  "token_type": "bearer",
                  "expires_in": 3600
                }
                """
            )
        }

        let epoch = try await harness.coordinator.beginTransition()
        let restoredValue = try await harness.client.restoreCredentials(at: epoch)
        let restored = try XCTUnwrap(restoredValue)

        XCTAssertEqual(restored.identity.serverUserID, testUserIDA)
        XCTAssertEqual(restored.credentials.accessToken, "upgraded-access")
        let upgradedStored = await credentialStore.loadCredentials()
        XCTAssertEqual(upgradedStored?.userID, testUserIDA)
    }

    func testLegacyCredentialUpgradeOfflineFailsClosed() async throws {
        let legacy = AuthCredentials(
            accessToken: "legacy-access",
            refreshToken: "legacy-refresh",
            tokenType: "bearer",
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
        )
        let credentialStore = MemoryCredentialStore(
            installationID: "installation-id",
            credentials: legacy
        )
        let harness = makeClient(
            credentialStore: credentialStore,
            establishedUserID: nil
        )
        URLProtocolStub.setHandler { _ in
            throw URLError(.notConnectedToInternet)
        }

        let epoch = try await harness.coordinator.beginTransition()
        do {
            _ = try await harness.client.restoreCredentials(at: epoch)
            XCTFail("Legacy credentials cannot establish an offline principal")
        } catch let error as APIError {
            guard case .transport(let code, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(code, .notConnectedToInternet)
        }
        let unchangedLegacy = await credentialStore.loadCredentials()
        XCTAssertEqual(unchangedLegacy, legacy)
    }

    func testRefreshWithDifferentUserIDDoesNotSaveOrRetry() async throws {
        let original = AuthCredentials(
            accessToken: "expired-access",
            refreshToken: "refresh-a",
            tokenType: "bearer",
            expiresAt: Date(timeIntervalSince1970: 1_000),
            userID: testUserIDA
        )
        let credentialStore = MemoryCredentialStore(
            installationID: "installation-id",
            credentials: original
        )
        let client = makeClient(credentialStore: credentialStore).establishedAPI!
        let lock = NSLock()
        var itineraryRequests = 0
        URLProtocolStub.setHandler { request in
            switch request.url?.path {
            case "/api/v1/auth/refresh":
                return .json(
                    statusCode: 200,
                    body: """
                    {
                      "user_id": "bbbbbbbb-1111-2222-3333-cccccccccccc",
                      "access_token": "access-b",
                      "refresh_token": "refresh-b",
                      "token_type": "bearer",
                      "expires_in": 3600
                    }
                    """
                )
            case "/api/v1/itineraries":
                lock.lock()
                itineraryRequests += 1
                lock.unlock()
                return .json(statusCode: 200, body: "[]")
            default:
                return .json(statusCode: 404, body: "{}")
            }
        }

        do {
            _ = try await client.savedItineraries()
            XCTFail("A mismatched refresh must fail closed")
        } catch let error as APIError {
            XCTAssertEqual(error, .identityIntegrityFailure)
        }
        let unchanged = await credentialStore.loadCredentials()
        XCTAssertEqual(unchanged, original)
        XCTAssertEqual(itineraryRequests, 0)
    }

    func testRejectedRefreshRequiresRecoveryWithoutClearingOrCreatingGuest() async throws {
        let original = AuthCredentials(
            accessToken: "expired-access",
            refreshToken: "revoked-refresh",
            tokenType: "bearer",
            expiresAt: Date(timeIntervalSince1970: 1_000),
            userID: testUserIDA
        )
        let credentialStore = MemoryCredentialStore(
            installationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            credentials: original
        )
        let client = makeClient(credentialStore: credentialStore).establishedAPI!
        let lock = NSLock()
        var refreshRequests = 0
        var guestRequests = 0
        var itineraryRequests = 0

        URLProtocolStub.setHandler { request in
            switch request.url?.path {
            case "/api/v1/auth/refresh":
                lock.lock()
                refreshRequests += 1
                lock.unlock()
                return .json(statusCode: 401, body: #"{"detail":"revoked"}"#)
            case "/api/v1/auth/guest":
                lock.lock()
                guestRequests += 1
                lock.unlock()
                return .json(statusCode: 500, body: "{}")
            case "/api/v1/itineraries":
                lock.lock()
                itineraryRequests += 1
                lock.unlock()
                return .json(statusCode: 200, body: "[]")
            default:
                XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
                return .json(statusCode: 404, body: "{}")
            }
        }

        for _ in 0..<2 {
            do {
                _ = try await client.savedItineraries()
                XCTFail("Rejected refresh must require coordinator recovery")
            } catch let error as APIError {
                XCTAssertEqual(error, .identityRecoveryRequired)
            }
        }
        let stored = await credentialStore.loadCredentials()
        XCTAssertEqual(stored, original)
        XCTAssertEqual(refreshRequests, 1)
        XCTAssertEqual(guestRequests, 0)
        XCTAssertEqual(itineraryRequests, 0)
    }

    func testExplicitExactLeaseRecoveryAllowsAtMostOneNewRefreshAttempt() async throws {
        let original = AuthCredentials(
            accessToken: "expired-access",
            refreshToken: "revoked-refresh",
            tokenType: "bearer",
            expiresAt: Date(timeIntervalSince1970: 1_000),
            userID: testUserIDA
        )
        let credentialStore = MemoryCredentialStore(
            installationID: "installation-id",
            credentials: original
        )
        let harness = makeClient(credentialStore: credentialStore)
        let client = harness.establishedAPI!
        let lock = NSLock()
        var refreshRequests = 0
        var privateRequests = 0

        URLProtocolStub.setHandler { request in
            switch request.url?.path {
            case "/api/v1/auth/refresh":
                lock.lock()
                refreshRequests += 1
                let requestNumber = refreshRequests
                lock.unlock()
                if requestNumber == 1 {
                    return .json(
                        statusCode: 401,
                        body: #"{"detail":"revoked"}"#
                    )
                }
                return .json(
                    statusCode: 200,
                    body: """
                    {
                      "user_id": "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb",
                      "access_token": "recovered-access",
                      "refresh_token": "recovered-refresh",
                      "token_type": "bearer",
                      "expires_in": 3600
                    }
                    """
                )
            case "/api/v1/itineraries":
                lock.lock()
                privateRequests += 1
                lock.unlock()
                return .json(statusCode: 200, body: "[]")
            default:
                XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
                return .json(statusCode: 404, body: "{}")
            }
        }

        do {
            _ = try await client.savedItineraries()
            XCTFail("The first rejected refresh must latch recovery")
        } catch let error as APIError {
            XCTAssertEqual(error, .identityRecoveryRequired)
        }
        do {
            _ = try await client.savedItineraries()
            XCTFail("Automatic requests must remain latched")
        } catch let error as APIError {
            XCTAssertEqual(error, .identityRecoveryRequired)
        }
        XCTAssertEqual(refreshRequests, 1)

        let wrongLease = IdentityLease(
            scope: client.lease.scope,
            epoch: client.lease.epoch,
            presentationSessionID: UUID(
                uuidString: "99999999-9999-9999-9999-999999999999"
            )!
        )
        do {
            try await harness.client.retrySessionRecovery(lease: wrongLease)
            XCTFail("A non-current presentation lease cannot clear recovery")
        } catch let error as IdentityCoordinatorError {
            XCTAssertEqual(error, .staleIdentity)
        }
        do {
            _ = try await client.savedItineraries()
            XCTFail("A wrong lease must leave the exact lease latched")
        } catch let error as APIError {
            XCTAssertEqual(error, .identityRecoveryRequired)
        }
        XCTAssertEqual(refreshRequests, 1)

        let recoveryLease = try await harness.coordinator
            .beginServerRecovery(ifCurrent: client.lease)
        try await harness.client.retrySessionRecovery(lease: client.lease)
        _ = try await harness.coordinator.resumeServerOperations(
            ifCurrent: recoveryLease
        )
        let trips = try await client.savedItineraries()

        XCTAssertEqual(refreshRequests, 2)
        XCTAssertEqual(privateRequests, 1)
        XCTAssertTrue(trips.isEmpty)
        let stored = await credentialStore.loadCredentials()
        XCTAssertEqual(stored?.accessToken, "recovered-access")
        XCTAssertEqual(stored?.userID, testUserIDA)
    }

    func testCancelledExplicitRecoveryRelatchesExactLease() async throws {
        let original = AuthCredentials(
            accessToken: "expired-access",
            refreshToken: "refresh-a",
            tokenType: "bearer",
            expiresAt: Date(timeIntervalSince1970: 1_000),
            userID: testUserIDA
        )
        let credentialStore = MemoryCredentialStore(
            installationID: "installation-id",
            credentials: original
        )
        let harness = makeClient(
            credentialStore: credentialStore
        )
        let client = harness.establishedAPI!
        let refreshStarted = DispatchSemaphore(value: 0)
        let releaseRefresh = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var refreshRequests = 0
        var privateRequests = 0

        URLProtocolStub.setHandler { request in
            switch request.url?.path {
            case "/api/v1/auth/refresh":
                lock.lock()
                refreshRequests += 1
                let requestNumber = refreshRequests
                lock.unlock()
                if requestNumber == 1 {
                    return .json(
                        statusCode: 401,
                        body: #"{"detail":"revoked"}"#
                    )
                }
                refreshStarted.signal()
                _ = releaseRefresh.wait(timeout: .now() + 5)
                return .json(
                    statusCode: 200,
                    body: """
                    {
                      "user_id": "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb",
                      "access_token": "late-recovered-access",
                      "refresh_token": "late-recovered-refresh",
                      "token_type": "bearer",
                      "expires_in": 3600
                    }
                    """
                )
            case "/api/v1/itineraries":
                lock.lock()
                privateRequests += 1
                lock.unlock()
                return .json(statusCode: 200, body: "[]")
            default:
                XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
                return .json(statusCode: 404, body: "{}")
            }
        }

        do {
            _ = try await client.savedItineraries()
            XCTFail("The rejected refresh must latch recovery")
        } catch let error as APIError {
            XCTAssertEqual(error, .identityRecoveryRequired)
        }

        let recovery = Task { () -> Error? in
            do {
                try await harness.client.retrySessionRecovery(
                    lease: client.lease
                )
                return nil
            } catch {
                return error
            }
        }
        XCTAssertEqual(refreshStarted.wait(timeout: .now() + 5), .success)
        recovery.cancel()
        releaseRefresh.signal()
        let recoveryError = await recovery.value
        XCTAssertTrue(recoveryError is CancellationError)

        do {
            _ = try await client.savedItineraries()
            XCTFail("Cancellation after unlatching must restore the latch")
        } catch let error as APIError {
            XCTAssertEqual(error, .identityRecoveryRequired)
        }
        XCTAssertEqual(refreshRequests, 2)
        XCTAssertEqual(privateRequests, 0)
    }

    func testRejectedExplicitRecoveryRelatchesExactLease() async throws {
        try await assertExplicitRecoveryFailureRelatches(.rejected)
    }

    func testTransportFailedExplicitRecoveryRelatchesExactLease() async throws {
        try await assertExplicitRecoveryFailureRelatches(.transport)
    }

    func testMismatchedExplicitRecoveryRelatchesExactLease() async throws {
        try await assertExplicitRecoveryFailureRelatches(.mismatchedIdentity)
    }

    func testTransitionDeletionRetriesLostResponseWithOriginalExpiredToken() async throws {
        let original = AuthCredentials(
            accessToken: "expired-but-retained-access",
            refreshToken: "retained-refresh",
            tokenType: "bearer",
            expiresAt: Date(timeIntervalSince1970: 1_000),
            userID: testUserIDA
        )
        let credentialStore = MemoryCredentialStore(
            installationID: "installation-id",
            credentials: original
        )
        let harness = makeClient(credentialStore: credentialStore)
        let expectedScope = try PrincipalIdentity(
            serverUserID: testUserIDA
        ).scope
        let transitionEpoch = try await harness.coordinator.beginTransition()
        await harness.client.cancelAndInvalidateAuthentication()
        let lock = NSLock()
        var deleteRequests = 0
        var refreshRequests = 0
        var guestRequests = 0

        URLProtocolStub.setHandler { request in
            switch request.url?.path {
            case "/api/v1/auth/me":
                lock.lock()
                deleteRequests += 1
                let requestNumber = deleteRequests
                lock.unlock()
                XCTAssertEqual(request.httpMethod, "DELETE")
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer expired-but-retained-access"
                )
                if requestNumber == 1 {
                    throw URLError(.networkConnectionLost)
                }
                return .json(statusCode: 204, body: "")
            case "/api/v1/auth/refresh":
                lock.lock()
                refreshRequests += 1
                lock.unlock()
                return .json(statusCode: 500, body: "{}")
            case "/api/v1/auth/guest":
                lock.lock()
                guestRequests += 1
                lock.unlock()
                return .json(statusCode: 500, body: "{}")
            default:
                XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
                return .json(statusCode: 404, body: "{}")
            }
        }

        do {
            try await harness.client.retryServerDeletion(
                expectedScope: expectedScope,
                at: transitionEpoch
            )
            XCTFail("A lost response must keep deletion recovery pending")
        } catch APIError.transport(let code, _) {
            XCTAssertEqual(code, .networkConnectionLost)
        }

        try await harness.client.retryServerDeletion(
            expectedScope: expectedScope,
            at: transitionEpoch
        )

        XCTAssertEqual(deleteRequests, 2)
        XCTAssertEqual(refreshRequests, 0)
        XCTAssertEqual(guestRequests, 0)
        let stored = await credentialStore.loadCredentials()
        XCTAssertEqual(stored, original)
        do {
            _ = try await harness.coordinator.currentLease()
            XCTFail("Deletion recovery must not establish a principal")
        } catch let error as IdentityCoordinatorError {
            XCTAssertEqual(error, .identityNotEstablished)
        }
    }

    func testTransitionDeletionRefreshesOnlySamePrincipalAfter401() async throws {
        let original = AuthCredentials(
            accessToken: "expired-access-a",
            refreshToken: "refresh-a",
            tokenType: "bearer",
            expiresAt: Date(timeIntervalSince1970: 1_000),
            userID: testUserIDA
        )
        let credentialStore = MemoryCredentialStore(
            installationID: "installation-id",
            credentials: original
        )
        let harness = makeClient(credentialStore: credentialStore)
        let expectedScope = try PrincipalIdentity(
            serverUserID: testUserIDA
        ).scope
        let transitionEpoch = try await harness.coordinator.beginTransition()
        await harness.client.cancelAndInvalidateAuthentication()
        let lock = NSLock()
        var deleteRequests = 0
        var refreshRequests = 0
        var guestRequests = 0

        URLProtocolStub.setHandler { request in
            switch request.url?.path {
            case "/api/v1/auth/me":
                lock.lock()
                deleteRequests += 1
                let requestNumber = deleteRequests
                lock.unlock()
                let expectedToken = requestNumber == 1
                    ? "Bearer expired-access-a"
                    : "Bearer refreshed-access-a"
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    expectedToken
                )
                return .json(
                    statusCode: requestNumber == 1 ? 401 : 204,
                    body: requestNumber == 1 ? #"{"detail":"expired"}"# : ""
                )
            case "/api/v1/auth/refresh":
                lock.lock()
                refreshRequests += 1
                lock.unlock()
                let body = try XCTUnwrap(request.bodyData)
                let json = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                XCTAssertEqual(json["refresh_token"] as? String, "refresh-a")
                return .json(
                    statusCode: 200,
                    body: """
                    {
                      "user_id": "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb",
                      "access_token": "refreshed-access-a",
                      "refresh_token": "refreshed-refresh-a",
                      "token_type": "bearer",
                      "expires_in": 3600
                    }
                    """
                )
            case "/api/v1/auth/guest":
                lock.lock()
                guestRequests += 1
                lock.unlock()
                return .json(statusCode: 500, body: "{}")
            default:
                XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
                return .json(statusCode: 404, body: "{}")
            }
        }

        try await harness.client.retryServerDeletion(
            expectedScope: expectedScope,
            at: transitionEpoch
        )

        XCTAssertEqual(deleteRequests, 2)
        XCTAssertEqual(refreshRequests, 1)
        XCTAssertEqual(guestRequests, 0)
        let stored = await credentialStore.loadCredentials()
        XCTAssertEqual(stored?.accessToken, "refreshed-access-a")
        XCTAssertEqual(stored?.refreshToken, "refreshed-refresh-a")
        XCTAssertEqual(stored?.userID, testUserIDA)
        let remainsInTransition = await harness.coordinator.isCurrentTransition(
            epoch: transitionEpoch
        )
        XCTAssertTrue(remainsInTransition)
    }

    func testTransitionDeletionUsesVerifiedRefreshWhenCredentialSaveFails()
        async throws {
        let original = AuthCredentials(
            accessToken: "expired-access-a",
            refreshToken: "refresh-a",
            tokenType: "bearer",
            expiresAt: Date(timeIntervalSince1970: 1_000),
            userID: testUserIDA
        )
        let credentialStore = MemoryCredentialStore(
            installationID: "installation-id",
            credentials: original,
            saveFailures: 1
        )
        let harness = makeClient(credentialStore: credentialStore)
        let expectedScope = try PrincipalIdentity(
            serverUserID: testUserIDA
        ).scope
        let transitionEpoch = try await harness.coordinator.beginTransition()
        await harness.client.cancelAndInvalidateAuthentication()
        let lock = NSLock()
        var deleteRequests = 0
        var refreshRequests = 0
        var guestRequests = 0

        URLProtocolStub.setHandler { request in
            switch request.url?.path {
            case "/api/v1/auth/me":
                lock.lock()
                deleteRequests += 1
                let requestNumber = deleteRequests
                lock.unlock()
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    requestNumber == 1
                        ? "Bearer expired-access-a"
                        : "Bearer refreshed-access-a"
                )
                return .json(
                    statusCode: requestNumber == 1 ? 401 : 204,
                    body: requestNumber == 1 ? #"{"detail":"expired"}"# : ""
                )
            case "/api/v1/auth/refresh":
                lock.lock()
                refreshRequests += 1
                lock.unlock()
                return .json(
                    statusCode: 200,
                    body: """
                    {
                      "user_id": "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb",
                      "access_token": "refreshed-access-a",
                      "refresh_token": "refreshed-refresh-a",
                      "token_type": "bearer",
                      "expires_in": 3600
                    }
                    """
                )
            case "/api/v1/auth/guest":
                lock.lock()
                guestRequests += 1
                lock.unlock()
                return .json(statusCode: 500, body: "{}")
            default:
                XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
                return .json(statusCode: 404, body: "{}")
            }
        }

        try await harness.client.retryServerDeletion(
            expectedScope: expectedScope,
            at: transitionEpoch
        )

        XCTAssertEqual(deleteRequests, 2)
        XCTAssertEqual(refreshRequests, 1)
        XCTAssertEqual(guestRequests, 0)
        let stored = await credentialStore.loadCredentials()
        XCTAssertEqual(stored, original)
        let remainsInTransition = await harness.coordinator
            .isCurrentTransition(
                epoch: transitionEpoch
            )
        XCTAssertTrue(remainsInTransition)
    }

    func testTransitionDeletionRejectedRefreshRequiresRecoveryWithoutMutation() async throws {
        let original = AuthCredentials(
            accessToken: "rejected-access-a",
            refreshToken: "rejected-refresh-a",
            tokenType: "bearer",
            expiresAt: Date(timeIntervalSince1970: 1_000),
            userID: testUserIDA
        )
        let credentialStore = MemoryCredentialStore(
            installationID: "installation-id",
            credentials: original
        )
        let harness = makeClient(credentialStore: credentialStore)
        let expectedScope = try PrincipalIdentity(
            serverUserID: testUserIDA
        ).scope
        let transitionEpoch = try await harness.coordinator.beginTransition()
        await harness.client.cancelAndInvalidateAuthentication()
        let lock = NSLock()
        var deleteRequests = 0
        var refreshRequests = 0
        var guestRequests = 0

        URLProtocolStub.setHandler { request in
            switch request.url?.path {
            case "/api/v1/auth/me":
                lock.lock()
                deleteRequests += 1
                lock.unlock()
                return .json(statusCode: 401, body: #"{"detail":"expired"}"#)
            case "/api/v1/auth/refresh":
                lock.lock()
                refreshRequests += 1
                lock.unlock()
                return .json(statusCode: 401, body: #"{"detail":"revoked"}"#)
            case "/api/v1/auth/guest":
                lock.lock()
                guestRequests += 1
                lock.unlock()
                return .json(statusCode: 500, body: "{}")
            default:
                XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
                return .json(statusCode: 404, body: "{}")
            }
        }

        do {
            try await harness.client.retryServerDeletion(
                expectedScope: expectedScope,
                at: transitionEpoch
            )
            XCTFail("Rejected deletion refresh must require explicit recovery")
        } catch let error as APIError {
            XCTAssertEqual(error, .identityRecoveryRequired)
        }

        XCTAssertEqual(deleteRequests, 1)
        XCTAssertEqual(refreshRequests, 1)
        XCTAssertEqual(guestRequests, 0)
        let stored = await credentialStore.loadCredentials()
        XCTAssertEqual(stored, original)
    }

    func testTransitionDeletionRejectsDifferentPrincipalRefreshWithoutRetry() async throws {
        let original = AuthCredentials(
            accessToken: "access-a",
            refreshToken: "refresh-a",
            tokenType: "bearer",
            expiresAt: Date(timeIntervalSince1970: 1_000),
            userID: testUserIDA
        )
        let credentialStore = MemoryCredentialStore(
            installationID: "installation-id",
            credentials: original
        )
        let harness = makeClient(credentialStore: credentialStore)
        let expectedScope = try PrincipalIdentity(
            serverUserID: testUserIDA
        ).scope
        let transitionEpoch = try await harness.coordinator.beginTransition()
        await harness.client.cancelAndInvalidateAuthentication()
        let lock = NSLock()
        var deleteRequests = 0

        URLProtocolStub.setHandler { request in
            switch request.url?.path {
            case "/api/v1/auth/me":
                lock.lock()
                deleteRequests += 1
                lock.unlock()
                return .json(statusCode: 401, body: #"{"detail":"expired"}"#)
            case "/api/v1/auth/refresh":
                return .json(
                    statusCode: 200,
                    body: """
                    {
                      "user_id": "bbbbbbbb-1111-2222-3333-cccccccccccc",
                      "access_token": "access-b",
                      "refresh_token": "refresh-b",
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
            try await harness.client.retryServerDeletion(
                expectedScope: expectedScope,
                at: transitionEpoch
            )
            XCTFail("A different principal can never satisfy deletion recovery")
        } catch let error as APIError {
            XCTAssertEqual(error, .identityIntegrityFailure)
        }

        XCTAssertEqual(deleteRequests, 1)
        let stored = await credentialStore.loadCredentials()
        XCTAssertEqual(stored, original)
    }

    func testAppleLinkConflictIsTypedAndDoesNotSignInOrReplaceCredentials() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "installation-id",
            credentials: validCredentials
        )
        let client = makeClient(credentialStore: credentialStore).establishedAPI!
        let lock = NSLock()
        var signInRequests = 0
        URLProtocolStub.setHandler { request in
            switch request.url?.path {
            case "/api/v1/auth/apple/link":
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer access-1"
                )
                return .json(
                    statusCode: 409,
                    body: """
                    {
                      "detail": {
                        "code": "apple_account_exists",
                        "message": "This Apple account already has an Itinera library."
                      }
                    }
                    """
                )
            case "/api/v1/auth/apple":
                lock.lock()
                signInRequests += 1
                lock.unlock()
                return .json(statusCode: 500, body: "{}")
            default:
                XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
                return .json(statusCode: 404, body: "{}")
            }
        }

        let result = try await client.connectAppleAccount(identityToken: "ephemeral-token")

        XCTAssertEqual(result, .switchConfirmationRequired)
        XCTAssertEqual(signInRequests, 0)
        let stored = await credentialStore.loadCredentials()
        XCTAssertEqual(stored, validCredentials)
    }

    func testAppleLinkUnrecognizedConflictIsNotOfferedAsAccountSwitch() async throws {
        let original = validCredentials
        let credentialStore = MemoryCredentialStore(
            installationID: "installation-id",
            credentials: original
        )
        let client = makeClient(credentialStore: credentialStore).establishedAPI!
        URLProtocolStub.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/v1/auth/apple/link")
            return .json(
                statusCode: 409,
                body: #"{"detail":{"code":"unknown_conflict","message":"Conflict"}}"#
            )
        }

        do {
            _ = try await client.connectAppleAccount(identityToken: "ephemeral-token")
            XCTFail("Only apple_account_exists is a confirmable switch")
        } catch APIError.http(let statusCode, let code, _, _) {
            XCTAssertEqual(statusCode, 409)
            XCTAssertEqual(code, "unknown_conflict")
        }
        let stored = await credentialStore.loadCredentials()
        XCTAssertEqual(stored, original)
    }

    func testAppleLinkSamePrincipalRotatesCredentials() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "installation-id",
            credentials: validCredentials
        )
        let client = makeClient(credentialStore: credentialStore).establishedAPI!
        URLProtocolStub.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/v1/auth/apple/link")
            return .json(
                statusCode: 200,
                body: """
                {
                  "user_id": "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb",
                  "access_token": "apple-access",
                  "refresh_token": "apple-refresh",
                  "token_type": "bearer",
                  "expires_in": 3600
                }
                """
            )
        }

        let result = try await client.connectAppleAccount(identityToken: "ephemeral-token")

        XCTAssertEqual(result, .linked)
        let stored = await credentialStore.loadCredentials()
        XCTAssertEqual(stored?.accessToken, "apple-access")
        XCTAssertEqual(stored?.userID, testUserIDA)
    }

    func testAppleLinkSuccessForDifferentPrincipalFailsWithoutSaving() async throws {
        let original = validCredentials
        let credentialStore = MemoryCredentialStore(
            installationID: "installation-id",
            credentials: original
        )
        let client = makeClient(credentialStore: credentialStore).establishedAPI!
        URLProtocolStub.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/v1/auth/apple/link")
            return .json(
                statusCode: 200,
                body: """
                {
                  "user_id": "bbbbbbbb-1111-2222-3333-cccccccccccc",
                  "access_token": "wrong-access",
                  "refresh_token": "wrong-refresh",
                  "token_type": "bearer",
                  "expires_in": 3600
                }
                """
            )
        }

        do {
            _ = try await client.connectAppleAccount(identityToken: "ephemeral-token")
            XCTFail("Apple linking cannot change the established principal")
        } catch let error as APIError {
            XCTAssertEqual(error, .identityIntegrityFailure)
        }
        let stored = await credentialStore.loadCredentials()
        XCTAssertEqual(stored, original)
    }

    func testConfirmedAppleCandidateDoesNotReplaceCredentialsUntilTransitionActivation() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "installation-id",
            credentials: validCredentials
        )
        let harness = makeClient(credentialStore: credentialStore)
        URLProtocolStub.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/v1/auth/apple")
            return .json(
                statusCode: 200,
                body: """
                {
                  "user_id": "bbbbbbbb-1111-2222-3333-cccccccccccc",
                  "access_token": "candidate-access",
                  "refresh_token": "candidate-refresh",
                  "token_type": "bearer",
                  "expires_in": 3600
                }
                """
            )
        }

        let candidate = try await harness.establishedAPI!.prepareAppleSwitch(
            identityToken: "ephemeral-token"
        )
        let beforeActivation = await credentialStore.loadCredentials()
        XCTAssertEqual(beforeActivation, validCredentials)
        XCTAssertEqual(candidate.identity.serverUserID, testUserIDB)

        let transitionEpoch = try await harness.coordinator.beginTransition()
        await harness.client.cancelAndInvalidateAuthentication()
        let activated = try await harness.client.activateAppleCandidate(
            candidate,
            at: transitionEpoch
        )

        XCTAssertEqual(activated.identity.serverUserID, testUserIDB)
        let stored = await credentialStore.loadCredentials()
        XCTAssertEqual(stored?.accessToken, "candidate-access")
        XCTAssertEqual(stored?.userID, testUserIDB)
    }

    func testFailedAppleSwitchPreparationKeepsCurrentCredentials() async throws {
        let original = validCredentials
        let credentialStore = MemoryCredentialStore(
            installationID: "installation-id",
            credentials: original
        )
        let harness = makeClient(credentialStore: credentialStore)
        URLProtocolStub.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/v1/auth/apple")
            return .json(
                statusCode: 503,
                body: #"{"detail":"Apple sign-in unavailable"}"#
            )
        }

        do {
            _ = try await harness.establishedAPI!.prepareAppleSwitch(
                identityToken: "ephemeral-token"
            )
            XCTFail("Failed preparation must not activate a candidate")
        } catch APIError.http(let statusCode, _, _, _) {
            XCTAssertEqual(statusCode, 503)
        }
        let stored = await credentialStore.loadCredentials()
        XCTAssertEqual(stored, original)
    }

    func testDelayedRefreshCannotSaveOrRetryAfterRapidAtoBtoA() async throws {
        let original = AuthCredentials(
            accessToken: "expired-a",
            refreshToken: "refresh-a",
            tokenType: "bearer",
            expiresAt: Date(timeIntervalSince1970: 1_000),
            userID: testUserIDA
        )
        let credentialStore = MemoryCredentialStore(
            installationID: "installation-id",
            credentials: original
        )
        let harness = makeClient(credentialStore: credentialStore)
        let refreshStarted = DispatchSemaphore(value: 0)
        let releaseRefresh = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var itineraryRequests = 0
        URLProtocolStub.setHandler { request in
            switch request.url?.path {
            case "/api/v1/auth/refresh":
                refreshStarted.signal()
                _ = releaseRefresh.wait(timeout: .now() + 5)
                return .json(
                    statusCode: 200,
                    body: """
                    {
                      "user_id": "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb",
                      "access_token": "late-access-a",
                      "refresh_token": "late-refresh-a",
                      "token_type": "bearer",
                      "expires_in": 3600
                    }
                    """
                )
            case "/api/v1/itineraries":
                lock.lock()
                itineraryRequests += 1
                lock.unlock()
                return .json(statusCode: 200, body: "[]")
            default:
                return .json(statusCode: 404, body: "{}")
            }
        }

        let oldRequest = Task { () -> Error? in
            do {
                _ = try await harness.establishedAPI!.savedItineraries()
                return nil
            } catch {
                return error
            }
        }
        XCTAssertEqual(refreshStarted.wait(timeout: .now() + 5), .success)

        let epochB = try await harness.coordinator.beginTransition()
        let identityB = try PrincipalIdentity(serverUserID: testUserIDB)
        _ = try await harness.coordinator.establish(
            identityB.scope,
            presentationSessionID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            at: epochB
        )
        let epochA3 = try await harness.coordinator.beginTransition()
        let identityA = try PrincipalIdentity(serverUserID: testUserIDA)
        _ = try await harness.coordinator.establish(
            identityA.scope,
            presentationSessionID: UUID(uuidString: "aaaaaaaa-3333-3333-3333-aaaaaaaaaaaa")!,
            at: epochA3
        )
        releaseRefresh.signal()

        let error = await oldRequest.value
        XCTAssertEqual(error as? IdentityCoordinatorError, .staleIdentity)
        let stored = await credentialStore.loadCredentials()
        XCTAssertEqual(stored, original)
        XCTAssertEqual(itineraryRequests, 0)
    }

    func testCancelAndInvalidateAuthenticationStopsDelayedRefreshInSameEpoch() async throws {
        let original = AuthCredentials(
            accessToken: "expired-a",
            refreshToken: "refresh-a",
            tokenType: "bearer",
            expiresAt: Date(timeIntervalSince1970: 1_000),
            userID: testUserIDA
        )
        let credentialStore = MemoryCredentialStore(
            installationID: "installation-id",
            credentials: original
        )
        let harness = makeClient(credentialStore: credentialStore)
        let refreshStarted = DispatchSemaphore(value: 0)
        let releaseRefresh = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var itineraryRequests = 0
        URLProtocolStub.setHandler { request in
            switch request.url?.path {
            case "/api/v1/auth/refresh":
                refreshStarted.signal()
                _ = releaseRefresh.wait(timeout: .now() + 5)
                return .json(
                    statusCode: 200,
                    body: """
                    {
                      "user_id": "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb",
                      "access_token": "late-access-a",
                      "refresh_token": "late-refresh-a",
                      "token_type": "bearer",
                      "expires_in": 3600
                    }
                    """
                )
            case "/api/v1/itineraries":
                lock.lock()
                itineraryRequests += 1
                lock.unlock()
                return .json(statusCode: 200, body: "[]")
            default:
                return .json(statusCode: 404, body: "{}")
            }
        }

        let request = Task { () -> Error? in
            do {
                _ = try await harness.establishedAPI!.savedItineraries()
                return nil
            } catch {
                return error
            }
        }
        XCTAssertEqual(refreshStarted.wait(timeout: .now() + 5), .success)
        await harness.client.cancelAndInvalidateAuthentication()
        releaseRefresh.signal()

        let error = await request.value
        XCTAssertTrue(error is CancellationError)
        let stored = await credentialStore.loadCredentials()
        XCTAssertEqual(stored, original)
        XCTAssertEqual(itineraryRequests, 0)
    }

    func testLeaseBoundMutationSuspendedBeforeDispatchMakesZeroRequestsAfterAtoB() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "installation-id",
            credentials: validCredentials
        )
        let harness = makeClient(credentialStore: credentialStore)
        let capturedA = harness.establishedAPI!
        let dispatchGate = TestAsyncGate()
        let lock = NSLock()
        var requests = 0
        URLProtocolStub.setHandler { _ in
            lock.lock()
            requests += 1
            lock.unlock()
            return .json(statusCode: 200, body: "[]")
        }

        let suspendedMutation = Task { () -> Error? in
            await dispatchGate.wait()
            do {
                _ = try await capturedA.updateTrip("trip-a", archived: true)
                return nil
            } catch {
                return error
            }
        }
        await dispatchGate.waitUntilSuspended()

        let epochB = try await harness.coordinator.beginTransition()
        let identityB = try PrincipalIdentity(serverUserID: testUserIDB)
        _ = try await harness.coordinator.establish(
            identityB.scope,
            presentationSessionID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            at: epochB
        )
        await dispatchGate.open()

        let error = await suspendedMutation.value
        XCTAssertEqual(error as? IdentityCoordinatorError, .staleIdentity)
        XCTAssertEqual(requests, 0)
    }

    func testLeaseBoundMutationSuspendedBeforeDispatchMakesZeroRequestsAfterA1toBtoA3() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "installation-id",
            credentials: validCredentials
        )
        let harness = makeClient(credentialStore: credentialStore)
        let capturedA1 = harness.establishedAPI!
        let dispatchGate = TestAsyncGate()
        let lock = NSLock()
        var requests = 0
        URLProtocolStub.setHandler { _ in
            lock.lock()
            requests += 1
            lock.unlock()
            return .json(statusCode: 200, body: "[]")
        }

        let suspendedMutation = Task { () -> Error? in
            await dispatchGate.wait()
            do {
                _ = try await capturedA1.updateTrip("trip-a", title: "stale")
                return nil
            } catch {
                return error
            }
        }
        await dispatchGate.waitUntilSuspended()

        let epochB = try await harness.coordinator.beginTransition()
        let identityB = try PrincipalIdentity(serverUserID: testUserIDB)
        _ = try await harness.coordinator.establish(
            identityB.scope,
            presentationSessionID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            at: epochB
        )
        let epochA3 = try await harness.coordinator.beginTransition()
        let identityA = try PrincipalIdentity(serverUserID: testUserIDA)
        _ = try await harness.coordinator.establish(
            identityA.scope,
            presentationSessionID: UUID(uuidString: "aaaaaaaa-3333-3333-3333-aaaaaaaaaaaa")!,
            at: epochA3
        )
        await dispatchGate.open()

        let error = await suspendedMutation.value
        XCTAssertEqual(error as? IdentityCoordinatorError, .staleIdentity)
        XCTAssertEqual(requests, 0)
    }

    func testCredentialMutationGateOrdersStaleAWritesBeforeBClearAndSave() async throws {
        let original = validCredentials
        let credentialStore = SuspendingCredentialStore(
            installationID: "installation-id",
            credentials: original
        )
        await credentialStore.suspendNextSave()
        let harness = makeClient(credentialStore: credentialStore)
        let lock = NSLock()
        var linkResponses = 0
        URLProtocolStub.setHandler { request in
            switch request.url?.path {
            case "/api/v1/auth/apple/link":
                lock.lock()
                linkResponses += 1
                let responseNumber = linkResponses
                lock.unlock()
                return .json(
                    statusCode: 200,
                    body: """
                    {
                      "user_id": "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb",
                      "access_token": "rotated-a-\(responseNumber)",
                      "refresh_token": "rotated-refresh-a-\(responseNumber)",
                      "token_type": "bearer",
                      "expires_in": 3600
                    }
                    """
                )
            case "/api/v1/auth/guest":
                return .json(
                    statusCode: 201,
                    body: """
                    {
                      "user_id": "bbbbbbbb-1111-2222-3333-cccccccccccc",
                      "access_token": "access-b",
                      "refresh_token": "refresh-b",
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

        let firstA = Task { () -> Error? in
            do {
                _ = try await harness.establishedAPI!.connectAppleAccount(
                    identityToken: "first-a"
                )
                return nil
            } catch {
                return error
            }
        }
        await credentialStore.waitForSuspendedSave()

        let waiterObserved = Task {
            await harness.client.waitForCredentialMutationWaiterForTesting()
        }
        let queuedA = Task { () -> Error? in
            do {
                _ = try await harness.establishedAPI!.connectAppleAccount(
                    identityToken: "queued-a"
                )
                return nil
            } catch {
                return error
            }
        }
        await waiterObserved.value

        let transitionEpoch = try await harness.coordinator.beginTransition()
        await harness.client.cancelAndInvalidateAuthentication()
        let clearTask = Task {
            try await harness.client.clearCredentials(at: transitionEpoch)
        }
        await credentialStore.resumeSuspendedSave()

        let firstError = await firstA.value
        let queuedError = await queuedA.value
        XCTAssertEqual(firstError as? IdentityCoordinatorError, .staleIdentity)
        XCTAssertEqual(queuedError as? IdentityCoordinatorError, .staleIdentity)
        try await clearTask.value
        let principalB = try await harness.client.createGuestCredentials(
            at: transitionEpoch
        )

        XCTAssertEqual(principalB.identity.serverUserID, testUserIDB)
        let final = await credentialStore.loadCredentials()
        XCTAssertEqual(final?.accessToken, "access-b")
        XCTAssertEqual(final?.userID, testUserIDB)
        let saved = await credentialStore.savedCredentials()
        XCTAssertEqual(saved.map(\.accessToken), ["rotated-a-1", "access-b"])
        let clears = await credentialStore.clearCount()
        XCTAssertEqual(clears, 1)
    }

    func testPopularItineraryEndpointsDecodeSnakeCaseResponses() async throws {
        let credentialStore = MemoryCredentialStore(
            installationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            credentials: validCredentials
        )
        let client = makeClient(credentialStore: credentialStore).establishedAPI!

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
        let client = makeClient(credentialStore: credentialStore).establishedAPI!

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

    private enum ExplicitRecoveryFailure {
        case rejected
        case transport
        case mismatchedIdentity
    }

    private func assertExplicitRecoveryFailureRelatches(
        _ failure: ExplicitRecoveryFailure
    ) async throws {
        let original = AuthCredentials(
            accessToken: "expired-access",
            refreshToken: "refresh-a",
            tokenType: "bearer",
            expiresAt: Date(timeIntervalSince1970: 1_000),
            userID: testUserIDA
        )
        let credentialStore = MemoryCredentialStore(
            installationID: "installation-id",
            credentials: original
        )
        let harness = makeClient(
            credentialStore: credentialStore
        )
        let client = harness.establishedAPI!
        let lock = NSLock()
        var refreshRequests = 0
        var privateRequests = 0
        URLProtocolStub.setHandler { request in
            switch request.url?.path {
            case "/api/v1/auth/refresh":
                lock.lock()
                refreshRequests += 1
                let requestNumber = refreshRequests
                lock.unlock()
                if requestNumber == 1 {
                    return .json(
                        statusCode: 401,
                        body: #"{"detail":"revoked"}"#
                    )
                }
                switch failure {
                case .rejected:
                    return .json(
                        statusCode: 401,
                        body: #"{"detail":"still revoked"}"#
                    )
                case .transport:
                    throw URLError(.notConnectedToInternet)
                case .mismatchedIdentity:
                    return .json(
                        statusCode: 200,
                        body: """
                        {
                          "user_id": "bbbbbbbb-1111-2222-3333-cccccccccccc",
                          "access_token": "access-b",
                          "refresh_token": "refresh-b",
                          "token_type": "bearer",
                          "expires_in": 3600
                        }
                        """
                    )
                }
            case "/api/v1/itineraries":
                lock.lock()
                privateRequests += 1
                lock.unlock()
                return .json(statusCode: 200, body: "[]")
            default:
                XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
                return .json(statusCode: 404, body: "{}")
            }
        }

        do {
            _ = try await client.savedItineraries()
            XCTFail("The initial rejected refresh must latch recovery")
        } catch let error as APIError {
            XCTAssertEqual(error, .identityRecoveryRequired)
        }

        let recoveryError: Error
        do {
            try await harness.client.retrySessionRecovery(
                lease: client.lease
            )
            XCTFail("The explicit recovery was expected to fail")
            return
        } catch {
            recoveryError = error
        }
        switch failure {
        case .rejected:
            XCTAssertEqual(
                recoveryError as? APIError,
                .identityRecoveryRequired
            )
        case .transport:
            guard case .transport(let code, _) = recoveryError as? APIError else {
                return XCTFail("Expected a typed transport error")
            }
            XCTAssertEqual(code, .notConnectedToInternet)
        case .mismatchedIdentity:
            XCTAssertEqual(
                recoveryError as? APIError,
                .identityIntegrityFailure
            )
        }

        do {
            _ = try await client.savedItineraries()
            XCTFail("An unsuccessful explicit recovery must restore the latch")
        } catch let error as APIError {
            XCTAssertEqual(error, .identityRecoveryRequired)
        }
        XCTAssertEqual(refreshRequests, 2)
        XCTAssertEqual(privateRequests, 0)
        let stored = await credentialStore.loadCredentials()
        XCTAssertEqual(stored, original)
    }

    private struct ClientHarness {
        let client: APIClient
        let coordinator: IdentityCoordinator
        let establishedAPI: IdentityBoundAPIClient?
    }

    private func makeClient(
        credentialStore: any CredentialStoring,
        establishedUserID: String? = "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb"
    ) -> ClientHarness {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let coordinator: IdentityCoordinator
        let initialLease: IdentityLease?
        if let establishedUserID {
            let identity = try! PrincipalIdentity(serverUserID: establishedUserID)
            let sessionID = UUID(
                uuidString: "77777777-7777-7777-7777-777777777777"
            )!
            coordinator = IdentityCoordinator(
                initialScope: identity.scope,
                initialEpoch: 7,
                initialPresentationSessionID: sessionID
            )
            initialLease = IdentityLease(
                scope: identity.scope,
                epoch: 7,
                presentationSessionID: sessionID
            )
        } else {
            coordinator = IdentityCoordinator()
            initialLease = nil
        }
        let client = APIClient(
            configuration: APIConfiguration(
                baseURL: URL(string: "https://example.test")!,
                requestTimeout: 2,
                resourceTimeout: 3
            ),
            session: URLSession(configuration: configuration),
            credentialStore: credentialStore,
            identityCoordinator: coordinator,
            now: { Date(timeIntervalSince1970: 2_000_000_000) }
        )
        return ClientHarness(
            client: client,
            coordinator: coordinator,
            establishedAPI: initialLease.map { client.bound(to: $0) }
        )
    }

    private var testUserIDA: String {
        "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb"
    }

    private var testUserIDB: String {
        "bbbbbbbb-1111-2222-3333-cccccccccccc"
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
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
            userID: testUserIDA
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

private enum MemoryCredentialStoreError: Error {
    case saveFailed
}

private actor MemoryCredentialStore: CredentialStoring {
    private let installationID: String
    private var credentials: AuthCredentials?
    private var saveFailures: Int

    init(
        installationID: String,
        credentials: AuthCredentials? = nil,
        saveFailures: Int = 0
    ) {
        self.installationID = installationID
        self.credentials = credentials
        self.saveFailures = saveFailures
    }

    func loadCredentials() -> AuthCredentials? { credentials }
    func saveCredentials(_ credentials: AuthCredentials) throws {
        if saveFailures > 0 {
            saveFailures -= 1
            throw MemoryCredentialStoreError.saveFailed
        }
        self.credentials = credentials
    }
    func clearCredentials() { credentials = nil }
    func installationIdentifier() -> String { installationID }
}

private actor SuspendingCredentialStore: CredentialStoring {
    private let installationID: String
    private var credentials: AuthCredentials?
    private var shouldSuspendNextSave = false
    private var suspendedSaveContinuation: CheckedContinuation<Void, Never>?
    private var saveStartedContinuations: [CheckedContinuation<Void, Never>] = []
    private var saveIsSuspended = false
    private var saves: [AuthCredentials] = []
    private var clears = 0

    init(installationID: String, credentials: AuthCredentials?) {
        self.installationID = installationID
        self.credentials = credentials
    }

    func suspendNextSave() {
        shouldSuspendNextSave = true
    }

    func waitForSuspendedSave() async {
        guard !saveIsSuspended else { return }
        await withCheckedContinuation { continuation in
            saveStartedContinuations.append(continuation)
        }
    }

    func resumeSuspendedSave() {
        suspendedSaveContinuation?.resume()
        suspendedSaveContinuation = nil
    }

    func loadCredentials() -> AuthCredentials? { credentials }

    func saveCredentials(_ credentials: AuthCredentials) async {
        if shouldSuspendNextSave {
            shouldSuspendNextSave = false
            saveIsSuspended = true
            let continuations = saveStartedContinuations
            saveStartedContinuations.removeAll()
            continuations.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                suspendedSaveContinuation = continuation
            }
            saveIsSuspended = false
        }
        self.credentials = credentials
        saves.append(credentials)
    }

    func clearCredentials() {
        credentials = nil
        clears += 1
    }

    func installationIdentifier() -> String { installationID }
    func savedCredentials() -> [AuthCredentials] { saves }
    func clearCount() -> Int { clears }
}

private actor TestAsyncGate {
    private var isOpen = false
    private var isSuspended = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var suspensionObservers: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        isSuspended = true
        let observers = suspensionObservers
        suspensionObservers.removeAll()
        observers.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            suspensionObservers.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
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
