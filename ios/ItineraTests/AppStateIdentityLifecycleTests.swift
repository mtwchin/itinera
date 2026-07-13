import Foundation
import XCTest
@testable import Itinera

@MainActor
final class AppStateIdentityLifecycleTests: XCTestCase {
    func testPermanentInvalidationRejectsLateEstablishAtExhaustedEpoch()
        async throws {
        let sessionID = UUID(
            uuidString: "77777777-7777-4777-8777-777777777777"
        )!
        let coordinator = IdentityCoordinator(
            initialScope: establishedIdentity.scope,
            initialEpoch: .max,
            initialPresentationSessionID: sessionID
        )

        await coordinator.invalidateCurrent()

        do {
            _ = try await coordinator.establish(
                establishedIdentity.scope,
                presentationSessionID: UUID(),
                at: .max
            )
            XCTFail("A terminal invalidation must reject late establishment.")
        } catch {
            XCTAssertEqual(error as? IdentityCoordinatorError, .staleIdentity)
        }
        do {
            _ = try await coordinator.beginTransition()
            XCTFail("A terminal invalidation must never advance again.")
        } catch {
            XCTAssertEqual(error as? IdentityCoordinatorError, .epochExhausted)
        }
        do {
            _ = try await coordinator.currentLease()
            XCTFail("A terminal invalidation cannot retain a current lease.")
        } catch {
            XCTAssertEqual(
                error as? IdentityCoordinatorError,
                .identityNotEstablished
            )
        }
    }

    func testDeleteEpochExhaustionAfterJournalRequiresDeletionRetry()
        async throws {
        let environment = makeEnvironment()
        defer { environment.remove() }
        let events = IdentityLifecycleEventLog()
        let journal = IdentityLifecycleJournal(events: events)
        let credentials = IdentityLifecycleCredentialStore(
            credentials: establishedCredentials,
            events: events
        )
        let harness = try makeReadyHarness(
            environment: environment,
            journal: journal,
            credentials: credentials,
            events: events,
            initialEpoch: .max
        )

        do {
            try await harness.appState.deleteMyData(session: harness.session)
            XCTFail("An exhausted epoch must stop before server deletion.")
        } catch {
            XCTAssertEqual(error as? IdentityCoordinatorError, .epochExhausted)
        }

        let retainedPlan = await journal.currentPlan()
        XCTAssertEqual(retainedPlan?.intent, .delete)
        XCTAssertEqual(retainedPlan?.stage, .serverDeletionPending)
        guard case .cleanupRequired(let intent, let stage, _) =
                harness.appState.identityPhase else {
            return XCTFail("The durable deletion must be resumable.")
        }
        XCTAssertEqual(intent, .delete)
        XCTAssertEqual(stage, .serverDeletionPending)
        XCTAssertGreaterThanOrEqual(harness.surfaces.tearDownCount, 1)
        XCTAssertFalse(events.snapshot().contains("network.delete"))
        assertPrivacyCurtain(harness.appState)
    }

    func testSignOutEpochExhaustionAfterJournalRequiresCleanupRetry()
        async throws {
        let environment = makeEnvironment()
        defer { environment.remove() }
        let events = IdentityLifecycleEventLog()
        let journal = IdentityLifecycleJournal(events: events)
        let credentials = IdentityLifecycleCredentialStore(
            credentials: establishedCredentials,
            events: events
        )
        let harness = try makeReadyHarness(
            environment: environment,
            journal: journal,
            credentials: credentials,
            events: events,
            initialEpoch: .max
        )

        do {
            try await harness.appState.signOut(session: harness.session)
            XCTFail("An exhausted epoch must retain sign-out cleanup.")
        } catch {
            XCTAssertEqual(error as? IdentityCoordinatorError, .epochExhausted)
        }

        let retainedPlan = await journal.currentPlan()
        XCTAssertEqual(retainedPlan?.intent, .signOut)
        XCTAssertEqual(retainedPlan?.stage, .localCleanup)
        guard case .cleanupRequired(let intent, let stage, _) =
                harness.appState.identityPhase else {
            return XCTFail("The durable sign-out must be resumable.")
        }
        XCTAssertEqual(intent, .signOut)
        XCTAssertEqual(stage, .localCleanup)
        XCTAssertGreaterThanOrEqual(harness.surfaces.tearDownCount, 1)
        XCTAssertFalse(events.snapshot().contains("network.guest"))
        assertPrivacyCurtain(harness.appState)
    }

    func testRelaunchEpochExhaustionRestoresDurableCleanupRequiredState()
        async throws {
        let environment = makeEnvironment()
        defer { environment.remove() }
        let events = IdentityLifecycleEventLog()
        let plan = PrivateCleanupPlan(
            operationID: fixedOperationID,
            intent: .delete,
            stage: .serverDeletionPending,
            scope: establishedIdentity.scope
        )
        let journal = IdentityLifecycleJournal(plan: plan, events: events)
        let credentials = IdentityLifecycleCredentialStore(
            credentials: establishedCredentials,
            events: events
        )
        let appState = makeRelaunchAppState(
            environment: environment,
            journal: journal,
            credentials: credentials,
            events: events,
            initialEpoch: .max
        )

        await appState.bootstrapIdentity()

        guard case .cleanupRequired(let intent, let stage, _) =
                appState.identityPhase else {
            return XCTFail("Relaunch must expose the retained deletion retry.")
        }
        XCTAssertEqual(intent, .delete)
        XCTAssertEqual(stage, .serverDeletionPending)
        let retainedPlan = await journal.currentPlan()
        XCTAssertEqual(retainedPlan, plan)
        XCTAssertFalse(events.snapshot().contains("network.delete"))
        XCTAssertFalse(events.snapshot().contains("network.guest"))
        assertPrivacyCurtain(appState)
    }

    func testDeleteJournalsBeforeTransportAndFailureKeepsServerPlan()
        async throws {
        let environment = makeEnvironment()
        defer { environment.remove() }
        let events = IdentityLifecycleEventLog()
        let journal = IdentityLifecycleJournal(events: events)
        let credentials = IdentityLifecycleCredentialStore(
            credentials: establishedCredentials,
            events: events
        )
        let harness = try makeReadyHarness(
            environment: environment,
            journal: journal,
            credentials: credentials,
            events: events
        )
        IdentityLifecycleURLProtocolStub.setHandler { request in
            guard request.url?.path == "/api/v1/auth/me",
                  request.httpMethod == "DELETE" else {
                throw IdentityLifecycleTestError.unexpectedRequest
            }
            events.record("network.delete")
            throw URLError(.notConnectedToInternet)
        }
        defer { IdentityLifecycleURLProtocolStub.reset() }

        do {
            try await harness.appState.deleteMyData(
                session: harness.session
            )
            XCTFail("A transport failure must retain the deletion journal.")
        } catch let error as APIError {
            guard case .transport = error else {
                return XCTFail("Unexpected API error: \(error)")
            }
        }

        let recordedEvents = events.snapshot()
        let retainedPlan = await journal.currentPlan()
        let saveAttempts = await journal.savedPlans()
        let clearAttempts = await journal.clearAttemptCount()
        let retainedCredentials = await credentials.currentCredentials()
        XCTAssertLessThan(
            try XCTUnwrap(
                recordedEvents.firstIndex(
                    of: "journal.save.serverDeletionPending"
                )
            ),
            try XCTUnwrap(recordedEvents.firstIndex(of: "network.delete"))
        )
        XCTAssertLessThan(
            try XCTUnwrap(recordedEvents.firstIndex(of: "surface.teardown")),
            try XCTUnwrap(recordedEvents.firstIndex(of: "network.delete"))
        )
        XCTAssertEqual(saveAttempts.count, 1)
        XCTAssertEqual(retainedPlan, saveAttempts.first)
        XCTAssertEqual(retainedPlan?.schemaVersion, 1)
        XCTAssertEqual(retainedPlan?.intent, .delete)
        XCTAssertEqual(retainedPlan?.stage, .serverDeletionPending)
        XCTAssertEqual(retainedPlan?.scope, establishedIdentity.scope)
        XCTAssertEqual(clearAttempts, 0)
        XCTAssertEqual(
            retainedCredentials,
            establishedCredentials
        )
        assertPrivacyCurtain(harness.appState)
        XCTAssertGreaterThanOrEqual(harness.surfaces.tearDownCount, 1)
        XCTAssertNil(harness.surfaces.activeSession)
        XCTAssertFalse(recordedEvents.contains("network.guest"))
    }

    func testDeleteSurfaceTeardownFailureSendsNoServerDelete()
        async throws {
        let environment = makeEnvironment()
        defer { environment.remove() }
        let events = IdentityLifecycleEventLog()
        let journal = IdentityLifecycleJournal(events: events)
        let credentials = IdentityLifecycleCredentialStore(
            credentials: establishedCredentials,
            events: events
        )
        let harness = try makeReadyHarness(
            environment: environment,
            journal: journal,
            credentials: credentials,
            events: events,
            surfaceTearDownFailures: 1
        )
        IdentityLifecycleURLProtocolStub.setHandler { request in
            if request.url?.path == "/api/v1/auth/me" {
                events.record("network.delete")
            }
            throw IdentityLifecycleTestError.unexpectedRequest
        }
        defer { IdentityLifecycleURLProtocolStub.reset() }

        do {
            try await harness.appState.deleteMyData(session: harness.session)
            XCTFail("Deletion cannot reach the server before surface teardown.")
        } catch {
            XCTAssertEqual(
                error as? IdentityLifecycleTestError,
                .surfaceTearDownFailed
            )
        }

        XCTAssertFalse(events.snapshot().contains("network.delete"))
        let retainedPlan = await journal.currentPlan()
        XCTAssertEqual(retainedPlan?.intent, .delete)
        XCTAssertEqual(retainedPlan?.stage, .serverDeletionPending)
        assertPrivacyCurtain(harness.appState)
    }

    func testRejectedDeletionSessionRequiresReverificationWithoutRetryLoop()
        async throws {
        let environment = makeEnvironment()
        defer { environment.remove() }
        let events = IdentityLifecycleEventLog()
        let journal = IdentityLifecycleJournal(events: events)
        let credentials = IdentityLifecycleCredentialStore(
            credentials: establishedCredentials,
            events: events
        )
        let harness = try makeReadyHarness(
            environment: environment,
            journal: journal,
            credentials: credentials,
            events: events
        )
        IdentityLifecycleURLProtocolStub.setHandler { request in
            switch (request.httpMethod, request.url?.path) {
            case ("DELETE", "/api/v1/auth/me"):
                events.record("network.delete")
                return .init(
                    statusCode: 401,
                    data: Data(#"{"detail":"expired"}"#.utf8)
                )
            case ("POST", "/api/v1/auth/refresh"):
                events.record("network.refresh.rejected")
                return .init(
                    statusCode: 401,
                    data: Data(#"{"detail":"revoked"}"#.utf8)
                )
            default:
                throw IdentityLifecycleTestError.unexpectedRequest
            }
        }
        defer { IdentityLifecycleURLProtocolStub.reset() }

        do {
            try await harness.appState.deleteMyData(session: harness.session)
            XCTFail("Rejected credentials cannot be presented as connectivity.")
        } catch {
            XCTAssertEqual(error as? APIError, .identityRecoveryRequired)
        }

        guard case .cleanupBlocked(let intent, let stage, let message) =
                harness.appState.identityPhase else {
            return XCTFail("Deletion must require account re-verification.")
        }
        XCTAssertEqual(intent, .delete)
        XCTAssertEqual(stage, .serverDeletionPending)
        XCTAssertTrue(message.contains("Account re-verification"))
        XCTAssertTrue(message.contains("contact Itinera support"))
        XCTAssertFalse(harness.appState.canRetryIdentityBootstrap)
        XCTAssertFalse(events.snapshot().contains("network.guest"))
        let retainedPlan = await journal.currentPlan()
        XCTAssertEqual(retainedPlan?.stage, .serverDeletionPending)
        assertPrivacyCurtain(harness.appState)
    }

    func testIntegrityFailurePreemptsSuspendedJournaledDeleteBeforeReopen()
        async throws {
        let environment = makeEnvironment()
        defer { environment.remove() }
        let events = IdentityLifecycleEventLog()
        let journal = IdentityLifecycleJournal(
            suspendNextServerDeletionSave: true,
            events: events
        )
        let credentials = IdentityLifecycleCredentialStore(
            credentials: establishedCredentials,
            events: events
        )
        let harness = try makeReadyHarness(
            environment: environment,
            journal: journal,
            credentials: credentials,
            events: events
        )
        let releasePrivateResponse = DispatchSemaphore(value: 0)
        let guestUserID = guestUserID
        IdentityLifecycleURLProtocolStub.setHandler { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/v1/itineraries"):
                events.record("network.private.started")
                _ = releasePrivateResponse.wait(timeout: .now() + 5)
                return .init(
                    statusCode: 401,
                    data: Data(#"{"detail":"refresh"}"#.utf8)
                )
            case ("POST", "/api/v1/auth/refresh"):
                events.record("network.refresh.mismatched")
                return .init(
                    statusCode: 200,
                    data: Data(
                        """
                        {
                          "user_id": "dddddddd-1111-4222-8333-eeeeeeeeeeee",
                          "access_token": "wrong-access",
                          "refresh_token": "wrong-refresh",
                          "token_type": "Bearer",
                          "expires_in": 3600
                        }
                        """.utf8
                    )
                )
            case ("DELETE", "/api/v1/auth/me"):
                events.record("network.delete")
                return .init(statusCode: 204, data: Data())
            case ("POST", "/api/v1/auth/guest"):
                events.record("network.guest")
                return .init(
                    statusCode: 200,
                    data: Data(
                        """
                        {
                          "user_id": "\(guestUserID)",
                          "access_token": "guest-access",
                          "refresh_token": "guest-refresh",
                          "token_type": "Bearer",
                          "expires_in": 3600
                        }
                        """.utf8
                    )
                )
            default:
                throw IdentityLifecycleTestError.unexpectedRequest
            }
        }
        defer {
            releasePrivateResponse.signal()
            IdentityLifecycleURLProtocolStub.reset()
        }

        let privateRequest = Task { () -> Error? in
            do {
                _ = try await harness.appState.scopedAPIValue(
                    session: harness.session
                ) {
                    try await $0.savedItineraries()
                }
                return nil
            } catch {
                return error
            }
        }
        try await waitForEvent("network.private.started", events: events)

        let deletion = Task { () -> Error? in
            do {
                try await harness.appState.deleteMyData(
                    session: harness.session
                )
                return nil
            } catch {
                return error
            }
        }
        try await waitForEvent(
            "journal.save.serverDeletionPending.suspended",
            events: events
        )

        releasePrivateResponse.signal()
        let privateError = await privateRequest.value
        XCTAssertEqual(
            privateError as? APIError,
            .identityIntegrityFailure
        )

        await journal.resumeSuspendedSave()
        let deletionError = await deletion.value
        XCTAssertEqual(
            deletionError as? IdentityCoordinatorError,
            .staleIdentity
        )

        XCTAssertEqual(
            events.snapshot().filter { $0 == "network.delete" }.count,
            0
        )
        XCTAssertEqual(
            events.snapshot().filter { $0 == "network.guest" }.count,
            0
        )
        XCTAssertNil(harness.appState.identityOutcome)
        assertPrivacyCurtain(harness.appState)
        let retainedPlan = await journal.currentPlan()
        XCTAssertEqual(retainedPlan?.intent, .delete)
        XCTAssertEqual(retainedPlan?.stage, .serverDeletionPending)
    }

    func testRelaunchResumesSignOutBeforeGuestAndSkipsDeleteAndQuarantine()
        async throws {
        let environment = makeEnvironment()
        defer { environment.remove() }
        let events = IdentityLifecycleEventLog()
        let signOutPlan = PrivateCleanupPlan(
            operationID: fixedOperationID,
            intent: .signOut,
            stage: .localCleanup,
            scope: establishedIdentity.scope
        )
        let journal = IdentityLifecycleJournal(
            plan: signOutPlan,
            events: events
        )
        let credentials = IdentityLifecycleCredentialStore(
            credentials: establishedCredentials,
            events: events
        )
        let legacyURL = environment.root
            .appending(path: "Itinera", directoryHint: .isDirectory)
            .appending(path: PrincipalStorageLayout.pendingSubmissionsFileName)
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacyEvidence = Data("ambiguous legacy submission".utf8)
        try legacyEvidence.write(to: legacyURL, options: [.atomic])
        installSuccessfulLifecycleHandler(events: events)
        defer { IdentityLifecycleURLProtocolStub.reset() }
        let appState = makeRelaunchAppState(
            environment: environment,
            journal: journal,
            credentials: credentials,
            events: events
        )

        await appState.bootstrapIdentity()

        let recordedEvents = events.snapshot()
        let retainedPlan = await journal.currentPlan()
        let clearAttempts = await journal.clearAttemptCount()
        let currentCredentials = await credentials.currentCredentials()
        XCTAssertLessThan(
            try XCTUnwrap(recordedEvents.firstIndex(of: "journal.load")),
            try XCTUnwrap(recordedEvents.firstIndex(of: "network.guest"))
        )
        XCTAssertLessThan(
            try XCTUnwrap(recordedEvents.firstIndex(of: "credential.clear")),
            try XCTUnwrap(recordedEvents.firstIndex(of: "network.guest"))
        )
        XCTAssertFalse(recordedEvents.contains("network.delete"))
        XCTAssertEqual(recordedEvents.filter { $0 == "network.guest" }.count, 1)
        XCTAssertNil(retainedPlan)
        XCTAssertEqual(clearAttempts, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyURL.path)
        )
        let quarantinedLegacyURL = environment.root
            .appending(path: "Itinera", directoryHint: .isDirectory)
            .appending(path: "quarantine", directoryHint: .isDirectory)
            .appending(path: "unscoped-v1", directoryHint: .isDirectory)
            .appending(path: PrincipalStorageLayout.pendingSubmissionsFileName)
        XCTAssertEqual(
            try Data(contentsOf: quarantinedLegacyURL),
            legacyEvidence
        )
        XCTAssertNotNil(appState.privateAppSession)
        XCTAssertEqual(appState.identityPhase, .ready(isOffline: false))
        XCTAssertEqual(
            currentCredentials?.userID,
            guestUserID
        )
    }

    func testBootstrapLoadsJournalBeforeQuarantineAndCredentialsAndNeverReplaysLegacySubmission()
        async throws {
        let environment = makeEnvironment()
        defer { environment.remove() }
        let events = IdentityLifecycleEventLog()
        let legacyURL = environment.root
            .appending(path: "Itinera", directoryHint: .isDirectory)
            .appending(path: PrincipalStorageLayout.pendingSubmissionsFileName)
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacyEvidence = Data("unscoped request must never be decoded".utf8)
        try legacyEvidence.write(to: legacyURL, options: [.atomic])
        let journal = IdentityLifecycleJournal(
            observedLegacyPath: legacyURL.path,
            events: events
        )
        let credentials = IdentityLifecycleCredentialStore(
            credentials: establishedCredentials,
            observedLegacyPath: legacyURL.path,
            events: events
        )
        IdentityLifecycleURLProtocolStub.setHandler { request in
            events.record(
                "network.unexpected.\(request.httpMethod ?? "unknown").\(request.url?.path ?? "unknown")"
            )
            throw IdentityLifecycleTestError.unexpectedRequest
        }
        defer { IdentityLifecycleURLProtocolStub.reset() }
        let appState = makeRelaunchAppState(
            environment: environment,
            journal: journal,
            credentials: credentials,
            events: events
        )

        await appState.bootstrapIdentity()

        let session = try XCTUnwrap(appState.privateAppSession)
        await appState.resumePendingSubmissions(session: session)

        let recordedEvents = events.snapshot()
        XCTAssertLessThan(
            try XCTUnwrap(recordedEvents.firstIndex(of: "journal.load")),
            try XCTUnwrap(
                recordedEvents.firstIndex(of: "legacy.quarantine.completed")
            )
        )
        XCTAssertLessThan(
            try XCTUnwrap(
                recordedEvents.firstIndex(of: "legacy.quarantine.completed")
            ),
            try XCTUnwrap(recordedEvents.firstIndex(of: "credential.load"))
        )
        XCTAssertTrue(recordedEvents.contains("journal.load.legacy-present"))
        XCTAssertFalse(
            recordedEvents.contains("credential.load.legacy-present")
        )
        XCTAssertFalse(
            recordedEvents.contains { $0.hasPrefix("network.unexpected") },
            "Quarantined pending work must never cause a network request."
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        let quarantineURL = environment.root
            .appending(path: "Itinera", directoryHint: .isDirectory)
            .appending(path: "quarantine", directoryHint: .isDirectory)
            .appending(path: "unscoped-v1", directoryHint: .isDirectory)
            .appending(path: PrincipalStorageLayout.pendingSubmissionsFileName)
        XCTAssertEqual(try Data(contentsOf: quarantineURL), legacyEvidence)
        XCTAssertEqual(appState.identityPhase, .ready(isOffline: false))
    }

    func testBootstrapCancellationDuringSuspendedSurfaceEstablishmentVerifiesTeardown()
        async throws {
        let environment = makeEnvironment()
        defer { environment.remove() }
        let events = IdentityLifecycleEventLog()
        let journal = IdentityLifecycleJournal(events: events)
        let credentials = IdentityLifecycleCredentialStore(
            credentials: establishedCredentials,
            events: events
        )
        let surfaces = IdentityLifecycleSurfaceSpy(
            activeSession: nil,
            suspendNextEstablish: true,
            events: events
        )
        IdentityLifecycleURLProtocolStub.setHandler { request in
            events.record(
                "network.unexpected.\(request.httpMethod ?? "unknown").\(request.url?.path ?? "unknown")"
            )
            throw IdentityLifecycleTestError.unexpectedRequest
        }
        defer {
            surfaces.resumeSuspendedEstablish()
            IdentityLifecycleURLProtocolStub.reset()
        }
        let appState = makeRelaunchAppState(
            environment: environment,
            journal: journal,
            credentials: credentials,
            events: events,
            surfaces: surfaces
        )

        let bootstrap = Task { await appState.bootstrapIdentity() }
        try await waitForEvent(
            "surface.establish.suspended",
            events: events
        )
        XCTAssertNotNil(
            surfaces.activeSession,
            "The spy models a surface published before establishment returns."
        )

        bootstrap.cancel()
        surfaces.resumeSuspendedEstablish()
        await bootstrap.value

        XCTAssertGreaterThanOrEqual(surfaces.tearDownCount, 2)
        XCTAssertNil(surfaces.activeSession)
        XCTAssertNil(appState.privateAppSession)
        XCTAssertNil(appState.currentPrincipalScope)
        XCTAssertFalse(appState.identityPhase.presentsPrivateContent)
        guard case .blocked = appState.identityPhase else {
            return XCTFail("Cancelled bootstrap must retain a retryable curtain.")
        }
        XCTAssertFalse(
            events.snapshot().contains { $0.hasPrefix("network.unexpected") }
        )
    }

    func testConfirmedAppleSwitchPublishesOnlyTheExistingAppleLibrary()
        async throws {
        let environment = makeEnvironment()
        defer { environment.remove() }
        let events = IdentityLifecycleEventLog()
        let journal = IdentityLifecycleJournal(events: events)
        let credentials = IdentityLifecycleCredentialStore(
            credentials: establishedCredentials,
            events: events
        )
        let harness = try makeReadyHarness(
            environment: environment,
            journal: journal,
            credentials: credentials,
            events: events
        )
        IdentityLifecycleURLProtocolStub.setHandler { request in
            guard request.httpMethod == "POST",
                  request.url?.path == "/api/v1/auth/apple" else {
                throw IdentityLifecycleTestError.unexpectedRequest
            }
            events.record("network.apple.prepare")
            return .init(
                statusCode: 200,
                data: IdentityLifecycleFixtures.tokenResponse(
                    userID: IdentityLifecycleFixtures.appleUserID,
                    accessToken: "apple-access",
                    refreshToken: "apple-refresh"
                )
            )
        }
        defer { IdentityLifecycleURLProtocolStub.reset() }

        try await harness.appState.switchToAppleAccount(
            identityToken: "ephemeral-apple-token",
            session: harness.session
        )

        let publishedSession = try XCTUnwrap(
            harness.appState.privateAppSession
        )
        let appleScope = try PrincipalIdentity(
            serverUserID: IdentityLifecycleFixtures.appleUserID
        ).scope
        let storedCredentials = await credentials.currentCredentials()
        XCTAssertEqual(publishedSession.lease.scope, appleScope)
        XCTAssertNotEqual(publishedSession, harness.session)
        XCTAssertEqual(harness.appState.currentPrincipalScope, appleScope)
        XCTAssertEqual(harness.appState.identityPhase, .ready(isOffline: false))
        XCTAssertEqual(
            harness.appState.identityOutcome,
            .appleLibrarySwitched
        )
        XCTAssertEqual(
            storedCredentials?.userID,
            IdentityLifecycleFixtures.appleUserID
        )
        XCTAssertEqual(harness.surfaces.establishCount, 1)
        XCTAssertEqual(
            harness.surfaces.activeSession,
            publishedSession.presentationSession
        )
        XCTAssertEqual(
            events.snapshot().filter { $0 == "network.apple.prepare" }.count,
            1
        )
    }

    func testConfirmedAppleSwitchCannotOverlapSuspendedDeletionOrActivateCandidate()
        async throws {
        let environment = makeEnvironment()
        defer { environment.remove() }
        let events = IdentityLifecycleEventLog()
        let journal = IdentityLifecycleJournal(
            suspendNextServerDeletionSave: true,
            events: events
        )
        let credentials = IdentityLifecycleCredentialStore(
            credentials: establishedCredentials,
            events: events
        )
        let harness = try makeReadyHarness(
            environment: environment,
            journal: journal,
            credentials: credentials,
            events: events
        )
        IdentityLifecycleURLProtocolStub.setHandler { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/v1/auth/apple"):
                events.record("network.apple.prepare")
                return .init(
                    statusCode: 200,
                    data: IdentityLifecycleFixtures.tokenResponse(
                        userID: IdentityLifecycleFixtures.appleUserID,
                        accessToken: "candidate-access",
                        refreshToken: "candidate-refresh"
                    )
                )
            case ("DELETE", "/api/v1/auth/me"):
                events.record("network.delete")
                throw URLError(.notConnectedToInternet)
            default:
                throw IdentityLifecycleTestError.unexpectedRequest
            }
        }
        defer {
            Task { await journal.resumeSuspendedSave() }
            IdentityLifecycleURLProtocolStub.reset()
        }

        let deletion = Task { () -> Error? in
            do {
                try await harness.appState.deleteMyData(
                    session: harness.session
                )
                return nil
            } catch {
                return error
            }
        }
        try await waitForEvent(
            "journal.save.serverDeletionPending.suspended",
            events: events
        )

        do {
            try await harness.appState.switchToAppleAccount(
                identityToken: "confirmed-but-racing-token",
                session: harness.session
            )
            XCTFail("The deletion operation must retain the lifecycle gate.")
        } catch {
            XCTAssertEqual(
                error as? IdentityCoordinatorError,
                .staleIdentity
            )
        }

        let credentialsBeforeDeletionResumes =
            await credentials.currentCredentials()
        let savedCandidates = await credentials.savedCredentials()
        XCTAssertEqual(
            harness.appState.privateAppSession,
            harness.session
        )
        XCTAssertEqual(
            credentialsBeforeDeletionResumes,
            establishedCredentials
        )
        XCTAssertTrue(savedCandidates.isEmpty)
        XCTAssertEqual(harness.surfaces.establishCount, 0)
        XCTAssertNil(harness.appState.identityOutcome)

        await journal.resumeSuspendedSave()
        let deletionError = await deletion.value
        guard let deletionAPIError = deletionError as? APIError,
              case .transport = deletionAPIError else {
            return XCTFail("Deletion should retain its plan after transport loss.")
        }

        XCTAssertEqual(harness.surfaces.establishCount, 0)
        XCTAssertNil(harness.surfaces.activeSession)
        XCTAssertNil(harness.appState.privateAppSession)
        XCTAssertNil(harness.appState.currentPrincipalScope)
        XCTAssertEqual(
            events.snapshot().filter { $0 == "network.apple.prepare" }.count,
            1
        )
        XCTAssertEqual(
            events.snapshot().filter { $0 == "network.delete" }.count,
            1
        )
        guard case .cleanupRequired(let intent, let stage, _) =
                harness.appState.identityPhase else {
            return XCTFail("Deletion recovery must remain behind the curtain.")
        }
        XCTAssertEqual(intent, .delete)
        XCTAssertEqual(stage, .serverDeletionPending)
    }

    func testClearSignOutAndDeleteReplaceSessionsAndPublishOnlyTheirOwnOutcomes()
        async throws {
        let environment = makeEnvironment()
        defer { environment.remove() }
        let events = IdentityLifecycleEventLog()
        let storageGate = IdentityLifecycleSuspensionGate(
            event: "storage.commit.suspended",
            events: events
        )
        let journal = IdentityLifecycleJournal(
            suspendedSaveStages: [.localCleanup, .serverDeletionPending],
            events: events
        )
        let credentials = IdentityLifecycleCredentialStore(
            credentials: establishedCredentials,
            events: events
        )
        let harness = try makeReadyHarness(
            environment: environment,
            journal: journal,
            credentials: credentials,
            events: events,
            beforeCommit: { _ in await storageGate.suspendOnce() }
        )
        IdentityLifecycleURLProtocolStub.setHandler { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/v1/auth/apple/link"):
                events.record("network.apple.link")
                return .init(
                    statusCode: 200,
                    data: IdentityLifecycleFixtures.tokenResponse(
                        userID: IdentityLifecycleFixtures.establishedUserID,
                        accessToken: "linked-access",
                        refreshToken: "linked-refresh"
                    )
                )
            case ("POST", "/api/v1/auth/guest"):
                events.record("network.guest")
                return .init(
                    statusCode: 200,
                    data: IdentityLifecycleFixtures.tokenResponse(
                        userID: IdentityLifecycleFixtures.guestUserID,
                        accessToken: "guest-access",
                        refreshToken: "guest-refresh"
                    )
                )
            case ("DELETE", "/api/v1/auth/me"):
                events.record("network.delete")
                return .init(statusCode: 204, data: Data())
            default:
                throw IdentityLifecycleTestError.unexpectedRequest
            }
        }
        defer {
            Task {
                await storageGate.resume()
                await journal.resumeSuspendedSave()
            }
            IdentityLifecycleURLProtocolStub.reset()
        }

        let linkResult = try await harness.appState.connectAppleAccount(
            identityToken: "ephemeral-link-token",
            session: harness.session
        )
        XCTAssertEqual(linkResult, .linked)
        XCTAssertEqual(
            harness.appState.identityOutcome,
            .appleAccountLinked
        )

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
        try await waitForEvent("storage.commit.suspended", events: events)
        XCTAssertNil(
            harness.appState.identityOutcome,
            "A newly owned operation must clear stale completion copy."
        )
        XCTAssertEqual(harness.appState.identityPhase, .clearingDownloads)
        await storageGate.resume()
        let clearError = await clear.value
        XCTAssertNil(clearError)

        let clearedSession = try XCTUnwrap(
            harness.appState.privateAppSession
        )
        XCTAssertEqual(clearedSession.lease.scope, harness.session.lease.scope)
        XCTAssertNotEqual(clearedSession, harness.session)
        XCTAssertEqual(
            harness.appState.identityOutcome,
            .downloadsCleared
        )
        XCTAssertEqual(harness.appState.identityPhase, .ready(isOffline: false))

        do {
            let currentServerLease = try await harness.appState
                .identityCoordinator.captureServerOperationLease(
                    ifCurrent: clearedSession.lease
                )
            _ = try await harness.stores.pendingJobStore.add(
                jobID: "stale-old-store",
                title: nil,
                lease: harness.session.lease,
                serverOperationLease: currentServerLease
            )
            XCTFail("The retained pre-clear actor must reject its old lease.")
        } catch {
            XCTAssertEqual(
                error as? IdentityCoordinatorError,
                .staleIdentity
            )
        }
        await harness.appState.registerPending(
            jobID: "fresh-store-job",
            title: "Fresh store",
            session: clearedSession
        )
        XCTAssertEqual(
            harness.appState.pendingJobs.map(\.jobID),
            ["fresh-store-job"]
        )

        let signOut = Task { () -> Error? in
            do {
                try await harness.appState.signOut(session: clearedSession)
                return nil
            } catch {
                return error
            }
        }
        try await waitForEvent(
            "journal.save.localCleanup.suspended",
            events: events
        )
        XCTAssertNil(harness.appState.identityOutcome)
        await journal.resumeSuspendedSave()
        let signOutError = await signOut.value
        XCTAssertNil(signOutError)

        let signedOutSession = try XCTUnwrap(
            harness.appState.privateAppSession
        )
        XCTAssertNotEqual(signedOutSession, clearedSession)
        XCTAssertEqual(harness.appState.identityOutcome, .signedOut)
        XCTAssertEqual(harness.appState.identityPhase, .ready(isOffline: false))

        let deletion = Task { () -> Error? in
            do {
                try await harness.appState.deleteMyData(
                    session: signedOutSession
                )
                return nil
            } catch {
                return error
            }
        }
        try await waitForEvent(
            "journal.save.serverDeletionPending.suspended",
            events: events
        )
        XCTAssertNil(harness.appState.identityOutcome)
        await journal.resumeSuspendedSave()
        let deletionError = await deletion.value
        XCTAssertNil(deletionError)

        let replacementSession = try XCTUnwrap(
            harness.appState.privateAppSession
        )
        XCTAssertNotEqual(replacementSession, signedOutSession)
        XCTAssertEqual(harness.appState.identityOutcome, .accountDeleted)
        XCTAssertEqual(harness.appState.identityPhase, .ready(isOffline: false))
        XCTAssertEqual(harness.surfaces.establishCount, 3)
        XCTAssertEqual(
            harness.surfaces.activeSession,
            replacementSession.presentationSession
        )
    }

    func testDelayedDispatchedLibraryResponseCannotPublishAfterAppleSwitch()
        async throws {
        let environment = makeEnvironment()
        defer { environment.remove() }
        let events = IdentityLifecycleEventLog()
        let journal = IdentityLifecycleJournal(events: events)
        let credentials = IdentityLifecycleCredentialStore(
            credentials: establishedCredentials,
            events: events
        )
        let harness = try makeReadyHarness(
            environment: environment,
            journal: journal,
            credentials: credentials,
            events: events
        )
        let releaseLibraryResponse = IdentityLifecycleResponseGate()
        IdentityLifecycleURLProtocolStub.setHandler { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/v1/itineraries"):
                events.record("network.library.started")
                return .init(
                    statusCode: 200,
                    data: Data(
                        """
                        [{
                          "job_id": "private-a-trip",
                          "status": "succeeded",
                          "title": "Private A",
                          "result": null,
                          "error": null,
                          "archived_at": null,
                          "version": 1,
                          "created_at": "2026-07-13T00:00:00Z"
                        }]
                        """.utf8
                    ),
                    deliveryGate: releaseLibraryResponse,
                    onDelivery: {
                        events.record("network.library.released")
                    }
                )
            case ("POST", "/api/v1/auth/apple"):
                events.record("network.apple.prepare")
                return .init(
                    statusCode: 200,
                    data: IdentityLifecycleFixtures.tokenResponse(
                        userID: IdentityLifecycleFixtures.appleUserID,
                        accessToken: "apple-access",
                        refreshToken: "apple-refresh"
                    )
                )
            default:
                throw IdentityLifecycleTestError.unexpectedRequest
            }
        }
        defer {
            releaseLibraryResponse.release()
            IdentityLifecycleURLProtocolStub.reset()
        }

        let delayedLibrary = Task { () -> Error? in
            do {
                _ = try await harness.appState.refreshTripLibrary(
                    session: harness.session
                )
                return nil
            } catch {
                return error
            }
        }
        try await waitForEvent("network.library.started", events: events)

        try await harness.appState.switchToAppleAccount(
            identityToken: "confirmed-apple-token",
            session: harness.session
        )
        let switchedSession = try XCTUnwrap(
            harness.appState.privateAppSession
        )
        let appleScope = try PrincipalIdentity(
            serverUserID: IdentityLifecycleFixtures.appleUserID
        ).scope
        XCTAssertEqual(switchedSession.lease.scope, appleScope)
        XCTAssertTrue(harness.appState.cachedTrips.isEmpty)

        releaseLibraryResponse.release()
        let delayedError = await delayedLibrary.value
        XCTAssertNotNil(delayedError)
        XCTAssertEqual(
            harness.appState.privateAppSession,
            switchedSession
        )
        XCTAssertEqual(harness.appState.currentPrincipalScope, appleScope)
        XCTAssertTrue(harness.appState.cachedTrips.isEmpty)
        XCTAssertEqual(
            harness.appState.identityOutcome,
            .appleLibrarySwitched
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: harness.stores.layout.completedTripsURL.path
            )
        )
    }

    func testRecoveryPauseRejectsPendingCommitCapturedWhileReady()
        async throws {
        let environment = makeEnvironment()
        defer { environment.remove() }
        let events = IdentityLifecycleEventLog()
        let pendingCommitGate = IdentityLifecycleSuspensionGate(
            event: "storage.pending.commit.suspended",
            events: events
        )
        let journal = IdentityLifecycleJournal(events: events)
        let credentials = IdentityLifecycleCredentialStore(
            credentials: establishedCredentials,
            events: events
        )
        let harness = try makeReadyHarness(
            environment: environment,
            journal: journal,
            credentials: credentials,
            events: events,
            beforeCommit: { _ in await pendingCommitGate.suspendOnce() }
        )
        IdentityLifecycleURLProtocolStub.setHandler { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/v1/itineraries"):
                events.record("network.library.unauthorized")
                return .init(
                    statusCode: 401,
                    data: Data(#"{"detail":"refresh required"}"#.utf8)
                )
            case ("POST", "/api/v1/auth/refresh"):
                events.record("network.refresh.rejected")
                return .init(
                    statusCode: 401,
                    data: Data(#"{"detail":"reauthenticate"}"#.utf8)
                )
            default:
                throw IdentityLifecycleTestError.unexpectedRequest
            }
        }
        defer {
            Task { await pendingCommitGate.resume() }
            IdentityLifecycleURLProtocolStub.reset()
        }

        let pendingMutation = Task {
            await harness.appState.registerPending(
                jobID: "must-not-commit",
                title: "Stale queued trip",
                session: harness.session
            )
        }
        try await waitForEvent(
            "storage.pending.commit.suspended",
            events: events
        )

        do {
            _ = try await harness.appState.scopedAPIValue(
                session: harness.session
            ) {
                try await $0.savedItineraries()
            }
            XCTFail("Rejected refresh must pause this server session.")
        } catch {
            XCTAssertEqual(error as? APIError, .identityRecoveryRequired)
        }

        guard case .recoveryRequired = harness.appState.identityPhase else {
            return XCTFail("Server work must remain paused for recovery.")
        }
        XCTAssertTrue(harness.appState.pendingJobs.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: harness.stores.layout.pendingJobsURL.path
            )
        )

        await pendingCommitGate.resume()
        await pendingMutation.value

        let storedPendingJobs = try await harness.stores.pendingJobStore.all()
        XCTAssertTrue(harness.appState.pendingJobs.isEmpty)
        XCTAssertTrue(storedPendingJobs.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: harness.stores.layout.pendingJobsURL.path
            )
        )
        XCTAssertEqual(
            events.snapshot().filter {
                $0 == "network.library.unauthorized"
            }.count,
            1
        )
        XCTAssertEqual(
            events.snapshot().filter { $0 == "network.refresh.rejected" }.count,
            1
        )
    }

    func testDelete204ThenJournalAdvanceFailureRetriesOnRelaunch()
        async throws {
        let environment = makeEnvironment()
        defer { environment.remove() }
        let events = IdentityLifecycleEventLog()
        let journal = IdentityLifecycleJournal(
            localCleanupSaveFailures: 1,
            events: events
        )
        let credentials = IdentityLifecycleCredentialStore(
            credentials: establishedCredentials,
            events: events
        )
        let firstHarness = try makeReadyHarness(
            environment: environment,
            journal: journal,
            credentials: credentials,
            events: events
        )
        installSuccessfulLifecycleHandler(events: events)
        defer { IdentityLifecycleURLProtocolStub.reset() }

        do {
            try await firstHarness.appState.deleteMyData(
                session: firstHarness.session
            )
            XCTFail("The failed journal advance must keep the curtain raised.")
        } catch let error as IdentityLifecycleTestError {
            XCTAssertEqual(error, .journalSaveFailed)
        }

        let retainedPlan = await journal.currentPlan()
        let initialSaveAttempts = await journal.savedPlans()
        let retainedCredentials = await credentials.currentCredentials()
        XCTAssertEqual(initialSaveAttempts.count, 2)
        XCTAssertEqual(retainedPlan, initialSaveAttempts[0])
        XCTAssertEqual(retainedPlan?.schemaVersion, 1)
        XCTAssertEqual(retainedPlan?.intent, .delete)
        XCTAssertEqual(retainedPlan?.stage, .serverDeletionPending)
        XCTAssertEqual(retainedPlan?.scope, establishedIdentity.scope)
        XCTAssertEqual(
            initialSaveAttempts[1],
            retainedPlan?.advancing(to: .localCleanup)
        )
        XCTAssertEqual(
            retainedCredentials,
            establishedCredentials
        )
        assertPrivacyCurtain(firstHarness.appState)
        XCTAssertGreaterThanOrEqual(firstHarness.surfaces.tearDownCount, 1)
        XCTAssertNil(firstHarness.surfaces.activeSession)
        XCTAssertEqual(
            events.snapshot().filter { $0 == "network.delete" }.count,
            1
        )
        XCTAssertFalse(events.snapshot().contains("network.guest"))

        let relaunched = makeRelaunchAppState(
            environment: environment,
            journal: journal,
            credentials: credentials,
            events: events
        )
        await relaunched.bootstrapIdentity()

        let recordedEvents = events.snapshot()
        let completedPlan = await journal.currentPlan()
        XCTAssertEqual(
            recordedEvents.filter { $0 == "network.delete" }.count,
            2
        )
        XCTAssertEqual(
            recordedEvents.filter { $0 == "network.guest" }.count,
            1
        )
        XCTAssertLessThan(
            try XCTUnwrap(
                recordedEvents.lastIndex(of: "network.delete")
            ),
            try XCTUnwrap(recordedEvents.firstIndex(of: "network.guest"))
        )
        XCTAssertNil(completedPlan)
        XCTAssertEqual(relaunched.identityPhase, .ready(isOffline: false))
        XCTAssertNotNil(relaunched.privateAppSession)
    }

    func testCredentialClearFailureRetainsLocalPlanAfterIndependentPurge()
        async throws {
        let environment = makeEnvironment()
        defer { environment.remove() }
        let events = IdentityLifecycleEventLog()
        let journal = IdentityLifecycleJournal(events: events)
        let credentials = IdentityLifecycleCredentialStore(
            credentials: establishedCredentials,
            clearFailures: 1,
            events: events
        )
        let harness = try makeReadyHarness(
            environment: environment,
            journal: journal,
            credentials: credentials,
            events: events
        )
        let serverOperationLease = try await harness.appState
            .identityCoordinator.captureServerOperationLease(
                ifCurrent: harness.session.lease
            )
        _ = try await harness.stores.pendingJobStore.add(
            jobID: "private-job",
            title: "Private trip",
            lease: harness.session.lease,
            serverOperationLease: serverOperationLease
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: harness.stores.layout.scopeDirectory.path
            )
        )
        installSuccessfulLifecycleHandler(events: events)
        defer { IdentityLifecycleURLProtocolStub.reset() }

        do {
            try await harness.appState.signOut(session: harness.session)
            XCTFail("Credential cleanup failure must retain the journal.")
        } catch let error as LocalDataCleanupError {
            guard case .identityCleanupIncomplete = error else {
                return XCTFail("Unexpected cleanup error: \(error)")
            }
        }

        let clearAttempts = await credentials.clearAttemptCount()
        let retainedCredentials = await credentials.currentCredentials()
        let retainedPlan = await journal.currentPlan()
        let journalClearAttempts = await journal.clearAttemptCount()
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: harness.stores.layout.scopeDirectory.path
            )
        )
        XCTAssertGreaterThanOrEqual(harness.surfaces.tearDownCount, 1)
        XCTAssertEqual(clearAttempts, 1)
        XCTAssertEqual(
            retainedCredentials,
            establishedCredentials
        )
        XCTAssertEqual(retainedPlan?.stage, .localCleanup)
        XCTAssertEqual(journalClearAttempts, 0)
        XCTAssertFalse(events.snapshot().contains("network.guest"))
        XCTAssertEqual(harness.surfaces.establishCount, 0)
        assertPrivacyCurtain(harness.appState)
    }

    func testLocalPurgeFailureStillAttemptsIndependentCleanupAndRetainsPlan()
        async throws {
        let environment = makeEnvironment()
        defer { environment.remove() }
        let events = IdentityLifecycleEventLog()
        let journal = IdentityLifecycleJournal(events: events)
        let credentials = IdentityLifecycleCredentialStore(
            credentials: establishedCredentials,
            events: events
        )
        let expectedScope = establishedIdentity.scope
        let harness = try makeReadyHarness(
            environment: environment,
            journal: journal,
            credentials: credentials,
            events: events,
            beforePurgeCommit: { scope in
                guard scope == expectedScope else {
                    throw IdentityLifecycleTestError.unexpectedRequest
                }
                events.record("storage.purge")
                throw IdentityLifecycleTestError.localPurgeFailed
            }
        )
        let serverOperationLease = try await harness.appState
            .identityCoordinator.captureServerOperationLease(
                ifCurrent: harness.session.lease
            )
        _ = try await harness.stores.pendingJobStore.add(
            jobID: "private-job",
            title: "Private trip",
            lease: harness.session.lease,
            serverOperationLease: serverOperationLease
        )
        installSuccessfulLifecycleHandler(events: events)
        defer { IdentityLifecycleURLProtocolStub.reset() }

        do {
            try await harness.appState.signOut(session: harness.session)
            XCTFail("Local purge failure must retain the cleanup journal.")
        } catch let error as LocalDataCleanupError {
            guard case .identityCleanupIncomplete = error else {
                return XCTFail("Unexpected cleanup error: \(error)")
            }
        }

        let recordedEvents = events.snapshot()
        let retainedPlan = await journal.currentPlan()
        let saveAttempts = await journal.savedPlans()
        let journalClearAttempts = await journal.clearAttemptCount()
        let credentialClearAttempts = await credentials.clearAttemptCount()
        let currentCredentials = await credentials.currentCredentials()
        XCTAssertEqual(saveAttempts.count, 1)
        XCTAssertEqual(retainedPlan, saveAttempts.first)
        XCTAssertEqual(retainedPlan?.schemaVersion, 1)
        XCTAssertEqual(retainedPlan?.intent, .signOut)
        XCTAssertEqual(retainedPlan?.stage, .localCleanup)
        XCTAssertEqual(retainedPlan?.scope, establishedIdentity.scope)
        XCTAssertTrue(recordedEvents.contains("storage.purge"))
        XCTAssertTrue(recordedEvents.contains("credential.clear"))
        XCTAssertGreaterThanOrEqual(harness.surfaces.tearDownCount, 1)
        XCTAssertNil(harness.surfaces.activeSession)
        XCTAssertEqual(credentialClearAttempts, 1)
        XCTAssertNil(currentCredentials)
        XCTAssertEqual(journalClearAttempts, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: harness.stores.layout.scopeDirectory.path
            )
        )
        XCTAssertFalse(recordedEvents.contains("network.guest"))
        XCTAssertEqual(harness.surfaces.establishCount, 0)
        assertPrivacyCurtain(harness.appState)
    }

    func testJournalClearFailureKeepsCurtainAfterOtherCleanupSucceeds()
        async throws {
        let environment = makeEnvironment()
        defer { environment.remove() }
        let events = IdentityLifecycleEventLog()
        let journal = IdentityLifecycleJournal(
            clearFailures: 1,
            events: events
        )
        let credentials = IdentityLifecycleCredentialStore(
            credentials: establishedCredentials,
            events: events
        )
        let harness = try makeReadyHarness(
            environment: environment,
            journal: journal,
            credentials: credentials,
            events: events
        )
        let serverOperationLease = try await harness.appState
            .identityCoordinator.captureServerOperationLease(
                ifCurrent: harness.session.lease
            )
        _ = try await harness.stores.pendingJobStore.add(
            jobID: "private-job",
            title: nil,
            lease: harness.session.lease,
            serverOperationLease: serverOperationLease
        )
        installSuccessfulLifecycleHandler(events: events)
        defer { IdentityLifecycleURLProtocolStub.reset() }

        do {
            try await harness.appState.signOut(session: harness.session)
            XCTFail("A journal-clear failure must prevent guest publication.")
        } catch let error as IdentityLifecycleTestError {
            XCTAssertEqual(error, .journalClearFailed)
        }

        let currentCredentials = await credentials.currentCredentials()
        let clearAttempts = await credentials.clearAttemptCount()
        let retainedPlan = await journal.currentPlan()
        let journalClearAttempts = await journal.clearAttemptCount()
        XCTAssertNil(currentCredentials)
        XCTAssertEqual(clearAttempts, 1)
        XCTAssertEqual(retainedPlan?.stage, .localCleanup)
        XCTAssertEqual(journalClearAttempts, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: harness.stores.layout.scopeDirectory.path
            )
        )
        XCTAssertFalse(events.snapshot().contains("network.guest"))
        XCTAssertEqual(harness.surfaces.establishCount, 0)
        assertPrivacyCurtain(harness.appState)
    }

    func testCorruptJournalLoadBlocksWithoutDeletingEvidence()
        async throws {
        let environment = makeEnvironment()
        defer { environment.remove() }
        let events = IdentityLifecycleEventLog()
        let journal = IdentityLifecycleJournal(
            loadFailure: true,
            evidencePresent: true,
            events: events
        )
        let credentials = IdentityLifecycleCredentialStore(
            credentials: establishedCredentials,
            events: events
        )
        installSuccessfulLifecycleHandler(events: events)
        defer { IdentityLifecycleURLProtocolStub.reset() }
        let appState = makeRelaunchAppState(
            environment: environment,
            journal: journal,
            credentials: credentials,
            events: events
        )

        await appState.bootstrapIdentity()

        let hasEvidence = await journal.hasEvidence()
        let clearAttempts = await journal.clearAttemptCount()
        let retainedCredentials = await credentials.currentCredentials()
        XCTAssertTrue(hasEvidence)
        XCTAssertEqual(clearAttempts, 0)
        XCTAssertEqual(
            retainedCredentials,
            establishedCredentials
        )
        XCTAssertFalse(events.snapshot().contains("network.delete"))
        XCTAssertFalse(events.snapshot().contains("network.guest"))
        assertPrivacyCurtain(appState)
    }

    func testUnsupportedJournalPlanBlocksWithoutDeletingEvidence()
        async throws {
        let environment = makeEnvironment()
        defer { environment.remove() }
        let events = IdentityLifecycleEventLog()
        let unsupportedPlan = PrivateCleanupPlan(
            schemaVersion:
                ProtectedFilePrivateCleanupJournal.currentSchemaVersion + 1,
            operationID: fixedOperationID,
            intent: .delete,
            stage: .serverDeletionPending,
            scope: establishedIdentity.scope
        )
        let journal = IdentityLifecycleJournal(
            plan: unsupportedPlan,
            evidencePresent: true,
            events: events
        )
        let credentials = IdentityLifecycleCredentialStore(
            credentials: establishedCredentials,
            events: events
        )
        installSuccessfulLifecycleHandler(events: events)
        defer { IdentityLifecycleURLProtocolStub.reset() }
        let appState = makeRelaunchAppState(
            environment: environment,
            journal: journal,
            credentials: credentials,
            events: events
        )

        await appState.bootstrapIdentity()

        let hasEvidence = await journal.hasEvidence()
        let clearAttempts = await journal.clearAttemptCount()
        let retainedPlan = await journal.currentPlan()
        let retainedCredentials = await credentials.currentCredentials()
        XCTAssertTrue(hasEvidence)
        XCTAssertEqual(clearAttempts, 0)
        XCTAssertEqual(retainedPlan, unsupportedPlan)
        XCTAssertEqual(
            retainedCredentials,
            establishedCredentials
        )
        XCTAssertFalse(events.snapshot().contains("network.delete"))
        XCTAssertFalse(events.snapshot().contains("network.guest"))
        assertPrivacyCurtain(appState)
    }

    private struct ReadyHarness {
        let appState: AppState
        let stores: PrincipalStoreSet
        let surfaces: IdentityLifecycleSurfaceSpy
        let session: PrivateAppSession
    }

    private func makeReadyHarness(
        environment: IdentityLifecycleEnvironment,
        journal: IdentityLifecycleJournal,
        credentials: IdentityLifecycleCredentialStore,
        events: IdentityLifecycleEventLog,
        initialEpoch: UInt64 = 7,
        surfaceTearDownFailures: Int = 0,
        beforeCommit: PrincipalStorageBeforeCommit? = nil,
        beforePurgeCommit: PrincipalStorageBeforePurgeCommit? = nil
    ) throws -> ReadyHarness {
        let sessionID = UUID(
            uuidString: "77777777-7777-4777-8777-777777777777"
        )!
        let lease = IdentityLease(
            scope: establishedIdentity.scope,
            epoch: initialEpoch,
            presentationSessionID: sessionID
        )
        let coordinator = IdentityCoordinator(
            initialScope: lease.scope,
            initialEpoch: lease.epoch,
            initialPresentationSessionID: sessionID
        )
        let factory = PrincipalStorageFactory(
            applicationSupportDirectory: environment.root,
            identityCoordinator: coordinator,
            beforeCommit: beforeCommit,
            beforePurgeCommit: beforePurgeCommit
        )
        let stores = factory.makeStoreSet(
            for: lease,
            defaultsDomain: environment.defaultsDomain
        )
        let surfaces = IdentityLifecycleSurfaceSpy(
            activeSession: lease.presentationSession,
            tearDownFailures: surfaceTearDownFailures,
            events: events
        )
        let appState = AppState(
            apiClient: makeAPIClient(
                coordinator: coordinator,
                credentials: credentials
            ),
            identityCoordinator: coordinator,
            storageFactory: factory,
            defaults: environment.defaults,
            defaultsDomain: environment.defaultsDomain,
            surfaceCoordinator: surfaces,
            cleanupJournal: journal,
            initialStoreSet: stores
        )
        return ReadyHarness(
            appState: appState,
            stores: stores,
            surfaces: surfaces,
            session: PrivateAppSession(lease: lease)
        )
    }

    private func makeRelaunchAppState(
        environment: IdentityLifecycleEnvironment,
        journal: IdentityLifecycleJournal,
        credentials: IdentityLifecycleCredentialStore,
        events: IdentityLifecycleEventLog,
        initialEpoch: UInt64 = 0,
        surfaces: IdentityLifecycleSurfaceSpy? = nil
    ) -> AppState {
        let coordinator = IdentityCoordinator(initialEpoch: initialEpoch)
        let factory = PrincipalStorageFactory(
            applicationSupportDirectory: environment.root,
            identityCoordinator: coordinator
        )
        return AppState(
            apiClient: makeAPIClient(
                coordinator: coordinator,
                credentials: credentials
            ),
            identityCoordinator: coordinator,
            storageFactory: factory,
            defaults: environment.defaults,
            defaultsDomain: environment.defaultsDomain,
            surfaceCoordinator: surfaces ?? IdentityLifecycleSurfaceSpy(
                activeSession: nil,
                events: events
            ),
            cleanupJournal: journal
        )
    }

    private func makeAPIClient(
        coordinator: IdentityCoordinator,
        credentials: IdentityLifecycleCredentialStore
    ) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IdentityLifecycleURLProtocolStub.self]
        return APIClient(
            configuration: APIConfiguration(
                baseURL: URL(string: "https://identity-lifecycle.test")!,
                requestTimeout: 2,
                resourceTimeout: 3
            ),
            session: URLSession(configuration: configuration),
            credentialStore: credentials,
            identityCoordinator: coordinator,
            now: { Date(timeIntervalSince1970: 2_000_000_000) }
        )
    }

    private func installSuccessfulLifecycleHandler(
        events: IdentityLifecycleEventLog
    ) {
        let guestUserID = guestUserID
        IdentityLifecycleURLProtocolStub.setHandler { request in
            switch (request.httpMethod, request.url?.path) {
            case ("DELETE", "/api/v1/auth/me"):
                events.record("network.delete")
                return .init(statusCode: 204, data: Data())
            case ("POST", "/api/v1/auth/guest"):
                events.record("network.guest")
                return .init(
                    statusCode: 200,
                    data: Data(
                        """
                        {
                          "user_id": "\(guestUserID)",
                          "access_token": "guest-access",
                          "refresh_token": "guest-refresh",
                          "token_type": "Bearer",
                          "expires_in": 3600
                        }
                        """.utf8
                    )
                )
            default:
                throw IdentityLifecycleTestError.unexpectedRequest
            }
        }
    }

    private func assertPrivacyCurtain(
        _ appState: AppState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch appState.identityPhase {
        case .blocked, .cleanupRequired, .cleanupBlocked:
            break
        default:
            return XCTFail(
                "Expected a retryable identity privacy curtain.",
                file: file,
                line: line
            )
        }
        XCTAssertNil(appState.privateAppSession, file: file, line: line)
        XCTAssertNil(appState.currentPrincipalScope, file: file, line: line)
        XCTAssertTrue(appState.cachedTrips.isEmpty, file: file, line: line)
        XCTAssertTrue(appState.pendingJobs.isEmpty, file: file, line: line)
    }

    private func waitForEvent(
        _ event: String,
        events: IdentityLifecycleEventLog
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await events.wait(for: event)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw IdentityLifecycleTestError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw IdentityLifecycleTestError.timedOut
            }
            return result
        }
    }

    private func makeEnvironment() -> IdentityLifecycleEnvironment {
        let suiteName = "AppStateIdentityLifecycleTests.\(UUID().uuidString)"
        return IdentityLifecycleEnvironment(
            root: FileManager.default.temporaryDirectory.appending(
                path: suiteName,
                directoryHint: .isDirectory
            ),
            defaults: UserDefaults(suiteName: suiteName)!,
            suiteName: suiteName
        )
    }

    private var establishedIdentity: PrincipalIdentity {
        try! PrincipalIdentity(serverUserID: establishedUserID)
    }

    private var establishedCredentials: AuthCredentials {
        AuthCredentials(
            accessToken: "established-access",
            refreshToken: "established-refresh",
            tokenType: "Bearer",
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
            userID: establishedUserID
        )
    }

    private var establishedUserID: String {
        IdentityLifecycleFixtures.establishedUserID
    }

    private var guestUserID: String {
        IdentityLifecycleFixtures.guestUserID
    }

    private var fixedOperationID: UUID {
        UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    }
}

private enum IdentityLifecycleFixtures {
    static let establishedUserID =
        "aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb"
    static let guestUserID =
        "bbbbbbbb-1111-4222-8333-cccccccccccc"
    static let appleUserID =
        "dddddddd-1111-4222-8333-eeeeeeeeeeee"

    static func tokenResponse(
        userID: String,
        accessToken: String,
        refreshToken: String
    ) -> Data {
        Data(
            """
            {
              "user_id": "\(userID)",
              "access_token": "\(accessToken)",
              "refresh_token": "\(refreshToken)",
              "token_type": "Bearer",
              "expires_in": 3600
            }
            """.utf8
        )
    }
}

private struct IdentityLifecycleEnvironment {
    let root: URL
    let defaults: UserDefaults
    let suiteName: String

    var defaultsDomain: PrivateStorageDefaultsDomain {
        try! PrivateStorageDefaultsDomain(suiteName: suiteName)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private actor IdentityLifecycleSuspensionGate {
    private let event: String
    private let events: IdentityLifecycleEventLog
    private var shouldSuspend = true
    private var continuation: CheckedContinuation<Void, Never>?

    init(event: String, events: IdentityLifecycleEventLog) {
        self.event = event
        self.events = events
    }

    func suspendOnce() async {
        guard shouldSuspend else { return }
        shouldSuspend = false
        events.record(event)
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private final class IdentityLifecycleResponseGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func wait() throws {
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            throw IdentityLifecycleTestError.timedOut
        }
    }

    func release() {
        semaphore.signal()
    }
}

private enum IdentityLifecycleTestError: Error, Equatable, Sendable {
    case journalSaveFailed
    case journalClearFailed
    case credentialClearFailed
    case localPurgeFailed
    case surfaceTearDownFailed
    case unexpectedRequest
    case timedOut
}

private final class IdentityLifecycleEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var waiters: [
        String: [UUID: CheckedContinuation<Void, Error>]
    ] = [:]
    private var cancelledWaiters: Set<UUID> = []

    func record(_ event: String) {
        let continuations: [CheckedContinuation<Void, Error>]
        lock.lock()
        events.append(event)
        if let recordedWaiters = waiters.removeValue(forKey: event) {
            continuations = Array(recordedWaiters.values)
        } else {
            continuations = []
        }
        lock.unlock()
        continuations.forEach { $0.resume() }
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func wait(for event: String) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let outcome: WaitRegistrationOutcome
                lock.lock()
                if events.contains(event) {
                    outcome = .alreadyRecorded
                } else if cancelledWaiters.remove(waiterID) != nil {
                    outcome = .cancelled
                } else {
                    waiters[event, default: [:]][waiterID] = continuation
                    outcome = .registered
                }
                lock.unlock()

                switch outcome {
                case .alreadyRecorded:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .registered:
                    break
                }
            }
        } onCancel: {
            cancelWaiter(waiterID, for: event)
        }
    }

    private func cancelWaiter(_ waiterID: UUID, for event: String) {
        let continuation: CheckedContinuation<Void, Error>?
        lock.lock()
        continuation = waiters[event]?.removeValue(forKey: waiterID)
        if waiters[event]?.isEmpty == true {
            waiters[event] = nil
        }
        if continuation == nil {
            cancelledWaiters.insert(waiterID)
        }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    private enum WaitRegistrationOutcome {
        case alreadyRecorded
        case cancelled
        case registered
    }
}

private actor IdentityLifecycleJournal: PrivateCleanupJournalStoring {
    private var plan: PrivateCleanupPlan?
    private var loadFailure: Bool
    private var localCleanupSaveFailures: Int
    private var clearFailures: Int
    private var evidencePresent: Bool
    private var clearAttempts = 0
    private var saveAttempts: [PrivateCleanupPlan] = []
    private var suspendedSaveStages: [PrivateCleanupStage]
    private var suspendedSaveContinuation: CheckedContinuation<Void, Never>?
    private let observedLegacyPath: String?
    private let events: IdentityLifecycleEventLog

    init(
        plan: PrivateCleanupPlan? = nil,
        loadFailure: Bool = false,
        localCleanupSaveFailures: Int = 0,
        clearFailures: Int = 0,
        suspendNextServerDeletionSave: Bool = false,
        suspendedSaveStages: [PrivateCleanupStage] = [],
        evidencePresent: Bool? = nil,
        observedLegacyPath: String? = nil,
        events: IdentityLifecycleEventLog
    ) {
        self.plan = plan
        self.loadFailure = loadFailure
        self.localCleanupSaveFailures = localCleanupSaveFailures
        self.clearFailures = clearFailures
        self.suspendedSaveStages =
            (suspendNextServerDeletionSave ? [.serverDeletionPending] : [])
            + suspendedSaveStages
        self.evidencePresent = evidencePresent ?? (plan != nil)
        self.observedLegacyPath = observedLegacyPath
        self.events = events
    }

    func load() throws -> PrivateCleanupPlan? {
        events.record("journal.load")
        if let observedLegacyPath {
            events.record(
                FileManager.default.fileExists(atPath: observedLegacyPath)
                    ? "journal.load.legacy-present"
                    : "journal.load.legacy-missing"
            )
        }
        if loadFailure {
            throw LocalDataCleanupError.cleanupJournalUnavailable
        }
        return plan
    }

    func save(_ plan: PrivateCleanupPlan) async throws {
        events.record("journal.save.\(plan.stage.rawValue)")
        saveAttempts.append(plan)
        if suspendedSaveStages.first == plan.stage {
            suspendedSaveStages.removeFirst()
            events.record(
                "journal.save.\(plan.stage.rawValue).suspended"
            )
            await withCheckedContinuation { continuation in
                suspendedSaveContinuation = continuation
            }
        }
        if plan.stage == .localCleanup,
           localCleanupSaveFailures > 0 {
            localCleanupSaveFailures -= 1
            throw IdentityLifecycleTestError.journalSaveFailed
        }
        self.plan = plan
        evidencePresent = true
    }

    func resumeSuspendedSave() {
        suspendedSaveContinuation?.resume()
        suspendedSaveContinuation = nil
    }

    func clear() throws {
        clearAttempts += 1
        events.record("journal.clear")
        if clearFailures > 0 {
            clearFailures -= 1
            throw IdentityLifecycleTestError.journalClearFailed
        }
        plan = nil
        evidencePresent = false
    }

    func currentPlan() -> PrivateCleanupPlan? { plan }
    func savedPlans() -> [PrivateCleanupPlan] { saveAttempts }
    func clearAttemptCount() -> Int { clearAttempts }
    func hasEvidence() -> Bool { evidencePresent }
}

private actor IdentityLifecycleCredentialStore: CredentialStoring {
    private var credentials: AuthCredentials?
    private var savedCredentialValues: [AuthCredentials] = []
    private var clearFailures: Int
    private var clearAttempts = 0
    private let observedLegacyPath: String?
    private let events: IdentityLifecycleEventLog

    init(
        credentials: AuthCredentials?,
        clearFailures: Int = 0,
        observedLegacyPath: String? = nil,
        events: IdentityLifecycleEventLog
    ) {
        self.credentials = credentials
        self.clearFailures = clearFailures
        self.observedLegacyPath = observedLegacyPath
        self.events = events
    }

    func loadCredentials() -> AuthCredentials? {
        if let observedLegacyPath {
            if FileManager.default.fileExists(atPath: observedLegacyPath) {
                events.record("credential.load.legacy-present")
            } else {
                events.record("legacy.quarantine.completed")
            }
        }
        events.record("credential.load")
        return credentials
    }

    func saveCredentials(_ credentials: AuthCredentials) {
        events.record("credential.save")
        savedCredentialValues.append(credentials)
        self.credentials = credentials
    }

    func clearCredentials() throws {
        clearAttempts += 1
        events.record("credential.clear")
        if clearFailures > 0 {
            clearFailures -= 1
            throw IdentityLifecycleTestError.credentialClearFailed
        }
        credentials = nil
    }

    func installationIdentifier() -> String {
        events.record("credential.installation")
        return "identity-lifecycle-installation"
    }

    func currentCredentials() -> AuthCredentials? { credentials }
    func savedCredentials() -> [AuthCredentials] { savedCredentialValues }
    func clearAttemptCount() -> Int { clearAttempts }
}

@MainActor
private final class IdentityLifecycleSurfaceSpy: PrivateSurfaceCoordinating {
    private(set) var activeSession: PrivatePresentationSession?
    private(set) var establishCount = 0
    private(set) var tearDownCount = 0
    private var tearDownFailures: Int
    private var suspendNextEstablish: Bool
    private var suspendedEstablishContinuation: CheckedContinuation<Void, Never>?
    private let events: IdentityLifecycleEventLog

    init(
        activeSession: PrivatePresentationSession?,
        tearDownFailures: Int = 0,
        suspendNextEstablish: Bool = false,
        events: IdentityLifecycleEventLog
    ) {
        self.activeSession = activeSession
        self.tearDownFailures = tearDownFailures
        self.suspendNextEstablish = suspendNextEstablish
        self.events = events
    }

    func establish(session: PrivatePresentationSession) async throws {
        establishCount += 1
        events.record("surface.establish")
        activeSession = session
        if suspendNextEstablish {
            suspendNextEstablish = false
            events.record("surface.establish.suspended")
            await withCheckedContinuation { continuation in
                suspendedEstablishContinuation = continuation
            }
            try Task.checkCancellation()
        }
    }

    func resumeSuspendedEstablish() {
        suspendedEstablishContinuation?.resume()
        suspendedEstablishContinuation = nil
    }

    func tearDown() async throws {
        tearDownCount += 1
        events.record("surface.teardown")
        if tearDownFailures > 0 {
            tearDownFailures -= 1
            throw IdentityLifecycleTestError.surfaceTearDownFailed
        }
        activeSession = nil
    }

    func isCurrent(_ session: PrivatePresentationSession) -> Bool {
        activeSession == session
    }
}

private final class IdentityLifecycleURLProtocolStub: URLProtocol {
    struct Response: Sendable {
        let statusCode: Int
        let data: Data
        let deliveryGate: IdentityLifecycleResponseGate?
        let onDelivery: (@Sendable () -> Void)?

        init(
            statusCode: Int,
            data: Data,
            deliveryGate: IdentityLifecycleResponseGate? = nil,
            onDelivery: (@Sendable () -> Void)? = nil
        ) {
            self.statusCode = statusCode
            self.data = data
            self.deliveryGate = deliveryGate
            self.onDelivery = onDelivery
        }
    }

    private static let handlers = IdentityLifecycleHandlerStorage()

    static func setHandler(
        _ handler: @escaping @Sendable (URLRequest) throws -> Response
    ) {
        handlers.set(handler)
    }

    static func reset() {
        handlers.set(nil)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handlers.get() else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        do {
            let stub = try handler(request)
            if let deliveryGate = stub.deliveryGate {
                let protocolReference =
                    IdentityLifecycleURLProtocolReference(self)
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let receiver = protocolReference.value else {
                        return
                    }
                    do {
                        try deliveryGate.wait()
                        receiver.deliver(stub)
                    } catch {
                        receiver.fail(error)
                    }
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
        stub.onDelivery?()
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

private final class IdentityLifecycleURLProtocolReference:
    @unchecked Sendable {
    weak var value: IdentityLifecycleURLProtocolStub?

    init(_ value: IdentityLifecycleURLProtocolStub) {
        self.value = value
    }
}

private final class IdentityLifecycleHandlerStorage: @unchecked Sendable {
    typealias Handler =
        @Sendable (URLRequest) throws -> IdentityLifecycleURLProtocolStub.Response

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
