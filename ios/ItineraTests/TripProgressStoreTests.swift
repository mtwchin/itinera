import Foundation
import XCTest
@testable import Itinera

final class TripProgressStoreTests: XCTestCase {
    func testProgressPersistsAndUpcomingClearsStoredOverride() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = root.appending(path: "progress.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try PrivateStorageTestContext()

        let activity = try XCTUnwrap(Itinerary.preview.itinerary.first?.activities.first)
        let stopID = TripStopID(tripID: "trip-1", day: 1, activity: activity)
        let store = storage.tripProgressStore(fileURL: fileURL)

        try await store.set(
            .completed,
            for: stopID,
            updatedAt: Date(timeIntervalSince1970: 100),
            lease: storage.lease
        )
        let storedStatus = try await store.status(
            for: stopID,
            lease: storage.lease
        )
        let reloadedStatus = try await storage.tripProgressStore(
            fileURL: fileURL
        ).status(for: stopID, lease: storage.lease)
        XCTAssertEqual(storedStatus, .completed)
        XCTAssertEqual(reloadedStatus, .completed)

        try await store.set(
            .upcoming,
            for: stopID,
            lease: storage.lease
        )
        let clearedStatus = try await store.status(
            for: stopID,
            lease: storage.lease
        )
        let clearedProgress = try await store.progress(
            for: "trip-1",
            lease: storage.lease
        )
        XCTAssertEqual(clearedStatus, .upcoming)
        XCTAssertTrue(clearedProgress.isEmpty)
    }

    func testProgressIsIsolatedByTripAndDay() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = root.appending(path: "progress.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try PrivateStorageTestContext()

        let activity = try XCTUnwrap(Itinerary.preview.itinerary.first?.activities.first)
        let first = TripStopID(tripID: "trip-1", day: 1, activity: activity)
        let otherDay = TripStopID(tripID: "trip-1", day: 2, activity: activity)
        let otherTrip = TripStopID(tripID: "trip-2", day: 1, activity: activity)
        let store = storage.tripProgressStore(fileURL: fileURL)

        try await store.set(
            .completed,
            for: first,
            lease: storage.lease
        )
        try await store.set(
            .skipped,
            for: otherDay,
            lease: storage.lease
        )

        let progress = try await store.progress(
            for: "trip-1",
            lease: storage.lease
        )
        let otherTripStatus = try await store.status(
            for: otherTrip,
            lease: storage.lease
        )
        XCTAssertEqual(progress[first], .completed)
        XCTAssertEqual(progress[otherDay], .skipped)
        XCTAssertEqual(otherTripStatus, .upcoming)
    }

    func testStaleLeaseCannotMutateProgressAfterSamePrincipalReestablishment() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = root.appending(path: "progress.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try PrivateStorageTestContext()
        let activity = try XCTUnwrap(
            Itinerary.preview.itinerary.first?.activities.first
        )
        let stopID = TripStopID(
            tripID: "trip-1",
            day: 1,
            activity: activity
        )
        let staleStore = first.tripProgressStore(fileURL: fileURL)
        try await staleStore.set(
            .completed,
            for: stopID,
            lease: first.lease
        )

        let nextEpoch = try await first.identityCoordinator.beginTransition()
        let nextLease = try await first.identityCoordinator.establish(
            first.lease.scope,
            presentationSessionID: UUID(
                uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
            )!,
            at: nextEpoch
        )

        do {
            try await staleStore.set(
                .skipped,
                for: stopID,
                lease: first.lease
            )
            XCTFail("An expired progress lease must fail before persistence")
        } catch let error as IdentityCoordinatorError {
            XCTAssertEqual(error, .staleIdentity)
        }

        let reestablishedStore = TripProgressStore(
            fileURL: fileURL,
            lease: nextLease,
            identityCoordinator: first.identityCoordinator
        )
        let reestablishedStatus = try await reestablishedStore.status(
            for: stopID,
            lease: nextLease
        )
        XCTAssertEqual(reestablishedStatus, .completed)
    }

    func testSuspendedA1ProgressReadCannotReturnAfterRapidAtoBtoA3Switch()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = root.appending(path: "progress.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try PrivateStorageTestContext()
        let activity = try XCTUnwrap(
            Itinerary.preview.itinerary.first?.activities.first
        )
        let stopID = TripStopID(
            tripID: "trip-a",
            day: 1,
            activity: activity
        )
        let seedStore = first.tripProgressStore(fileURL: fileURL)
        try await seedStore.set(
            .completed,
            for: stopID,
            lease: first.lease
        )

        let gate = ProgressReadGate()
        let staleStore = TripProgressStore(
            fileURL: fileURL,
            lease: first.lease,
            identityCoordinator: first.identityCoordinator,
            beforeRead: { _ in await gate.suspendOnce() }
        )
        let staleRead = Task {
            try await staleStore.progress(
                for: "trip-a",
                lease: first.lease
            )
        }
        await gate.waitUntilSuspended()

        let scopeB = try PrincipalScope(
            validating: String(repeating: "b", count: 64)
        )
        let epochB = try await first.identityCoordinator.beginTransition()
        _ = try await first.identityCoordinator.establish(
            scopeB,
            presentationSessionID: UUID(),
            at: epochB
        )
        let epochA3 = try await first.identityCoordinator.beginTransition()
        let leaseA3 = try await first.identityCoordinator.establish(
            first.lease.scope,
            presentationSessionID: UUID(),
            at: epochA3
        )
        await gate.resume()

        do {
            _ = try await staleRead.value
            XCTFail("A suspended A1 read must not return after A3 is active")
        } catch let error as IdentityCoordinatorError {
            XCTAssertEqual(error, .staleIdentity)
        }

        let currentStore = TripProgressStore(
            fileURL: fileURL,
            lease: leaseA3,
            identityCoordinator: first.identityCoordinator
        )
        let currentStatus = try await currentStore.status(
            for: stopID,
            lease: leaseA3
        )
        XCTAssertEqual(currentStatus, .completed)
    }

    func testA1ProgressCapabilityRejectsSamePrincipalA3Publication()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = root.appending(path: "progress.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try PrivateStorageTestContext()
        let staleCapability = SessionBoundTripProgressStore(
            store: first.tripProgressStore(fileURL: fileURL),
            lease: first.lease,
            identityCoordinator: first.identityCoordinator
        )
        let capturedA1Value = try await staleCapability.progress(
            for: "trip-a"
        )

        let scopeB = try PrincipalScope(
            validating: String(repeating: "b", count: 64)
        )
        let epochB = try await first.identityCoordinator.beginTransition()
        _ = try await first.identityCoordinator.establish(
            scopeB,
            presentationSessionID: UUID(),
            at: epochB
        )
        let epochA3 = try await first.identityCoordinator.beginTransition()
        _ = try await first.identityCoordinator.establish(
            first.lease.scope,
            presentationSessionID: UUID(),
            at: epochA3
        )

        do {
            _ = try await staleCapability.progress(for: "trip-a")
            XCTFail("An A1 capability must reject reads after A3")
        } catch let error as IdentityCoordinatorError {
            XCTAssertEqual(error, .staleIdentity)
        }
        let canPublishA1 = await staleCapability.canPublish(capturedA1Value)
        XCTAssertFalse(canPublishA1)
    }
}

private actor ProgressReadGate {
    private var isSuspended = false
    private var didResumeEarly = false
    private var suspension: CheckedContinuation<Void, Never>?
    private var arrivals: [CheckedContinuation<Void, Never>] = []

    func suspendOnce() async {
        guard !isSuspended else { return }
        isSuspended = true
        arrivals.forEach { $0.resume() }
        arrivals.removeAll()
        await withCheckedContinuation { continuation in
            if didResumeEarly {
                continuation.resume()
            } else {
                suspension = continuation
            }
        }
    }

    func waitUntilSuspended() async {
        if isSuspended { return }
        await withCheckedContinuation { continuation in
            arrivals.append(continuation)
        }
    }

    func resume() {
        didResumeEarly = true
        suspension?.resume()
        suspension = nil
    }
}
