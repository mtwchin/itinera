import Foundation
import XCTest
@testable import Itinera

final class LocalPrincipalScopeTests: XCTestCase {
    func testScopeIsStableOpaqueAndDistinctPerPrincipal() throws {
        let firstID = "11111111-2222-3333-4444-555555555555"
        let secondID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let first = try XCTUnwrap(LocalPrincipalScope(userID: firstID))
        let repeatFirst = try XCTUnwrap(LocalPrincipalScope(userID: firstID.uppercased()))
        let second = try XCTUnwrap(LocalPrincipalScope(userID: secondID))

        XCTAssertEqual(first, repeatFirst)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.digest.contains(firstID.replacingOccurrences(of: "-", with: "")))
        let defaultsKey = first.defaultsKey(name: "trip-draft-v1")
        XCTAssertFalse(defaultsKey.contains(firstID))
        XCTAssertNotEqual(defaultsKey, second.defaultsKey(name: "trip-draft-v1"))
        XCTAssertNil(LocalPrincipalScope(userID: "not-a-uuid"))
    }

    func testScopedOfflineStoresDoNotCrossPrincipals() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try XCTUnwrap(
            LocalPrincipalScope(userID: "11111111-2222-3333-4444-555555555555")
        )
        let second = try XCTUnwrap(
            LocalPrincipalScope(userID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        )
        let firstCache = CompletedTripCache.live(scope: first, root: root)
        let secondCache = CompletedTripCache.live(scope: second, root: root)
        let firstJobs = PendingJobStore.live(scope: first, root: root)
        let secondJobs = PendingJobStore.live(scope: second, root: root)
        let firstSubmissions = PendingSubmissionStore.live(scope: first, root: root)
        let secondSubmissions = PendingSubmissionStore.live(scope: second, root: root)
        let firstProgress = TripProgressStore.live(scope: first, root: root)
        let secondProgress = TripProgressStore.live(scope: second, root: root)

        _ = try await firstCache.replace(with: [SavedItinerary(
            jobId: "trip-a",
            status: .succeeded,
            title: "Private trip",
            sourcePublicItineraryId: nil,
            city: "Lisbon",
            country: "Portugal",
            arrivalDate: "2026-08-01",
            departureDate: "2026-08-02",
            result: .preview,
            error: nil,
            archivedAt: nil,
            version: 1,
            createdAt: "2026-01-01T00:00:00Z"
        )])

        let firstSnapshot = try await firstCache.load()
        let secondSnapshot = try await secondCache.load()
        _ = try await firstJobs.add(jobID: "pending-a", title: "Private queue")
        _ = try await firstSubmissions.record(
            for: GenerateItineraryRequest(
                city: "Lisbon",
                country: "Portugal",
                accommodation: Accommodation(address: "Rua Augusta", lat: 38.7, lng: -9.1),
                arrivalDate: "2026-08-01",
                departureDate: "2026-08-02",
                groupSize: 2,
                wakeUpTime: "08:00",
                foodPreferences: nil,
                mustDo: nil,
                budget: "Medium"
            ),
            title: "Private submission"
        )
        let stopID = TripStopID(
            tripID: "trip-a",
            day: 1,
            activity: Itinerary.preview.itinerary[0].activities[0]
        )
        try await firstProgress.set(.completed, for: stopID)
        let firstPendingJobs = try await firstJobs.all()
        let secondPendingJobs = try await secondJobs.all()
        let firstPendingSubmissions = try await firstSubmissions.all()
        let secondPendingSubmissions = try await secondSubmissions.all()
        let firstStopStatus = try await firstProgress.status(for: stopID)
        let secondStopStatus = try await secondProgress.status(for: stopID)
        XCTAssertEqual(firstSnapshot?.trips.map(\.jobId), ["trip-a"])
        XCTAssertNil(secondSnapshot)
        XCTAssertEqual(firstPendingJobs.map(\.jobID), ["pending-a"])
        XCTAssertTrue(secondPendingJobs.isEmpty)
        XCTAssertEqual(firstPendingSubmissions.count, 1)
        XCTAssertTrue(secondPendingSubmissions.isEmpty)
        XCTAssertEqual(firstStopStatus, .completed)
        XCTAssertEqual(secondStopStatus, .upcoming)
        XCTAssertNotEqual(
            first.fileURL(root: root, name: "completed-trips-v1.json"),
            second.fileURL(root: root, name: "completed-trips-v1.json")
        )
    }
}
