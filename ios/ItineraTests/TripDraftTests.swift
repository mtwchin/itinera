import XCTest
@testable import Itinera

final class TripDraftTests: XCTestCase {
    func testDraftRoundTripsAllPlanningContext() throws {
        let draft = TripDraft(
            destinationQuery: "Lisbon, Portugal",
            destination: nil,
            homeBaseQuery: "Alfama",
            homeBase: nil,
            arrival: Date(timeIntervalSince1970: 1_800_000_000),
            departure: Date(timeIntervalSince1970: 1_800_259_200),
            groupSize: 3,
            wakeUpTime: Date(timeIntervalSince1970: 28_800),
            foodPreferences: "Vegetarian",
            mustDo: "Tiles",
            budget: "Medium",
            pace: "Relaxed",
            transportationPreference: "Transit",
            travelingWithChildren: true,
            interests: "Architecture",
            accessibilityNeeds: "Step-free",
            fixedReservations: "Museum at 14:00",
            unavailableTimes: "Friday morning",
            scheduleConstraints: [
                TripScheduleConstraint(
                    id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                    kind: .freeTime,
                    title: "Keep free",
                    date: Date(timeIntervalSince1970: 1_800_000_000),
                    startsAt: Date(timeIntervalSince1970: 36_000),
                    endsAt: Date(timeIntervalSince1970: 39_600),
                    address: ""
                )
            ]
        )

        let encoded = try XCTUnwrap(TripDraftCodec.encode(draft))
        XCTAssertEqual(TripDraftCodec.decode(encoded), draft)
    }

    func testEmptyDataDoesNotCreateDraft() {
        XCTAssertNil(TripDraftCodec.decode(Data()))
    }

    func testCategorySelectionsUseOnlyKnownValues() {
        XCTAssertEqual(
            TripInterestCategory.selection(
                fromStoredValue: "History,Unknown,Nature & outdoors"
            ),
            [.history, .natureAndOutdoors]
        )
        XCTAssertEqual(
            TripAccessibilityCategory.selection(
                fromStoredValue: "Step-free routes,Unknown,Visual support"
            ),
            [.stepFree, .visualSupport]
        )
    }

    func testLocalDataCleanerRemovesOnlyCurrentScopeDraftAndLocks() throws {
        let suiteName = "TripDraftTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scope = try PrincipalScope(
            validating: String(repeating: "a", count: 64)
        )
        let otherScope = try PrincipalScope(
            validating: String(repeating: "b", count: 64)
        )
        defaults.set(
            Data([1, 2, 3]),
            forKey: ItineraLocalDataKeys.tripDraft(for: scope)
        )
        defaults.set(
            ["activity-1"],
            forKey: ItineraLocalDataKeys.lockedStops(
                for: "trip-1",
                scope: scope
            )
        )
        defaults.set(
            ["activity-2"],
            forKey: ItineraLocalDataKeys.lockedStops(
                for: "trip-2",
                scope: otherScope
            )
        )
        defaults.set("keep", forKey: "unrelated.preference")

        ItineraLocalDataCleaner.clearCurrentScope(
            scope,
            defaults: defaults
        )

        XCTAssertNil(
            defaults.object(
                forKey: ItineraLocalDataKeys.tripDraft(for: scope)
            )
        )
        XCTAssertNil(
            defaults.object(
                forKey: ItineraLocalDataKeys.lockedStops(
                    for: "trip-1",
                    scope: scope
                )
            )
        )
        XCTAssertEqual(
            defaults.stringArray(
                forKey: ItineraLocalDataKeys.lockedStops(
                    for: "trip-2",
                    scope: otherScope
                )
            ),
            ["activity-2"]
        )
        XCTAssertEqual(defaults.string(forKey: "unrelated.preference"), "keep")
    }
}
