import Foundation
import XCTest
@testable import Itinera

final class TripProgressStoreTests: XCTestCase {
    func testProgressPersistsAndUpcomingClearsStoredOverride() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = root.appending(path: "progress.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let activity = try XCTUnwrap(Itinerary.preview.itinerary.first?.activities.first)
        let stopID = TripStopID(tripID: "trip-1", day: 1, activity: activity)
        let store = TripProgressStore(fileURL: fileURL)

        try await store.set(
            .completed,
            for: stopID,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let storedStatus = try await store.status(for: stopID)
        let reloadedStatus = try await TripProgressStore(
            fileURL: fileURL
        ).status(for: stopID)
        XCTAssertEqual(storedStatus, .completed)
        XCTAssertEqual(reloadedStatus, .completed)

        try await store.set(.upcoming, for: stopID)
        let clearedStatus = try await store.status(for: stopID)
        let clearedProgress = try await store.progress(for: "trip-1")
        XCTAssertEqual(clearedStatus, .upcoming)
        XCTAssertTrue(clearedProgress.isEmpty)
    }

    func testProgressIsIsolatedByTripAndDay() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = root.appending(path: "progress.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let activity = try XCTUnwrap(Itinerary.preview.itinerary.first?.activities.first)
        let first = TripStopID(tripID: "trip-1", day: 1, activity: activity)
        let otherDay = TripStopID(tripID: "trip-1", day: 2, activity: activity)
        let otherTrip = TripStopID(tripID: "trip-2", day: 1, activity: activity)
        let store = TripProgressStore(fileURL: fileURL)

        try await store.set(.completed, for: first)
        try await store.set(.skipped, for: otherDay)

        let progress = try await store.progress(for: "trip-1")
        let otherTripStatus = try await store.status(for: otherTrip)
        XCTAssertEqual(progress[first], .completed)
        XCTAssertEqual(progress[otherDay], .skipped)
        XCTAssertEqual(otherTripStatus, .upcoming)
    }
}
