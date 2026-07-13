import Foundation
import XCTest
@testable import Itinera

@MainActor
final class AppStateRecoveryBoundaryTests: XCTestCase {
    func testPausedGenerationCannotRelatchAfterExplicitRecoverySucceeds()
        async throws {
        let oldRetryGate = RecoveryBoundaryGate()
        let beforeResumeGate = RecoveryBoundaryAsyncGate()
        let harness = try makeHarness(
            beforeServerRecoveryResume: {
                await beforeResumeGate.suspendOnce()
            }
        )
        defer {
            oldRetryGate.release()
            RecoveryBoundaryURLProtocol.reset()
            Task { await beforeResumeGate.resume() }
            harness.remove()
        }
        let router = RecoveryBoundaryRequestRouter()
        router.enqueue(
            .savedTrips,
            outcomes: [
                .http(statusCode: 401, body: unauthorizedBody),
                .suspended(
                    gate: oldRetryGate,
                    statusCode: 401,
                    body: unauthorizedBody
                ),
                .http(statusCode: 401, body: unauthorizedBody),
                .http(statusCode: 401, body: unauthorizedBody),
                .http(statusCode: 200, body: Data("[]".utf8)),
                .http(statusCode: 200, body: Data("[]".utf8))
            ]
        )
        router.enqueue(
            .refresh,
            outcomes: [
                .http(
                    statusCode: 200,
                    body: tokenBody(
                        userID: principalA,
                        accessToken: "old-r1-access"
                    )
                ),
                .http(
                    statusCode: 200,
                    body: tokenBody(
                        userID: principalA,
                        accessToken: "latching-r1-access"
                    )
                ),
                .http(
                    statusCode: 200,
                    body: tokenBody(
                        userID: principalA,
                        accessToken: "recovered-r2-access"
                    )
                )
            ]
        )
        RecoveryBoundaryURLProtocol.install(router: router)

        let oldR1Request = Task { () -> Error? in
            do {
                let _: IdentityScopedValue<[SavedItinerary]> =
                    try await harness.appState.scopedAPIValue(
                        session: harness.session
                    ) {
                        try await $0.savedItineraries()
                    }
                return nil
            } catch {
                return error
            }
        }
        await oldRetryGate.waitUntilStarted()

        let latchingR1Request = Task { () -> Error? in
            do {
                let _: IdentityScopedValue<[SavedItinerary]> =
                    try await harness.appState.scopedAPIValue(
                        session: harness.session
                    ) {
                        try await $0.savedItineraries()
                    }
                return nil
            } catch {
                return error
            }
        }
        let latchingError = await latchingR1Request.value
        XCTAssertEqual(
            latchingError as? APIError,
            .identityRecoveryRequired
        )
        assertRecoveryRequired(harness.appState)

        let retry = Task {
            try await harness.appState.retryServerSession(
                session: harness.session
            )
        }
        await beforeResumeGate.waitUntilSuspended()
        let currentCredentials = await harness.credentials.currentCredentials()
        let recoveredCredentials = try XCTUnwrap(currentCredentials)
        XCTAssertEqual(
            recoveredCredentials.accessToken,
            "recovered-r2-access"
        )

        // Release the delayed terminal R1 response only after explicit API
        // recovery has succeeded but before the exact recovery lease mints R2.
        oldRetryGate.release()
        let oldR1Error = await oldR1Request.value
        XCTAssertEqual(
            oldR1Error as? IdentityCoordinatorError,
            .staleIdentity
        )
        assertRecoveryRequired(harness.appState)

        await beforeResumeGate.resume()
        try await retry.value
        XCTAssertEqual(harness.appState.identityPhase, .ready(isOffline: false))

        let freshR2: IdentityScopedValue<[SavedItinerary]> = try await harness
            .appState.scopedAPIValue(session: harness.session) {
                try await $0.savedItineraries()
            }
        XCTAssertTrue(freshR2.value.isEmpty)
        XCTAssertEqual(router.count(for: .refresh), 3)
        XCTAssertEqual(router.count(for: .savedTrips), 6)
    }

    func testExplicitRetryPublishesReadyOnlyAfterExactPrincipalRefresh()
        async throws {
        let harness = try makeHarness()
        defer {
            RecoveryBoundaryURLProtocol.reset()
            harness.remove()
        }
        let router = RecoveryBoundaryRequestRouter()
        let refreshGate = RecoveryBoundaryGate()
        router.enqueue(
            .savedTrips,
            outcomes: [
                .http(statusCode: 401, body: unauthorizedBody),
                .http(statusCode: 200, body: Data("[]".utf8))
            ]
        )
        router.enqueue(
            .refresh,
            outcomes: [
                .http(statusCode: 401, body: unauthorizedBody),
                .suspended(
                    gate: refreshGate,
                    statusCode: 200,
                    body: tokenBody(
                        userID: principalA,
                        accessToken: "recovered-access"
                    )
                )
            ]
        )
        RecoveryBoundaryURLProtocol.install(router: router)

        await latchRecovery(in: harness)

        let retry = Task {
            try await harness.appState.retryServerSession(
                session: harness.session
            )
        }
        await refreshGate.waitUntilStarted()

        guard case .recoveryRequired = harness.appState.identityPhase else {
            refreshGate.release()
            _ = try? await retry.value
            return XCTFail(
                "A suspended same-principal refresh cannot publish Ready."
            )
        }
        XCTAssertEqual(router.count(for: .savedTrips), 1)

        refreshGate.release()
        try await retry.value

        XCTAssertEqual(
            harness.appState.identityPhase,
            .ready(isOffline: false)
        )
        XCTAssertEqual(
            harness.appState.identityOutcome,
            .serverSessionRestored(isOffline: false)
        )
        XCTAssertEqual(router.count(for: .refresh), 2)
        XCTAssertEqual(router.count(for: .savedTrips), 2)
        let currentCredentials = await harness.credentials
            .currentCredentials()
        let stored = try XCTUnwrap(currentCredentials)
        XCTAssertEqual(stored.userID, principalA)
        XCTAssertEqual(stored.accessToken, "recovered-access")
    }

    func testRejectedExplicitRetryStaysRecoveryRequiredAndRelatchesNetwork()
        async throws {
        let harness = try makeHarness()
        defer {
            RecoveryBoundaryURLProtocol.reset()
            harness.remove()
        }
        let router = RecoveryBoundaryRequestRouter()
        router.enqueue(
            .savedTrips,
            outcomes: [.http(statusCode: 401, body: unauthorizedBody)]
        )
        router.enqueue(
            .refresh,
            outcomes: [
                .http(statusCode: 401, body: unauthorizedBody),
                .http(statusCode: 401, body: unauthorizedBody)
            ]
        )
        RecoveryBoundaryURLProtocol.install(router: router)

        await latchRecovery(in: harness)
        do {
            try await harness.appState.retryServerSession(
                session: harness.session
            )
            XCTFail("A rejected refresh cannot restore the server session.")
        } catch {
            XCTAssertEqual(error as? APIError, .identityRecoveryRequired)
        }

        assertRecoveryRequired(harness.appState)
        let requestCount = router.totalCount
        await assertOrdinaryReadIsBlocked(in: harness)
        XCTAssertEqual(router.totalCount, requestCount)
        XCTAssertEqual(router.count(for: .refresh), 2)
    }

    func testTransportExplicitRetryStaysRecoveryRequiredAndRelatchesNetwork()
        async throws {
        let harness = try makeHarness()
        defer {
            RecoveryBoundaryURLProtocol.reset()
            harness.remove()
        }
        let router = RecoveryBoundaryRequestRouter()
        router.enqueue(
            .savedTrips,
            outcomes: [.http(statusCode: 401, body: unauthorizedBody)]
        )
        router.enqueue(
            .refresh,
            outcomes: [
                .http(statusCode: 401, body: unauthorizedBody),
                .transport(.notConnectedToInternet)
            ]
        )
        RecoveryBoundaryURLProtocol.install(router: router)

        await latchRecovery(in: harness)
        do {
            try await harness.appState.retryServerSession(
                session: harness.session
            )
            XCTFail("A transport failure cannot verify the server session.")
        } catch let error as APIError {
            guard case .transport(let code, _) = error else {
                return XCTFail("Expected a typed transport failure: \(error)")
            }
            XCTAssertEqual(code, .notConnectedToInternet)
        }

        assertRecoveryRequired(harness.appState)
        let requestCount = router.totalCount
        await assertOrdinaryReadIsBlocked(in: harness)
        XCTAssertEqual(router.totalCount, requestCount)
        XCTAssertEqual(router.count(for: .refresh), 2)
    }

    func testServerFailedExplicitRetryStaysRecoveryRequiredAndRelatchesNetwork()
        async throws {
        let harness = try makeHarness()
        defer {
            RecoveryBoundaryURLProtocol.reset()
            harness.remove()
        }
        let router = RecoveryBoundaryRequestRouter()
        router.enqueue(
            .savedTrips,
            outcomes: [.http(statusCode: 401, body: unauthorizedBody)]
        )
        router.enqueue(
            .refresh,
            outcomes: [
                .http(statusCode: 401, body: unauthorizedBody),
                .http(statusCode: 500, body: Data(#"{"detail":"later"}"#.utf8))
            ]
        )
        RecoveryBoundaryURLProtocol.install(router: router)

        await latchRecovery(in: harness)
        do {
            try await harness.appState.retryServerSession(
                session: harness.session
            )
            XCTFail("A server failure cannot verify the session.")
        } catch let APIError.http(statusCode, _, _, _) {
            XCTAssertEqual(statusCode, 500)
        }

        assertRecoveryRequired(harness.appState)
        let requestCount = router.totalCount
        await assertOrdinaryReadIsBlocked(in: harness)
        XCTAssertEqual(router.totalCount, requestCount)
    }

    func testRecoveredSessionWithTripRefreshTransportUsesOfflineCopy()
        async throws {
        let harness = try makeHarness()
        defer {
            RecoveryBoundaryURLProtocol.reset()
            harness.remove()
        }
        let offlineTrip = savedOfflineTrip
        _ = try await harness.stores.completedTripCache.replace(
            with: [offlineTrip],
            lease: harness.session.lease
        )
        await harness.appState.loadCachedTrips(session: harness.session)
        XCTAssertEqual(harness.appState.cachedTrips.map(\.jobId), [offlineTrip.jobId])

        let router = RecoveryBoundaryRequestRouter()
        router.enqueue(
            .savedTrips,
            outcomes: [
                .http(statusCode: 401, body: unauthorizedBody),
                .transport(.notConnectedToInternet)
            ]
        )
        router.enqueue(
            .refresh,
            outcomes: [
                .http(statusCode: 401, body: unauthorizedBody),
                .http(
                    statusCode: 200,
                    body: tokenBody(
                        userID: principalA,
                        accessToken: "recovered-access"
                    )
                )
            ]
        )
        RecoveryBoundaryURLProtocol.install(router: router)

        await latchRecovery(in: harness)
        try await harness.appState.retryServerSession(session: harness.session)

        XCTAssertEqual(harness.appState.identityPhase, .ready(isOffline: true))
        XCTAssertEqual(
            harness.appState.identityOutcome,
            .serverSessionRestored(isOffline: true)
        )
        XCTAssertEqual(harness.appState.cachedTrips.map(\.jobId), [offlineTrip.jobId])
        XCTAssertTrue(
            harness.appState.offlineCacheError?.contains("offline copy") == true
        )
    }

    func testRecoveredSessionFollowUpIdentityMismatchRaisesCurtain()
        async throws {
        let harness = try makeHarness()
        defer {
            RecoveryBoundaryURLProtocol.reset()
            harness.remove()
        }
        let router = RecoveryBoundaryRequestRouter()
        router.enqueue(
            .savedTrips,
            outcomes: [
                .http(statusCode: 401, body: unauthorizedBody),
                .http(statusCode: 401, body: unauthorizedBody)
            ]
        )
        router.enqueue(
            .refresh,
            outcomes: [
                .http(statusCode: 401, body: unauthorizedBody),
                .http(
                    statusCode: 200,
                    body: tokenBody(
                        userID: principalA,
                        accessToken: "recovered-access"
                    )
                ),
                .http(
                    statusCode: 200,
                    body: tokenBody(
                        userID: principalB,
                        accessToken: "wrong-principal-access"
                    )
                )
            ]
        )
        RecoveryBoundaryURLProtocol.install(router: router)

        await latchRecovery(in: harness)
        do {
            try await harness.appState.retryServerSession(
                session: harness.session
            )
            XCTFail("A follow-up different principal must raise the curtain.")
        } catch {
            XCTAssertEqual(error as? APIError, .identityIntegrityFailure)
        }

        guard case .blocked = harness.appState.identityPhase else {
            return XCTFail("The mismatch must finish behind a privacy curtain.")
        }
        XCTAssertNil(harness.appState.privateAppSession)
        XCTAssertNil(harness.appState.currentPrincipalScope)
        XCTAssertNil(harness.surfaces.activeSession)
        XCTAssertEqual(router.count(for: .savedTrips), 2)
        XCTAssertEqual(router.count(for: .refresh), 3)
    }

    func testStaleRetryAfterPrincipalSwitchCannotPublishReady() async throws {
        let harness = try makeHarness()
        defer {
            RecoveryBoundaryURLProtocol.reset()
            harness.remove()
        }
        let router = RecoveryBoundaryRequestRouter()
        let refreshGate = RecoveryBoundaryGate()
        router.enqueue(
            .savedTrips,
            outcomes: [.http(statusCode: 401, body: unauthorizedBody)]
        )
        router.enqueue(
            .refresh,
            outcomes: [
                .http(statusCode: 401, body: unauthorizedBody),
                .suspended(
                    gate: refreshGate,
                    statusCode: 200,
                    body: tokenBody(
                        userID: principalA,
                        accessToken: "late-a-access"
                    )
                )
            ]
        )
        RecoveryBoundaryURLProtocol.install(router: router)

        await latchRecovery(in: harness)
        let retry = Task { () -> Error? in
            do {
                try await harness.appState.retryServerSession(
                    session: harness.session
                )
                return nil
            } catch {
                return error
            }
        }
        await refreshGate.waitUntilStarted()

        let transitionEpoch = try await harness.coordinator.beginTransition()
        let identityB = try PrincipalIdentity(serverUserID: principalB)
        let sessionB = UUID(
            uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        )!
        let leaseB = try await harness.coordinator.establish(
            identityB.scope,
            presentationSessionID: sessionB,
            at: transitionEpoch
        )
        refreshGate.release()

        let retryError = await retry.value
        XCTAssertEqual(
            retryError as? IdentityCoordinatorError,
            .staleIdentity
        )
        guard case .recoveryRequired = harness.appState.identityPhase else {
            return XCTFail("Stale A recovery must not publish Ready for B.")
        }
        let currentLease = try await harness.coordinator.currentLease()
        XCTAssertEqual(currentLease, leaseB)
        XCTAssertEqual(router.count(for: .savedTrips), 1)
        let currentCredentials = await harness.credentials
            .currentCredentials()
        let stored = try XCTUnwrap(currentCredentials)
        XCTAssertEqual(stored.accessToken, "access-a")
    }

    func testRecoveryBlocksServerMutationsAndEveryPendingQueueMutation()
        async throws {
        let harness = try makeHarness()
        defer {
            RecoveryBoundaryURLProtocol.reset()
            harness.remove()
        }
        let router = RecoveryBoundaryRequestRouter()
        router.enqueue(
            .savedTrips,
            outcomes: [.http(statusCode: 401, body: unauthorizedBody)]
        )
        router.enqueue(
            .refresh,
            outcomes: [.http(statusCode: 401, body: unauthorizedBody)]
        )
        RecoveryBoundaryURLProtocol.install(router: router)

        await latchRecovery(in: harness)
        let requestCount = router.totalCount

        do {
            try await harness.appState.deleteTrip(
                jobID: "job-must-not-delete",
                session: harness.session
            )
            XCTFail("Recovery must block a direct server mutation.")
        } catch {
            XCTAssertEqual(error as? APIError, .identityRecoveryRequired)
        }

        do {
            _ = try await harness.appState.submitItinerary(
                sampleRequest,
                title: "Must not queue",
                session: harness.session
            )
            XCTFail("Recovery must block submission before local enqueue.")
        } catch {
            XCTAssertEqual(error as? APIError, .identityRecoveryRequired)
        }

        await harness.appState.registerPending(
            jobID: "job-must-not-queue",
            title: "Must not queue",
            session: harness.session
        )
        await harness.appState.resolvePending(
            jobID: "job-must-not-queue",
            session: harness.session
        )
        await harness.appState.resumePendingSubmissions(
            session: harness.session
        )

        XCTAssertEqual(router.totalCount, requestCount)
        let submissions = try await harness.stores.pendingSubmissionStore.all()
        let jobs = try await harness.stores.pendingJobStore.all()
        XCTAssertTrue(submissions.isEmpty)
        XCTAssertTrue(jobs.isEmpty)
        XCTAssertTrue(harness.appState.pendingJobs.isEmpty)
        assertRecoveryRequired(harness.appState)
    }

    func testClearDownloadsWhileRecoveryRequiredCarriesPauseToFreshSession()
        async throws {
        let recoveryRefreshGate = RecoveryBoundaryGate()
        let harness = try makeHarness()
        defer {
            recoveryRefreshGate.release()
            RecoveryBoundaryURLProtocol.reset()
            harness.remove()
        }
        let router = RecoveryBoundaryRequestRouter()
        router.enqueue(
            .savedTrips,
            outcomes: [
                .http(statusCode: 401, body: unauthorizedBody),
                .http(statusCode: 200, body: Data("[]".utf8))
            ]
        )
        router.enqueue(
            .refresh,
            outcomes: [
                .http(statusCode: 401, body: unauthorizedBody),
                .suspended(
                    gate: recoveryRefreshGate,
                    statusCode: 200,
                    body: tokenBody(
                        userID: principalA,
                        accessToken: "post-clear-recovered-access"
                    )
                )
            ]
        )
        RecoveryBoundaryURLProtocol.install(router: router)

        await latchRecovery(in: harness)
        try await harness.appState.clearDownloadedTripData(
            session: harness.session
        )

        let replacementSession = try XCTUnwrap(
            harness.appState.privateAppSession
        )
        XCTAssertNotEqual(replacementSession, harness.session)
        XCTAssertEqual(
            replacementSession.lease.scope,
            harness.session.lease.scope
        )
        assertRecoveryRequired(harness.appState)
        XCTAssertEqual(harness.appState.identityOutcome, .downloadsCleared)
        do {
            _ = try await harness.coordinator.captureServerOperationLease(
                ifCurrent: replacementSession.lease
            )
            XCTFail("Clear Downloads must not mint a ready server lease.")
        } catch {
            XCTAssertEqual(
                error as? IdentityCoordinatorError,
                .serverOperationsPaused
            )
        }

        let requestCount = router.totalCount
        do {
            _ = try await harness.appState.submitItinerary(
                sampleRequest,
                title: "Must remain paused",
                session: replacementSession
            )
            XCTFail("The replacement session must remain recovery-gated.")
        } catch {
            XCTAssertEqual(error as? APIError, .identityRecoveryRequired)
        }
        do {
            try await harness.appState.deleteTrip(
                jobID: "must-not-delete",
                session: replacementSession
            )
            XCTFail("A direct mutation must remain recovery-gated.")
        } catch {
            XCTAssertEqual(error as? APIError, .identityRecoveryRequired)
        }
        XCTAssertEqual(router.totalCount, requestCount)
        let submissions = try await harness.stores.pendingSubmissionStore.all()
        XCTAssertTrue(submissions.isEmpty)

        let retry = Task {
            try await harness.appState.retryServerSession(
                session: replacementSession
            )
        }
        await recoveryRefreshGate.waitUntilStarted()
        assertRecoveryRequired(harness.appState)
        recoveryRefreshGate.release()
        try await retry.value

        XCTAssertEqual(harness.appState.identityPhase, .ready(isOffline: false))
        XCTAssertEqual(router.count(for: .refresh), 2)
        XCTAssertEqual(router.count(for: .savedTrips), 2)
    }

    func testPauseConcurrentWithClearCannotMakeReplacementReady()
        async throws {
        let storageGate = RecoveryBoundaryAsyncGate()
        let responseGate = RecoveryBoundaryGate()
        let harness = try makeHarness(
            beforeCommit: { _ in await storageGate.suspendOnce() }
        )
        defer {
            responseGate.release()
            RecoveryBoundaryURLProtocol.reset()
            Task { await storageGate.resume() }
            harness.remove()
        }
        let router = RecoveryBoundaryRequestRouter()
        router.enqueue(
            .savedTrips,
            outcomes: [
                .suspended(
                    gate: responseGate,
                    statusCode: 401,
                    body: unauthorizedBody
                )
            ]
        )
        router.enqueue(
            .refresh,
            outcomes: [.http(statusCode: 401, body: unauthorizedBody)]
        )
        RecoveryBoundaryURLProtocol.install(router: router)

        let request = Task { () -> Error? in
            do {
                let _: IdentityScopedValue<[SavedItinerary]> = try await
                    harness.appState.scopedAPIValue(session: harness.session) {
                        try await $0.savedItineraries()
                    }
                return nil
            } catch {
                return error
            }
        }
        await responseGate.waitUntilStarted()

        let clear = Task { () -> Error? in
            do {
                try await harness.appState.clearDownloadedTripData(
                    session: harness.session
                )
                return nil
            } catch {
                return error
            }
        }
        await storageGate.waitUntilSuspended()
        responseGate.release()
        let requestError = await request.value
        XCTAssertEqual(
            requestError as? APIError,
            .identityRecoveryRequired
        )
        XCTAssertEqual(harness.appState.identityPhase, .clearingDownloads)

        await storageGate.resume()
        let clearError = await clear.value
        XCTAssertNil(clearError)
        let replacementSession = try XCTUnwrap(
            harness.appState.privateAppSession
        )
        assertRecoveryRequired(harness.appState)

        let requestCount = router.totalCount
        do {
            _ = try await harness.appState.submitItinerary(
                sampleRequest,
                title: "Concurrent pause",
                session: replacementSession
            )
            XCTFail("The concurrent pause must survive actor replacement.")
        } catch {
            XCTAssertEqual(error as? APIError, .identityRecoveryRequired)
        }
        XCTAssertEqual(router.totalCount, requestCount)
        let submissions = try await harness.stores.pendingSubmissionStore.all()
        XCTAssertTrue(submissions.isEmpty)
    }

    func testAPIClientPausesBeforeAppStateHandlerAndSecondSubmitCannotCommit()
        async throws {
        let recoveryReturnGate = RecoveryBoundaryAsyncGate()
        let harness = try makeHarness(
            beforeReturningIdentityRecoveryRequired: {
                await recoveryReturnGate.suspendOnce()
            }
        )
        defer {
            RecoveryBoundaryURLProtocol.reset()
            Task { await recoveryReturnGate.resume() }
            harness.remove()
        }
        let router = RecoveryBoundaryRequestRouter()
        router.enqueue(
            .savedTrips,
            outcomes: [.http(statusCode: 401, body: unauthorizedBody)]
        )
        router.enqueue(
            .refresh,
            outcomes: [.http(statusCode: 401, body: unauthorizedBody)]
        )
        RecoveryBoundaryURLProtocol.install(router: router)

        let firstRequest = Task { () -> Error? in
            do {
                let _: IdentityScopedValue<[SavedItinerary]> = try await
                    harness.appState.scopedAPIValue(session: harness.session) {
                        try await $0.savedItineraries()
                    }
                return nil
            } catch {
                return error
            }
        }
        await recoveryReturnGate.waitUntilSuspended()

        XCTAssertEqual(
            harness.appState.identityPhase,
            .ready(isOffline: false),
            "The test gate is before AppState receives the recovery error."
        )
        let requestCount = router.totalCount
        do {
            _ = try await harness.appState.submitItinerary(
                sampleRequest,
                title: "Must not enter retry storage",
                session: harness.session
            )
            XCTFail("A second submit cannot cross the coordinator pause.")
        } catch {
            XCTAssertEqual(
                error as? IdentityCoordinatorError,
                .serverOperationsPaused
            )
        }
        XCTAssertEqual(router.totalCount, requestCount)
        let submissions = try await harness.stores.pendingSubmissionStore.all()
        XCTAssertTrue(submissions.isEmpty)

        await recoveryReturnGate.resume()
        let firstRequestError = await firstRequest.value
        XCTAssertEqual(
            firstRequestError as? APIError,
            .identityRecoveryRequired
        )
        assertRecoveryRequired(harness.appState)
    }

    func testMissingCredentialsPauseBeforeHandlerAndSendNoRequestOrQueueWrite()
        async throws {
        let recoveryReturnGate = RecoveryBoundaryAsyncGate()
        let harness = try makeHarness(
            beforeReturningIdentityRecoveryRequired: {
                await recoveryReturnGate.suspendOnce()
            }
        )
        defer {
            RecoveryBoundaryURLProtocol.reset()
            Task { await recoveryReturnGate.resume() }
            harness.remove()
        }
        let router = RecoveryBoundaryRequestRouter()
        RecoveryBoundaryURLProtocol.install(router: router)
        await harness.credentials.replace(with: nil)

        let firstRequest = Task { () -> Error? in
            do {
                let _: IdentityScopedValue<[SavedItinerary]> = try await
                    harness.appState.scopedAPIValue(session: harness.session) {
                        try await $0.savedItineraries()
                    }
                return nil
            } catch {
                return error
            }
        }
        await recoveryReturnGate.waitUntilSuspended()

        XCTAssertEqual(harness.appState.identityPhase, .ready(isOffline: false))
        do {
            _ = try await harness.appState.submitItinerary(
                sampleRequest,
                title: "No credentials",
                session: harness.session
            )
            XCTFail("A missing credential must pause before local enqueue.")
        } catch {
            XCTAssertEqual(
                error as? IdentityCoordinatorError,
                .serverOperationsPaused
            )
        }
        XCTAssertEqual(router.totalCount, 0)
        let submissions = try await harness.stores.pendingSubmissionStore.all()
        XCTAssertTrue(submissions.isEmpty)

        await recoveryReturnGate.resume()
        let firstRequestError = await firstRequest.value
        XCTAssertEqual(
            firstRequestError as? APIError,
            .identityRecoveryRequired
        )
        assertRecoveryRequired(harness.appState)
    }

    func testMismatchedStoredCredentialRetryRaisesVerifiedPrivacyCurtain()
        async throws {
        let harness = try makeHarness()
        defer {
            RecoveryBoundaryURLProtocol.reset()
            harness.remove()
        }
        let router = RecoveryBoundaryRequestRouter()
        router.enqueue(
            .savedTrips,
            outcomes: [.http(statusCode: 401, body: unauthorizedBody)]
        )
        router.enqueue(
            .refresh,
            outcomes: [.http(statusCode: 401, body: unauthorizedBody)]
        )
        RecoveryBoundaryURLProtocol.install(router: router)

        await latchRecovery(in: harness)
        await harness.credentials.replace(
            with: credentials(userID: principalB, accessToken: "access-b")
        )
        let requestCount = router.totalCount

        do {
            try await harness.appState.retryServerSession(
                session: harness.session
            )
            XCTFail("A different stored principal must raise the curtain.")
        } catch {
            XCTAssertEqual(error as? APIError, .identityIntegrityFailure)
        }

        guard case .blocked = harness.appState.identityPhase else {
            return XCTFail("An integrity failure must end behind a curtain.")
        }
        XCTAssertNil(harness.appState.privateAppSession)
        XCTAssertNil(harness.appState.currentPrincipalScope)
        XCTAssertTrue(harness.appState.cachedTrips.isEmpty)
        XCTAssertTrue(harness.appState.pendingJobs.isEmpty)
        XCTAssertNil(harness.surfaces.activeSession)
        XCTAssertGreaterThanOrEqual(harness.surfaces.tearDownCount, 1)
        XCTAssertEqual(router.totalCount, requestCount)
        do {
            _ = try await harness.coordinator.currentLease()
            XCTFail("The coordinator cannot remain established.")
        } catch {
            XCTAssertEqual(
                error as? IdentityCoordinatorError,
                .identityNotEstablished
            )
        }
    }

    func testIntegrityFailurePreemptsSuspendedCleanupAndCannotReopenLibrary()
        async throws {
        let cleanupGate = RecoveryBoundaryAsyncGate()
        let privateRequestGate = RecoveryBoundaryGate()
        let harness = try makeHarness(
            beforeCommit: { _ in
                await cleanupGate.suspendOnce()
            }
        )
        defer {
            RecoveryBoundaryURLProtocol.reset()
            Task { await cleanupGate.resume() }
            harness.remove()
        }
        let router = RecoveryBoundaryRequestRouter()
        router.enqueue(
            .savedTrips,
            outcomes: [
                .suspended(
                    gate: privateRequestGate,
                    statusCode: 401,
                    body: unauthorizedBody
                )
            ]
        )
        router.enqueue(
            .refresh,
            outcomes: [
                .http(
                    statusCode: 200,
                    body: tokenBody(
                        userID: principalB,
                        accessToken: "wrong-principal-access"
                    )
                )
            ]
        )
        RecoveryBoundaryURLProtocol.install(router: router)

        let privateRequest = Task { () -> Error? in
            do {
                let _: IdentityScopedValue<[SavedItinerary]> = try await harness
                    .appState.scopedAPIValue(session: harness.session) {
                        try await $0.savedItineraries()
                    }
                return nil
            } catch {
                return error
            }
        }
        await privateRequestGate.waitUntilStarted()

        let cleanup = Task { () -> Error? in
            do {
                try await harness.appState.clearDownloadedTripData(
                    session: harness.session
                )
                return nil
            } catch {
                return error
            }
        }
        await cleanupGate.waitUntilSuspended()

        privateRequestGate.release()
        let privateError = await privateRequest.value
        XCTAssertEqual(privateError as? APIError, .identityIntegrityFailure)
        guard case .blocked = harness.appState.identityPhase else {
            await cleanupGate.resume()
            _ = await cleanup.value
            return XCTFail("Integrity must immediately raise the curtain.")
        }

        await cleanupGate.resume()
        let cleanupError = await cleanup.value
        XCTAssertEqual(
            cleanupError as? IdentityCoordinatorError,
            .staleIdentity
        )
        guard case .blocked = harness.appState.identityPhase else {
            return XCTFail("Suspended cleanup must not reopen the library.")
        }
        XCTAssertNil(harness.appState.privateAppSession)
        XCTAssertNil(harness.appState.currentPrincipalScope)
        XCTAssertNil(harness.surfaces.activeSession)
        XCTAssertEqual(harness.surfaces.establishCount, 0)
        XCTAssertGreaterThanOrEqual(harness.surfaces.tearDownCount, 1)
    }

    private struct Harness {
        let appState: AppState
        let coordinator: IdentityCoordinator
        let credentials: RecoveryBoundaryCredentialStore
        let stores: PrincipalStoreSet
        let surfaces: RecoveryBoundarySurfaceSpy
        let session: PrivateAppSession
        let root: URL
        let defaults: UserDefaults
        let suiteName: String

        func remove() {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func makeHarness(
        beforeCommit: PrincipalStorageBeforeCommit? = nil,
        beforeServerRecoveryResume: (@Sendable () async -> Void)? = nil,
        beforeReturningIdentityRecoveryRequired:
            (@Sendable () async -> Void)? = nil
    ) throws -> Harness {
        let identity = try PrincipalIdentity(serverUserID: principalA)
        let sessionID = UUID(
            uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        )!
        let lease = IdentityLease(
            scope: identity.scope,
            epoch: 7,
            presentationSessionID: sessionID
        )
        let coordinator = IdentityCoordinator(
            initialScope: identity.scope,
            initialEpoch: lease.epoch,
            initialPresentationSessionID: sessionID
        )
        let suiteName = "AppStateRecoveryBoundaryTests.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appending(
            path: suiteName,
            directoryHint: .isDirectory
        )
        let defaults = UserDefaults(suiteName: suiteName)!
        let factory = PrincipalStorageFactory(
            applicationSupportDirectory: root,
            identityCoordinator: coordinator,
            beforeCommit: beforeCommit
        )
        let defaultsDomain = try PrivateStorageDefaultsDomain(
            suiteName: suiteName
        )
        let stores = factory.makeStoreSet(
            for: lease,
            defaultsDomain: defaultsDomain
        )
        let credentials = RecoveryBoundaryCredentialStore(
            credentials: credentials(
                userID: principalA,
                accessToken: "access-a"
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryBoundaryURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(
                baseURL: URL(string: "https://recovery-boundary.test")!,
                requestTimeout: 2,
                resourceTimeout: 3
            ),
            session: URLSession(configuration: configuration),
            credentialStore: credentials,
            identityCoordinator: coordinator,
            now: { Date(timeIntervalSince1970: 2_000_000_000) },
            beforeReturningIdentityRecoveryRequired:
                beforeReturningIdentityRecoveryRequired
        )
        let surfaces = RecoveryBoundarySurfaceSpy(
            activeSession: lease.presentationSession
        )
        let appState = AppState(
            apiClient: client,
            identityCoordinator: coordinator,
            storageFactory: factory,
            defaults: defaults,
            defaultsDomain: defaultsDomain,
            surfaceCoordinator: surfaces,
            cleanupJournal: RecoveryBoundaryJournal(),
            initialStoreSet: stores,
            beforeServerRecoveryResume: beforeServerRecoveryResume
        )
        return Harness(
            appState: appState,
            coordinator: coordinator,
            credentials: credentials,
            stores: stores,
            surfaces: surfaces,
            session: PrivateAppSession(lease: lease),
            root: root,
            defaults: defaults,
            suiteName: suiteName
        )
    }

    private func latchRecovery(in harness: Harness) async {
        do {
            let _: IdentityScopedValue<[SavedItinerary]> = try await harness
                .appState.scopedAPIValue(session: harness.session) {
                    try await $0.savedItineraries()
                }
            XCTFail("The rejected refresh must pause server work.")
        } catch {
            XCTAssertEqual(error as? APIError, .identityRecoveryRequired)
        }
        assertRecoveryRequired(harness.appState)
    }

    private func assertOrdinaryReadIsBlocked(in harness: Harness) async {
        do {
            let _: IdentityScopedValue<[SavedItinerary]> = try await harness
                .appState.scopedAPIValue(session: harness.session) {
                    try await $0.savedItineraries()
                }
            XCTFail("Ordinary work cannot bypass recovery.")
        } catch {
            XCTAssertEqual(error as? APIError, .identityRecoveryRequired)
        }
    }

    private func assertRecoveryRequired(
        _ appState: AppState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .recoveryRequired = appState.identityPhase else {
            return XCTFail(
                "Expected an exact-session recovery state.",
                file: file,
                line: line
            )
        }
        XCTAssertNotNil(appState.privateAppSession, file: file, line: line)
        XCTAssertNotNil(appState.currentPrincipalScope, file: file, line: line)
    }

    private func credentials(
        userID: String,
        accessToken: String
    ) -> AuthCredentials {
        AuthCredentials(
            accessToken: accessToken,
            refreshToken: "refresh-\(accessToken)",
            tokenType: "Bearer",
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
            userID: userID
        )
    }

    private func tokenBody(userID: String, accessToken: String) -> Data {
        Data(
            """
            {
              "user_id": "\(userID)",
              "access_token": "\(accessToken)",
              "refresh_token": "refresh-\(accessToken)",
              "token_type": "Bearer",
              "expires_in": 3600
            }
            """.utf8
        )
    }

    private var sampleRequest: GenerateItineraryRequest {
        GenerateItineraryRequest(
            city: "Lisbon",
            country: "Portugal",
            accommodation: Accommodation(
                address: "1 Safe Street",
                lat: 38.72,
                lng: -9.14
            ),
            arrivalDate: "2026-09-01",
            departureDate: "2026-09-03",
            groupSize: 1,
            wakeUpTime: "08:00",
            budget: "Moderate"
        )
    }

    private var savedOfflineTrip: SavedItinerary {
        SavedItinerary(
            jobId: "offline-job",
            status: .succeeded,
            title: "Offline Lisbon",
            sourcePublicItineraryId: nil,
            city: "Lisbon",
            country: "Portugal",
            arrivalDate: "2026-09-01",
            departureDate: "2026-09-03",
            result: Itinerary(
                itinerary: [
                    ItineraryDay(
                        day: 1,
                        theme: "Old Lisbon",
                        activities: [
                            Activity(
                                time: "09:00",
                                name: "Alfama Walk",
                                type: "sightseeing",
                                duration: "1 hour",
                                description: "A saved offline stop.",
                                address: "Lisbon, Portugal",
                                coordinates: Coordinates(
                                    lat: 38.71,
                                    lng: -9.13
                                )
                            )
                        ]
                    )
                ],
                tips: [],
                accommodationInfo: AccommodationInfo(
                    morningStart: "09:00",
                    eveningReturn: "18:00",
                    transportationTips: "Walk"
                ),
                estimatedBudget: "€100"
            ),
            error: nil,
            createdAt: "2026-01-01T00:00:00Z"
        )
    }

    private var unauthorizedBody: Data {
        Data(#"{"detail":"expired"}"#.utf8)
    }

    private var principalA: String {
        "aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb"
    }

    private var principalB: String {
        "bbbbbbbb-1111-4222-8333-cccccccccccc"
    }
}

private actor RecoveryBoundaryJournal: PrivateCleanupJournalStoring {
    func load() -> PrivateCleanupPlan? { nil }
    func save(_ plan: PrivateCleanupPlan) {}
    func clear() {}
}

private actor RecoveryBoundaryCredentialStore: CredentialStoring {
    private var credentials: AuthCredentials?

    init(credentials: AuthCredentials?) {
        self.credentials = credentials
    }

    func loadCredentials() -> AuthCredentials? { credentials }

    func saveCredentials(_ credentials: AuthCredentials) {
        self.credentials = credentials
    }

    func clearCredentials() {
        credentials = nil
    }

    func installationIdentifier() -> String {
        "recovery-boundary-installation"
    }

    func replace(with credentials: AuthCredentials?) {
        self.credentials = credentials
    }

    func currentCredentials() -> AuthCredentials? { credentials }
}

@MainActor
private final class RecoveryBoundarySurfaceSpy: PrivateSurfaceCoordinating {
    private(set) var activeSession: PrivatePresentationSession?
    private(set) var establishCount = 0
    private(set) var tearDownCount = 0

    init(activeSession: PrivatePresentationSession?) {
        self.activeSession = activeSession
    }

    func establish(session: PrivatePresentationSession) async throws {
        establishCount += 1
        activeSession = session
    }

    func tearDown() async throws {
        tearDownCount += 1
        activeSession = nil
    }

    func isCurrent(_ session: PrivatePresentationSession) -> Bool {
        activeSession == session
    }
}

private actor RecoveryBoundaryAsyncGate {
    private var shouldSuspend = true
    private var suspended = false
    private var suspensionContinuation: CheckedContinuation<Void, Never>?
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func suspendOnce() async {
        guard shouldSuspend else { return }
        shouldSuspend = false
        suspended = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            suspensionContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func resume() {
        suspended = false
        suspensionContinuation?.resume()
        suspensionContinuation = nil
    }
}

private struct RecoveryBoundaryRequestKey: Hashable, Sendable {
    let method: String
    let path: String

    static let savedTrips = Self(
        method: "GET",
        path: "/api/v1/itineraries"
    )
    static let refresh = Self(
        method: "POST",
        path: "/api/v1/auth/refresh"
    )
}

private enum RecoveryBoundaryOutcome: @unchecked Sendable {
    case http(statusCode: Int, body: Data)
    case transport(URLError.Code)
    case suspended(
        gate: RecoveryBoundaryGate,
        statusCode: Int,
        body: Data
    )
}

private enum RecoveryBoundaryTestError: Error {
    case unexpectedRequest(RecoveryBoundaryRequestKey)
}

private final class RecoveryBoundaryRequestRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [RecoveryBoundaryRequestKey: [RecoveryBoundaryOutcome]]
        = [:]
    private var requests: [RecoveryBoundaryRequestKey] = []

    var totalCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    func enqueue(
        _ key: RecoveryBoundaryRequestKey,
        outcomes newOutcomes: [RecoveryBoundaryOutcome]
    ) {
        lock.lock()
        outcomes[key, default: []].append(contentsOf: newOutcomes)
        lock.unlock()
    }

    func count(for key: RecoveryBoundaryRequestKey) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter { $0 == key }.count
    }

    func response(for request: URLRequest)
        throws -> RecoveryBoundaryURLProtocol.Response {
        let key = RecoveryBoundaryRequestKey(
            method: request.httpMethod ?? "GET",
            path: request.url?.path ?? ""
        )
        let outcome: RecoveryBoundaryOutcome
        lock.lock()
        requests.append(key)
        if var queued = outcomes[key], !queued.isEmpty {
            outcome = queued.removeFirst()
            outcomes[key] = queued
            lock.unlock()
        } else {
            lock.unlock()
            throw RecoveryBoundaryTestError.unexpectedRequest(key)
        }

        switch outcome {
        case .http(let statusCode, let body):
            return .init(statusCode: statusCode, data: body)
        case .transport(let code):
            throw URLError(code)
        case .suspended(let gate, let statusCode, let body):
            return .init(
                statusCode: statusCode,
                data: body,
                deliveryGate: gate
            )
        }
    }
}

private final class RecoveryBoundaryGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if started {
                lock.unlock()
                continuation.resume()
            } else {
                startWaiter = continuation
                lock.unlock()
            }
        }
    }

    func blockUntilReleased() {
        lock.lock()
        started = true
        let waiter = startWaiter
        startWaiter = nil
        lock.unlock()
        waiter?.resume()
        releaseSemaphore.wait()
    }

    func release() {
        releaseSemaphore.signal()
    }
}

private final class RecoveryBoundaryURLProtocol: URLProtocol {
    struct Response: Sendable {
        let statusCode: Int
        let data: Data
        let deliveryGate: RecoveryBoundaryGate?

        init(
            statusCode: Int,
            data: Data,
            deliveryGate: RecoveryBoundaryGate? = nil
        ) {
            self.statusCode = statusCode
            self.data = data
            self.deliveryGate = deliveryGate
        }
    }

    private static let storage = RecoveryBoundaryRouterStorage()

    static func install(router: RecoveryBoundaryRequestRouter) {
        storage.set(router)
    }

    static func reset() {
        storage.set(nil)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let router = Self.storage.get() else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        do {
            let stub = try router.response(for: request)
            if let deliveryGate = stub.deliveryGate {
                let protocolReference = RecoveryBoundaryURLProtocolReference(
                    self
                )
                DispatchQueue.global(qos: .userInitiated).async {
                    deliveryGate.blockUntilReleased()
                    protocolReference.value?.deliver(stub)
                }
            } else {
                deliver(stub)
            }
        } catch {
            fail(error)
        }
    }

    override func stopLoading() {}

    private func deliver(_ stub: Response) {
        let response = HTTPURLResponse(
            url: request.url!,
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
    }

    private func fail(_ error: Error) {
        client?.urlProtocol(self, didFailWithError: error)
    }
}

private final class RecoveryBoundaryURLProtocolReference:
    @unchecked Sendable {
    weak var value: RecoveryBoundaryURLProtocol?

    init(_ value: RecoveryBoundaryURLProtocol) {
        self.value = value
    }
}

private final class RecoveryBoundaryRouterStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var router: RecoveryBoundaryRequestRouter?

    func set(_ router: RecoveryBoundaryRequestRouter?) {
        lock.lock()
        self.router = router
        lock.unlock()
    }

    func get() -> RecoveryBoundaryRequestRouter? {
        lock.lock()
        defer { lock.unlock() }
        return router
    }
}
