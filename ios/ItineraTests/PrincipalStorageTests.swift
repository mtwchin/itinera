import CryptoKit
import Foundation
import XCTest
@testable import Itinera

final class PrincipalStorageTests: XCTestCase {
    func testLayoutAndDefaultsKeysUseOnlyOpaqueScope() throws {
        let root = temporaryRoot()
        let rawServerID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let scope = try PrincipalScope(
            validating: String(repeating: "1a", count: 32)
        )
        let layout = PrincipalStorageLayout(
            applicationSupportDirectory: root,
            scope: scope
        )

        let expectedDirectory = root
            .appending(path: "Itinera", directoryHint: .isDirectory)
            .appending(path: "private", directoryHint: .isDirectory)
            .appending(path: "v1", directoryHint: .isDirectory)
            .appending(path: scope.digest, directoryHint: .isDirectory)
        XCTAssertEqual(layout.scopeDirectory, expectedDirectory)
        XCTAssertEqual(
            layout.completedTripsURL.lastPathComponent,
            "completed-trips-v1.json"
        )
        XCTAssertEqual(
            layout.pendingSubmissionsURL.lastPathComponent,
            "pending-submissions.json"
        )

        let draftKey = ItineraLocalDataKeys.tripDraft(for: scope)
        let lockKey = ItineraLocalDataKeys.lockedStops(
            for: "trip-1",
            scope: scope
        )
        for value in [
            layout.completedTripsURL.path,
            layout.tripProgressURL.path,
            layout.pendingJobsURL.path,
            layout.pendingSubmissionsURL.path,
            draftKey,
            lockKey
        ] {
            XCTAssertTrue(value.contains(scope.digest))
            XCTAssertFalse(value.contains(rawServerID))
        }
    }

    func testEveryPrivateStoreAndDefaultsAreIsolatedAcrossRelaunch()
        async throws {
        let root = temporaryRoot()
        let suiteName = "PrincipalStorageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let identityCoordinator = IdentityCoordinator()
        let factory = PrincipalStorageFactory(
            applicationSupportDirectory: root,
            identityCoordinator: identityCoordinator
        )
        let scopeA = try PrincipalScope(
            validating: String(repeating: "a", count: 64)
        )
        let scopeB = try PrincipalScope(
            validating: String(repeating: "b", count: 64)
        )
        let leaseA1 = try await transition(
            identityCoordinator,
            to: scopeA,
            sessionID: UUID(
                uuidString: "11111111-1111-4111-8111-111111111111"
            )!
        )
        let storesA = factory.makeStoreSet(
            for: leaseA1,
            defaultsDomain: try PrivateStorageDefaultsDomain(
                suiteName: suiteName
            )
        )
        let serverLeaseA1 = try await identityCoordinator
            .captureServerOperationLease(ifCurrent: leaseA1)

        _ = try await storesA.completedTripCache.replace(
            with: [savedTrip(id: "trip-a")],
            lease: leaseA1
        )

        let activity = try XCTUnwrap(
            Itinerary.preview.itinerary.first?.activities.first
        )
        let stopA = TripStopID(tripID: "trip-a", day: 1, activity: activity)
        let stopB = TripStopID(tripID: "trip-b", day: 1, activity: activity)
        try await storesA.tripProgressStore.set(
            .completed,
            for: stopA,
            lease: leaseA1
        )

        _ = try await storesA.pendingJobStore.add(
            jobID: "job-a",
            title: "A",
            lease: leaseA1,
            serverOperationLease: serverLeaseA1
        )
        _ = try await storesA.pendingSubmissionStore.record(
            for: sampleRequest(city: "Lisbon"),
            title: "A",
            lease: leaseA1,
            serverOperationLease: serverLeaseA1
        )
        try await storesA.localDataStore.saveTripDraftData(
            Data("draft-a".utf8),
            lease: leaseA1
        )
        try await storesA.localDataStore.saveLockedActivityIDs(
            ["activity-a"],
            for: "trip-a",
            lease: leaseA1
        )

        let leaseB2 = try await transition(
            identityCoordinator,
            to: scopeB,
            sessionID: UUID(
                uuidString: "22222222-2222-4222-8222-222222222222"
            )!
        )
        let storesB = factory.makeStoreSet(
            for: leaseB2,
            defaultsDomain: try PrivateStorageDefaultsDomain(
                suiteName: suiteName
            )
        )
        let serverLeaseB2 = try await identityCoordinator
            .captureServerOperationLease(ifCurrent: leaseB2)
        _ = try await storesB.completedTripCache.replace(
            with: [savedTrip(id: "trip-b")],
            lease: leaseB2
        )
        try await storesB.tripProgressStore.set(
            .skipped,
            for: stopB,
            lease: leaseB2
        )
        _ = try await storesB.pendingJobStore.add(
            jobID: "job-b",
            title: "B",
            lease: leaseB2,
            serverOperationLease: serverLeaseB2
        )
        _ = try await storesB.pendingSubmissionStore.record(
            for: sampleRequest(city: "Tokyo"),
            title: "B",
            lease: leaseB2,
            serverOperationLease: serverLeaseB2
        )
        try await storesB.localDataStore.saveTripDraftData(
            Data("draft-b".utf8),
            lease: leaseB2
        )
        try await storesB.localDataStore.saveLockedActivityIDs(
            ["activity-b"],
            for: "trip-b",
            lease: leaseB2
        )
        let statusBB = try await storesB.tripProgressStore.status(
            for: stopB,
            lease: leaseB2
        )

        let leaseA3 = try await transition(
            identityCoordinator,
            to: scopeA,
            sessionID: UUID(
                uuidString: "33333333-3333-4333-8333-333333333333"
            )!
        )
        let relaunchedA = factory.makeStoreSet(
            for: leaseA3,
            defaultsDomain: try PrivateStorageDefaultsDomain(
                suiteName: suiteName
            )
        )
        let relaunchedB = storesB
        let tripsA = try await relaunchedA.completedTripCache.load()
        let tripsB = try await relaunchedB.completedTripCache.load()
        let statusAA = try await relaunchedA.tripProgressStore.status(
            for: stopA,
            lease: leaseA3
        )
        let statusAB = try await relaunchedA.tripProgressStore.status(
            for: stopB,
            lease: leaseA3
        )
        let pendingA = try await relaunchedA.pendingJobStore.all()
        let pendingB = try await relaunchedB.pendingJobStore.all()
        let submissionsA = try await relaunchedA.pendingSubmissionStore.all()
        let submissionsB = try await relaunchedB.pendingSubmissionStore.all()
        let draftA = await relaunchedA.localDataStore.tripDraftData()
        let draftB = await relaunchedB.localDataStore.tripDraftData()
        let locksA = await relaunchedA.localDataStore.lockedActivityIDs(
            for: "trip-a"
        )
        let locksB = await relaunchedB.localDataStore.lockedActivityIDs(
            for: "trip-b"
        )
        XCTAssertFalse(
            storesA.completedTripCache === relaunchedA.completedTripCache
        )
        XCTAssertEqual(tripsA?.trips.map(\.jobId), ["trip-a"])
        XCTAssertEqual(tripsB?.trips.map(\.jobId), ["trip-b"])
        XCTAssertEqual(statusAA, .completed)
        XCTAssertEqual(statusAB, .upcoming)
        XCTAssertEqual(statusBB, .skipped)
        XCTAssertEqual(pendingA.map(\.jobID), ["job-a"])
        XCTAssertEqual(pendingB.map(\.jobID), ["job-b"])
        XCTAssertEqual(submissionsA.map(\.request.city), ["Lisbon"])
        XCTAssertEqual(submissionsB.map(\.request.city), ["Tokyo"])
        XCTAssertEqual(draftA, Data("draft-a".utf8))
        XCTAssertEqual(draftB, Data("draft-b".utf8))
        XCTAssertEqual(locksA, ["activity-a"])
        XCTAssertEqual(locksB, ["activity-b"])
        XCTAssertEqual(
            defaults.data(
                forKey: ItineraLocalDataKeys.tripDraft(for: scopeA)
            ),
            Data("draft-a".utf8)
        )
        XCTAssertEqual(
            defaults.stringArray(
                forKey: ItineraLocalDataKeys.lockedStops(
                    for: "trip-b",
                    scope: scopeB
                )
            ),
            ["activity-b"]
        )
    }

    func testLegacyQuarantineIsOpaqueCompleteAndIdempotent() async throws {
        let root = temporaryRoot()
        let suiteName = "PrincipalStorageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let itineraDirectory = root.appending(
            path: "Itinera",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: itineraDirectory,
            withIntermediateDirectories: true
        )
        let invalidPendingPayload = Data("never decode or submit".utf8)
        for (index, fileName) in
            PrincipalStorageLayout.legacyFileNames.enumerated() {
            let data = fileName == "pending-submissions.json"
                ? invalidPendingPayload
                : Data("legacy-\(index)".utf8)
            try data.write(
                to: itineraDirectory.appending(path: fileName),
                options: [.atomic]
            )
        }
        defaults.set(
            Data("legacy-draft".utf8),
            forKey: ItineraLegacyPrivateDataKeys.tripDraft
        )
        defaults.set(
            ["legacy-lock"],
            forKey: ItineraLegacyPrivateDataKeys.lockedStopsPrefix + "trip"
        )

        let identityCoordinator = IdentityCoordinator()
        let factory = PrincipalStorageFactory(
            applicationSupportDirectory: root,
            identityCoordinator: identityCoordinator
        )
        let report = try factory.quarantineLegacyPrivateData(
            defaults: defaults
        )

        XCTAssertEqual(report.retainedFileURLs.count, 4)
        XCTAssertEqual(report.removedDefaultsCount, 2)
        for fileName in PrincipalStorageLayout.legacyFileNames {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: itineraDirectory.appending(path: fileName).path
                )
            )
        }
        XCTAssertNil(
            defaults.object(forKey: ItineraLegacyPrivateDataKeys.tripDraft)
        )
        XCTAssertNil(
            defaults.object(
                forKey:
                    ItineraLegacyPrivateDataKeys.lockedStopsPrefix + "trip"
            )
        )
        let quarantinedPending = try XCTUnwrap(
            report.retainedFileURLs.first {
                $0.lastPathComponent == "pending-submissions.json"
            }
        )
        XCTAssertEqual(
            try Data(contentsOf: quarantinedPending),
            invalidPendingPayload
        )

        let scope = try PrincipalScope(
            validating: String(repeating: "c", count: 64)
        )
        let lease = try await transition(
            identityCoordinator,
            to: scope,
            sessionID: UUID(
                uuidString: "44444444-4444-4444-8444-444444444444"
            )!
        )
        let scopedStores = factory.makeStoreSet(
            for: lease,
            defaultsDomain: try PrivateStorageDefaultsDomain(
                suiteName: suiteName
            )
        )
        let scopedSubmissions = try await scopedStores.pendingSubmissionStore
            .all()
        let scopedJobs = try await scopedStores.pendingJobStore.all()
        XCTAssertTrue(scopedSubmissions.isEmpty)
        XCTAssertTrue(scopedJobs.isEmpty)

        let secondReport = try factory.quarantineLegacyPrivateData(
            defaults: defaults
        )
        XCTAssertEqual(secondReport.retainedFileURLs, [])
        XCTAssertEqual(secondReport.removedDefaultsCount, 0)

        try factory.purgeQuarantine()
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: itineraDirectory
                    .appending(path: "quarantine", directoryHint: .isDirectory)
                    .path
            )
        )
    }

    func testQuarantineCollisionRetainsBothAndAlwaysRemovesGlobalPath()
        throws {
        let root = temporaryRoot()
        let suiteName = "PrincipalStorageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let itineraDirectory = root.appending(
            path: "Itinera",
            directoryHint: .isDirectory
        )
        let quarantineDirectory = itineraDirectory
            .appending(path: "quarantine", directoryHint: .isDirectory)
            .appending(path: "unscoped-v1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: quarantineDirectory,
            withIntermediateDirectories: true
        )
        let fileName = PrincipalStorageLayout.completedTripsFileName
        let sourceURL = itineraDirectory.appending(path: fileName)
        let fixedURL = quarantineDirectory.appending(path: fileName)
        let oldData = Data("first retained version".utf8)
        let newData = Data("second retained version".utf8)
        try oldData.write(to: fixedURL)
        try newData.write(to: sourceURL)

        let factory = PrincipalStorageFactory(
            applicationSupportDirectory: root,
            identityCoordinator: IdentityCoordinator()
        )
        let report = try factory.quarantineLegacyPrivateData(
            defaults: defaults
        )
        let digest = SHA256.hash(data: newData)
            .map { String(format: "%02x", $0) }
            .joined()
        let collisionURL = quarantineDirectory.appending(
            path: "completed-trips-v1.\(digest).json"
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try Data(contentsOf: fixedURL), oldData)
        XCTAssertEqual(try Data(contentsOf: collisionURL), newData)
        XCTAssertEqual(report.retainedFileURLs, [collisionURL])

        // A rollback can recreate the same unsafe path. The retained copy is
        // reused, but the global path is still removed deterministically.
        try newData.write(to: sourceURL)
        let replayReport = try factory.quarantineLegacyPrivateData(
            defaults: defaults
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(replayReport.retainedFileURLs, [collisionURL])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: quarantineDirectory,
                includingPropertiesForKeys: nil
            ).count,
            2
        )
    }

    func testQuarantineSecurityFailureKeepsGlobalSourceAndRetryResecuresCopy()
        throws {
        let root = temporaryRoot()
        let suiteName = "PrincipalStorageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let itineraDirectory = root.appending(
            path: "Itinera",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: itineraDirectory,
            withIntermediateDirectories: true
        )
        let fileName = PrincipalStorageLayout.pendingSubmissionsFileName
        let sourceURL = itineraDirectory.appending(path: fileName)
        let retainedURL = itineraDirectory
            .appending(path: "quarantine", directoryHint: .isDirectory)
            .appending(path: "unscoped-v1", directoryHint: .isDirectory)
            .appending(path: fileName)
        let opaqueBytes = Data("never submit these bytes".utf8)
        try opaqueBytes.write(to: sourceURL)
        defaults.set(
            Data("ambiguous draft".utf8),
            forKey: ItineraLegacyPrivateDataKeys.tripDraft
        )

        let securer = FailOnceQuarantineSecurer()
        let factory = PrincipalStorageFactory(
            applicationSupportDirectory: root,
            identityCoordinator: IdentityCoordinator(),
            secureQuarantineFile: { url, fileManager in
                try securer.secure(url, fileManager: fileManager)
            }
        )

        XCTAssertThrowsError(
            try factory.quarantineLegacyPrivateData(defaults: defaults)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try Data(contentsOf: sourceURL), opaqueBytes)
        XCTAssertEqual(try Data(contentsOf: retainedURL), opaqueBytes)
        XCTAssertNotNil(
            defaults.object(forKey: ItineraLegacyPrivateDataKeys.tripDraft)
        )

        let retry = try factory.quarantineLegacyPrivateData(
            defaults: defaults
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(retry.retainedFileURLs, [retainedURL])
        XCTAssertEqual(try Data(contentsOf: retainedURL), opaqueBytes)
        XCTAssertNil(
            defaults.object(forKey: ItineraLegacyPrivateDataKeys.tripDraft)
        )
        XCTAssertEqual(securer.securedURLs, [retainedURL])
        XCTAssertEqual(securer.attemptedURLs, [retainedURL, retainedURL])

        let noSourceRetry = try factory.quarantineLegacyPrivateData(
            defaults: defaults
        )
        XCTAssertTrue(noSourceRetry.retainedFileURLs.isEmpty)
        XCTAssertEqual(
            securer.attemptedURLs,
            [retainedURL, retainedURL, retainedURL]
        )
    }

    func testPurgeCurrentScopeDoesNotTouchAnotherPrincipal() async throws {
        let root = temporaryRoot()
        let suiteName = "PrincipalStorageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let identityCoordinator = IdentityCoordinator()
        let factory = PrincipalStorageFactory(
            applicationSupportDirectory: root,
            identityCoordinator: identityCoordinator
        )
        let scopeA = try PrincipalScope(
            validating: String(repeating: "d", count: 64)
        )
        let scopeB = try PrincipalScope(
            validating: String(repeating: "e", count: 64)
        )
        let leaseA1 = try await transition(
            identityCoordinator,
            to: scopeA,
            sessionID: UUID(
                uuidString: "55555555-5555-4555-8555-555555555555"
            )!
        )
        let storesA = factory.makeStoreSet(
            for: leaseA1,
            defaultsDomain: try PrivateStorageDefaultsDomain(
                suiteName: suiteName
            )
        )
        let serverLeaseA1 = try await identityCoordinator
            .captureServerOperationLease(ifCurrent: leaseA1)
        _ = try await storesA.pendingJobStore.add(
            jobID: "a",
            title: nil,
            lease: leaseA1,
            serverOperationLease: serverLeaseA1
        )
        try await storesA.localDataStore.saveTripDraftData(
            Data("a".utf8),
            lease: leaseA1
        )

        let leaseB2 = try await transition(
            identityCoordinator,
            to: scopeB,
            sessionID: UUID(
                uuidString: "66666666-6666-4666-8666-666666666666"
            )!
        )
        let storesB = factory.makeStoreSet(
            for: leaseB2,
            defaultsDomain: try PrivateStorageDefaultsDomain(
                suiteName: suiteName
            )
        )
        let serverLeaseB2 = try await identityCoordinator
            .captureServerOperationLease(ifCurrent: leaseB2)
        _ = try await storesB.pendingJobStore.add(
            jobID: "b",
            title: nil,
            lease: leaseB2,
            serverOperationLease: serverLeaseB2
        )
        try await storesB.localDataStore.saveTripDraftData(
            Data("b".utf8),
            lease: leaseB2
        )

        let cleanupEpoch = try await identityCoordinator.beginTransition()
        try await factory.purgeCurrentScope(
            scopeA,
            at: cleanupEpoch,
            defaultsDomain: try PrivateStorageDefaultsDomain(
                suiteName: suiteName
            )
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: factory.layout(for: scopeA).scopeDirectory.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: factory.layout(for: scopeB).pendingJobsURL.path
            )
        )
        XCTAssertNil(
            defaults.data(
                forKey: ItineraLocalDataKeys.tripDraft(for: scopeA)
            )
        )
        XCTAssertEqual(
            defaults.data(
                forKey: ItineraLocalDataKeys.tripDraft(for: scopeB)
            ),
            Data("b".utf8)
        )
    }

    func testSuspendedA1WriteCannotCommitAfterRapidAtoBtoA3Switch()
        async throws {
        let root = temporaryRoot()
        let suiteName = "PrincipalStorageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let scopeA = try PrincipalScope(
            validating: String(repeating: "a", count: 64)
        )
        let scopeB = try PrincipalScope(
            validating: String(repeating: "b", count: 64)
        )
        let identityCoordinator = IdentityCoordinator()
        let suspension = MutationCommitSuspension()
        let factory = PrincipalStorageFactory(
            applicationSupportDirectory: root,
            identityCoordinator: identityCoordinator,
            beforeCommit: { lease in
                await suspension.pauseIfArmed(lease)
            }
        )
        let leaseA1 = try await transition(
            identityCoordinator,
            to: scopeA,
            sessionID: UUID(
                uuidString: "77777777-7777-4777-8777-777777777777"
            )!
        )
        let storesA1 = factory.makeStoreSet(
            for: leaseA1,
            defaultsDomain: try PrivateStorageDefaultsDomain(
                suiteName: suiteName
            )
        )
        _ = try await storesA1.completedTripCache.replace(
            with: [savedTrip(id: "a1-original")],
            lease: leaseA1
        )

        await suspension.arm(leaseA1)
        let staleTrip = savedTrip(id: "a1-stale")
        let staleWrite = Task {
            try await storesA1.completedTripCache.replace(
                with: [staleTrip],
                lease: leaseA1
            )
        }
        defer {
            Task { await suspension.release() }
        }
        await suspension.waitUntilSuspended()

        _ = try await transition(
            identityCoordinator,
            to: scopeB,
            sessionID: UUID(
                uuidString: "88888888-8888-4888-8888-888888888888"
            )!
        )
        let leaseA3 = try await transition(
            identityCoordinator,
            to: scopeA,
            sessionID: UUID(
                uuidString: "99999999-9999-4999-8999-999999999999"
            )!
        )
        let storesA3 = factory.makeStoreSet(
            for: leaseA3,
            defaultsDomain: try PrivateStorageDefaultsDomain(
                suiteName: suiteName
            )
        )
        _ = try await storesA3.completedTripCache.replace(
            with: [savedTrip(id: "a3-current")],
            lease: leaseA3
        )
        try await storesA3.localDataStore.saveTripDraftData(
            Data("a3-current".utf8),
            lease: leaseA3
        )
        do {
            try await storesA1.localDataStore.saveTripDraftData(
                Data("a1-stale".utf8),
                lease: leaseA1
            )
            XCTFail("The A1 draft write must be rejected after A3.")
        } catch let error as IdentityCoordinatorError {
            XCTAssertEqual(error, .staleIdentity)
        }

        await suspension.release()
        do {
            _ = try await staleWrite.value
            XCTFail("The A1 write must be rejected after A3 is established.")
        } catch let error as IdentityCoordinatorError {
            XCTAssertEqual(error, .staleIdentity)
        }

        let relaunchedA3 = factory.makeStoreSet(
            for: leaseA3,
            defaultsDomain: try PrivateStorageDefaultsDomain(
                suiteName: suiteName
            )
        )
        let diskSnapshot = try await relaunchedA3.completedTripCache.load()
        let draftData = await relaunchedA3.localDataStore.tripDraftData()
        XCTAssertEqual(diskSnapshot?.trips.map(\.jobId), ["a3-current"])
        XCTAssertEqual(draftData, Data("a3-current".utf8))
    }

    func testSuspendedQueueWriteCannotCommitAfterRecoveryPauseAndResume()
        async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try PrincipalScope(
            validating: String(repeating: "f", count: 64)
        )
        let identityCoordinator = IdentityCoordinator()
        let suspension = MutationCommitSuspension()
        let factory = PrincipalStorageFactory(
            applicationSupportDirectory: root,
            identityCoordinator: identityCoordinator,
            beforeCommit: { lease in
                await suspension.pauseIfArmed(lease)
            }
        )
        let lease = try await transition(
            identityCoordinator,
            to: scope,
            sessionID: UUID(
                uuidString: "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
            )!
        )
        let firstServerLease = try await identityCoordinator
            .captureServerOperationLease(ifCurrent: lease)
        let stores = factory.makeStoreSet(for: lease)
        _ = try await stores.pendingJobStore.add(
            jobID: "safe-original",
            title: nil,
            lease: lease,
            serverOperationLease: firstServerLease
        )

        await suspension.arm(lease)
        let suspendedWrite = Task {
            try await stores.pendingJobStore.add(
                jobID: "stale-during-recovery",
                title: nil,
                lease: lease,
                serverOperationLease: firstServerLease
            )
        }
        defer { Task { await suspension.release() } }
        await suspension.waitUntilSuspended()

        try await identityCoordinator.pauseServerOperations(
            ifCurrent: firstServerLease
        )
        let recoveryLease = try await identityCoordinator
            .beginServerRecovery(ifCurrent: lease)
        let resumedServerLease = try await identityCoordinator
            .resumeServerOperations(ifCurrent: recoveryLease)
        await suspension.release()

        do {
            _ = try await suspendedWrite.value
            XCTFail("A pre-recovery queue capability must not commit.")
        } catch let error as IdentityCoordinatorError {
            XCTAssertEqual(error, .staleIdentity)
        }

        _ = try await stores.pendingJobStore.add(
            jobID: "safe-after-recovery",
            title: nil,
            lease: lease,
            serverOperationLease: resumedServerLease
        )
        let reloaded = try await factory.makeStoreSet(for: lease)
            .pendingJobStore.all()
        XCTAssertEqual(
            Set(reloaded.map(\.jobID)),
            Set(["safe-original", "safe-after-recovery"])
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    private func transition(
        _ coordinator: IdentityCoordinator,
        to scope: PrincipalScope,
        sessionID: UUID
    ) async throws -> IdentityLease {
        let epoch = try await coordinator.beginTransition()
        return try await coordinator.establish(
            scope,
            presentationSessionID: sessionID,
            at: epoch
        )
    }

    private func savedTrip(id: String) -> SavedItinerary {
        SavedItinerary(
            jobId: id,
            status: .succeeded,
            title: id,
            sourcePublicItineraryId: nil,
            city: "Lisbon",
            country: "Portugal",
            arrivalDate: "2026-08-01",
            departureDate: "2026-08-03",
            result: .preview,
            error: nil,
            createdAt: "2026-01-01T00:00:00Z"
        )
    }

    private func sampleRequest(city: String) -> GenerateItineraryRequest {
        GenerateItineraryRequest(
            city: city,
            country: city == "Tokyo" ? "Japan" : "Portugal",
            accommodation: Accommodation(
                address: "Home",
                lat: 38.7,
                lng: -9.1
            ),
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

private actor MutationCommitSuspension {
    private var targetLease: IdentityLease?
    private var didSuspend = false
    private var releaseRequested = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var reachedContinuations: [CheckedContinuation<Void, Never>] = []

    func arm(_ lease: IdentityLease) {
        targetLease = lease
    }

    func pauseIfArmed(_ lease: IdentityLease) async {
        guard lease == targetLease, !didSuspend else { return }
        didSuspend = true
        reachedContinuations.forEach { $0.resume() }
        reachedContinuations.removeAll()
        await withCheckedContinuation { continuation in
            if releaseRequested {
                continuation.resume()
            } else {
                releaseContinuation = continuation
            }
        }
    }

    func waitUntilSuspended() async {
        if didSuspend { return }
        await withCheckedContinuation { continuation in
            reachedContinuations.append(continuation)
        }
    }

    func release() {
        releaseRequested = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class FailOnceQuarantineSecurer {
    private(set) var attemptedURLs: [URL] = []
    private(set) var securedURLs: [URL] = []
    private var shouldFail = true

    func secure(_ url: URL, fileManager: FileManager) throws {
        attemptedURLs.append(url)
        if shouldFail {
            shouldFail = false
            throw CocoaError(.fileWriteNoPermission)
        }
        try PrivateStorageFileSystem.secureFile(
            at: url,
            fileManager: fileManager
        )
        securedURLs.append(url)
    }
}
