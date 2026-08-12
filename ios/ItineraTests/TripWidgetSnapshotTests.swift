import Foundation
import XCTest
@testable import Itinera

final class TripWidgetSnapshotTests: XCTestCase {
    func testScopedKeyAcceptsOnlyOpaquePrincipalDigests() throws {
        let digest = String(repeating: "a", count: 64)

        XCTAssertEqual(
            TripWidgetSnapshotStore.scopedKey(principalDigest: digest),
            "trip-widget-snapshot-v1.\(digest)"
        )
        XCTAssertNil(
            TripWidgetSnapshotStore.scopedKey(
                principalDigest: "11111111-2222-3333-4444-555555555555"
            )
        )
    }

    func testSnapshotRoundTripsThroughAnIsolatedDefaultsSuite() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let leaveBy = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = TripWidgetSnapshot(
            tripID: "trip-1",
            tripTitle: "Lisbon",
            dayNumber: 2,
            stopNumber: 3,
            totalStops: 6,
            currentStop: "Alfama",
            nextStop: "Belém Tower",
            leaveBy: leaveBy,
            progress: 0.5,
            updatedAt: leaveBy.addingTimeInterval(-60)
        )

        XCTAssertTrue(TripWidgetSnapshotStore.save(snapshot, defaults: defaults))
        XCTAssertEqual(TripWidgetSnapshotStore.load(defaults: defaults), snapshot)
    }

    func testSnapshotProgressIsClampedAndClearRemovesIt() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshot = TripWidgetSnapshot(
            tripID: "trip-2",
            tripTitle: "Osaka",
            dayNumber: 1,
            stopNumber: 1,
            totalStops: 4,
            currentStop: nil,
            nextStop: "Osaka Castle",
            leaveBy: nil,
            progress: 3
        )

        XCTAssertEqual(snapshot.progress, 1)
        TripWidgetSnapshotStore.save(snapshot, defaults: defaults)
        TripWidgetSnapshotStore.clear(defaults: defaults)
        XCTAssertNil(TripWidgetSnapshotStore.load(defaults: defaults))
    }

    func testUnsupportedSnapshotSchemaIsIgnored() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshot = TripWidgetSnapshot(
            schemaVersion: TripWidgetSnapshot.currentSchemaVersion + 1,
            tripID: "trip-3",
            tripTitle: "Reykjavík",
            dayNumber: 1,
            stopNumber: 1,
            totalStops: 3,
            currentStop: nil,
            nextStop: "Harpa",
            leaveBy: nil,
            progress: 0
        )

        TripWidgetSnapshotStore.save(snapshot, defaults: defaults)
        XCTAssertNil(TripWidgetSnapshotStore.load(defaults: defaults))
    }

    func testOnlyTheSelectedOpaqueSnapshotIsVisibleToTheWidget() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = TripWidgetSnapshot(
            tripID: "trip-a",
            tripTitle: "First traveler",
            dayNumber: 1,
            stopNumber: 1,
            totalStops: 2,
            currentStop: nil,
            nextStop: "Private first stop",
            leaveBy: nil,
            progress: 0
        )
        let second = TripWidgetSnapshot(
            tripID: "trip-b",
            tripTitle: "Second traveler",
            dayNumber: 1,
            stopNumber: 2,
            totalStops: 3,
            currentStop: "Private second stop",
            nextStop: "Another private stop",
            leaveBy: nil,
            progress: 0.5
        )
        let firstKey = try XCTUnwrap(
            TripWidgetSnapshotStore.scopedKey(
                principalDigest: String(repeating: "a", count: 64)
            )
        )
        let secondKey = try XCTUnwrap(
            TripWidgetSnapshotStore.scopedKey(
                principalDigest: String(repeating: "b", count: 64)
            )
        )

        XCTAssertTrue(TripWidgetSnapshotStore.save(first, key: firstKey, defaults: defaults))
        XCTAssertTrue(TripWidgetSnapshotStore.save(second, key: secondKey, defaults: defaults))
        XCTAssertEqual(TripWidgetSnapshotStore.load(defaults: defaults), second)

        TripWidgetSnapshotStore.clear(key: firstKey, defaults: defaults)
        XCTAssertEqual(TripWidgetSnapshotStore.load(defaults: defaults), second)

        TripWidgetSnapshotStore.clear(defaults: defaults)
        XCTAssertNil(TripWidgetSnapshotStore.load(defaults: defaults))
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "TripWidgetSnapshotTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }
}
