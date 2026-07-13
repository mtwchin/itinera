import Foundation
import XCTest
@testable import Itinera

final class CompletedTripCacheTests: XCTestCase {
    func testCachePersistsOnlyCompletedTripsAcrossInstances() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "completed.json")

        let ready = savedTrip(id: "ready", status: .succeeded, result: .preview)
        let pending = savedTrip(id: "pending", status: .pending, result: nil)
        let failed = savedTrip(id: "failed", status: .failed, result: nil)
        let refreshDate = Date(timeIntervalSince1970: 1_000)

        let store = CompletedTripCache(fileURL: fileURL)
        let written = try await store.replace(
            with: [pending, failed, ready],
            refreshedAt: refreshDate
        )
        XCTAssertEqual(written.trips.map(\.jobId), ["ready"])
        XCTAssertEqual(written.refreshedAt, refreshDate)

        let reloaded = try await CompletedTripCache(fileURL: fileURL).load()
        XCTAssertEqual(reloaded?.trips.map(\.jobId), ["ready"])
        XCTAssertEqual(reloaded?.trips.first?.result, .preview)
        XCTAssertEqual(reloaded?.refreshedAt, refreshDate)
    }

    func testUpsertReplacesTripWithoutDuplicatingIt() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "completed.json")
        let store = CompletedTripCache(fileURL: fileURL)

        _ = try await store.upsert(
            savedTrip(id: "ready", title: "First", result: .preview)
        )
        let snapshot = try await store.upsert(
            savedTrip(id: "ready", title: "Renamed", result: .preview)
        )

        XCTAssertEqual(snapshot.trips.count, 1)
        XCTAssertEqual(snapshot.trips.first?.title, "Renamed")
    }

    func testRenameAndRemoveKeepCacheFreshnessTimestamp() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "completed.json")
        let store = CompletedTripCache(fileURL: fileURL)
        let refreshDate = Date(timeIntervalSince1970: 1_000)
        _ = try await store.replace(
            with: [savedTrip(id: "ready", result: .preview)],
            refreshedAt: refreshDate
        )

        let renamed = try await store.rename(
            jobID: "ready",
            title: "Summer in Lisbon"
        )
        XCTAssertEqual(renamed?.trips.first?.title, "Summer in Lisbon")
        XCTAssertEqual(renamed?.refreshedAt, refreshDate)

        let removed = try await store.remove(jobID: "ready")
        XCTAssertTrue(removed?.trips.isEmpty == true)
        XCTAssertEqual(removed?.refreshedAt, refreshDate)
    }

    func testArchivedTripRemainsInOfflinePackAndCanBeRestored() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompletedTripCache(
            fileURL: root.appending(path: "completed.json")
        )
        var archived = savedTrip(id: "archived", result: .preview)
        archived.archivedAt = "2026-07-12T12:00:00Z"

        let snapshot = try await store.replace(with: [archived])
        let afterUpsert = try await store.upsert(archived)
        let restored = try await store.setArchivedAt(
            jobID: archived.jobId,
            archivedAt: nil
        )
        let reloaded = try await CompletedTripCache(
            fileURL: root.appending(path: "completed.json")
        ).load()

        XCTAssertEqual(snapshot.trips.first?.archivedAt, archived.archivedAt)
        XCTAssertEqual(afterUpsert.trips.first?.archivedAt, archived.archivedAt)
        XCTAssertNil(restored?.trips.first?.archivedAt)
        XCTAssertNil(reloaded?.trips.first?.archivedAt)
    }

    func testStalenessUsesSnapshotRefreshTime() {
        let snapshot = CompletedTripCacheSnapshot(
            trips: [],
            refreshedAt: Date(timeIntervalSince1970: 100)
        )
        XCTAssertFalse(
            snapshot.isStale(
                at: Date(timeIntervalSince1970: 159),
                maximumAge: 60
            )
        )
        XCTAssertTrue(
            snapshot.isStale(
                at: Date(timeIntervalSince1970: 161),
                maximumAge: 60
            )
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    private func savedTrip(
        id: String,
        status: JobState = .succeeded,
        title: String = "Lisbon",
        result: Itinerary?
    ) -> SavedItinerary {
        SavedItinerary(
            jobId: id,
            status: status,
            title: title,
            sourcePublicItineraryId: nil,
            city: "Lisbon",
            country: "Portugal",
            arrivalDate: "2026-08-01",
            departureDate: "2026-08-03",
            result: result,
            error: status == .failed ? "Failed" : nil,
            createdAt: "2026-01-01T00:00:00Z"
        )
    }
}
