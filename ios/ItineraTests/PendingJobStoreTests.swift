import Foundation
import XCTest
@testable import Itinera

final class PendingJobStoreTests: XCTestCase {
    func testPendingJobsPersistAcrossStoreInstancesAndRemoveAtomically() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = root.appending(path: "pending-jobs.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try PrivateStorageTestContext()

        let firstStore = storage.pendingJobStore(fileURL: fileURL)
        _ = try await firstStore.add(
            jobID: "job-123",
            title: "Lisbon, Portugal",
            createdAt: Date(timeIntervalSince1970: 100),
            lease: storage.lease,
            serverOperationLease: storage.serverOperationLease
        )

        let reloadedStore = storage.pendingJobStore(fileURL: fileURL)
        let reloaded = try await reloadedStore.all()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.jobID, "job-123")
        XCTAssertEqual(reloaded.first?.title, "Lisbon, Portugal")

        _ = try await reloadedStore.remove(
            jobID: "job-123",
            lease: storage.lease,
            serverOperationLease: storage.serverOperationLease
        )
        let afterRemoval = try await storage.pendingJobStore(
            fileURL: fileURL
        ).all()
        XCTAssertTrue(afterRemoval.isEmpty)
    }

    func testAddingSameJobPreservesOriginalCreationDateAndUpdatesTitle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = root.appending(path: "pending-jobs.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try PrivateStorageTestContext()

        let store = storage.pendingJobStore(fileURL: fileURL)
        _ = try await store.add(
            jobID: "job-123",
            title: nil,
            createdAt: Date(timeIntervalSince1970: 100),
            lease: storage.lease,
            serverOperationLease: storage.serverOperationLease
        )
        let records = try await store.add(
            jobID: "job-123",
            title: "Tokyo, Japan",
            createdAt: Date(timeIntervalSince1970: 200),
            lease: storage.lease,
            serverOperationLease: storage.serverOperationLease
        )

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.createdAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(records.first?.title, "Tokyo, Japan")
    }

    func testRemoveAllDeletesPendingJobsFileAndClearsActorCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = root.appending(path: "pending-jobs.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try PrivateStorageTestContext()
        let store = storage.pendingJobStore(fileURL: fileURL)
        _ = try await store.add(
            jobID: "job-123",
            title: "Lisbon",
            lease: storage.lease,
            serverOperationLease: storage.serverOperationLease
        )

        try await store.removeAll(
            lease: storage.lease,
            serverOperationLease: storage.serverOperationLease
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let records = try await store.all()
        XCTAssertTrue(records.isEmpty)
    }

    func testPendingSubmissionPersistsAndReusesIdempotencyKeyForSameBody() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = root.appending(path: "pending-submissions.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try PrivateStorageTestContext()

        let firstStore = storage.pendingSubmissionStore(fileURL: fileURL)
        let first = try await firstStore.record(
            for: sampleRequest,
            title: "Lisbon, Portugal",
            createdAt: Date(timeIntervalSince1970: 100),
            lease: storage.lease,
            serverOperationLease: storage.serverOperationLease
        )
        let second = try await firstStore.record(
            for: sampleRequest,
            title: "Lisbon, Portugal",
            createdAt: Date(timeIntervalSince1970: 200),
            lease: storage.lease,
            serverOperationLease: storage.serverOperationLease
        )

        XCTAssertEqual(first.idempotencyKey, second.idempotencyKey)
        let reloaded = try await storage.pendingSubmissionStore(
            fileURL: fileURL
        ).all()
        XCTAssertEqual(reloaded, [first])

        try await firstStore.remove(
            idempotencyKey: first.idempotencyKey,
            lease: storage.lease,
            serverOperationLease: storage.serverOperationLease
        )
        let remaining = try await firstStore.all()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testLegacyPendingSubmissionDefaultsNewPlanningFields() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = root.appending(path: "pending-submissions.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try PrivateStorageTestContext()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data(
            """
            [
              {
                "idempotencyKey": "11111111-2222-3333-4444-555555555555",
                "request": {
                  "city": "Lisbon",
                  "country": "Portugal",
                  "accommodation": {
                    "address": "Rua Augusta",
                    "lat": 38.7,
                    "lng": -9.1
                  },
                  "arrivalDate": "2026-08-01",
                  "departureDate": "2026-08-04",
                  "groupSize": 2,
                  "wakeUpTime": "08:00",
                  "foodPreferences": null,
                  "mustDo": null,
                  "budget": "Medium"
                },
                "title": "Lisbon, Portugal",
                "createdAt": "2026-01-01T00:00:00Z"
              }
            ]
            """.utf8
        ).write(to: fileURL, options: [.atomic])

        let store = storage.pendingSubmissionStore(fileURL: fileURL)
        let legacyRecords = try await store.all()
        let record = try XCTUnwrap(legacyRecords.first)

        XCTAssertEqual(record.request.pace, "Balanced")
        XCTAssertEqual(
            record.request.transportationModes,
            ["Walking", "Transit", "Driving"]
        )
        XCTAssertFalse(record.request.travelingWithChildren)
        XCTAssertTrue(record.request.interests.isEmpty)
        XCTAssertNil(record.request.accessibilityNeeds)
        XCTAssertTrue(record.request.fixedReservations.isEmpty)
        XCTAssertTrue(record.request.unavailableTimes.isEmpty)
        XCTAssertNil(record.request.timezone)

        try await store.removeAll(
            lease: storage.lease,
            serverOperationLease: storage.serverOperationLease
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let recordsAfterRemoval = try await store.all()
        XCTAssertTrue(recordsAfterRemoval.isEmpty)
    }

    func testLegacySingleTransportationPreferenceBecomesChecklistSelection() throws {
        let data = Data(
            """
            {
              "city": "Lisbon",
              "country": "Portugal",
              "accommodation": {"address": "Rua Augusta", "lat": 38.7, "lng": -9.1},
              "arrivalDate": "2026-08-01",
              "departureDate": "2026-08-04",
              "groupSize": 2,
              "wakeUpTime": "08:00",
              "budget": "Medium",
              "transportationPreference": "Transit"
            }
            """.utf8
        )

        let request = try JSONDecoder().decode(GenerateItineraryRequest.self, from: data)
        XCTAssertEqual(request.transportationModes, ["Transit"])
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
}
