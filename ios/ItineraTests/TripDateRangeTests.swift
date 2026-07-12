import XCTest
@testable import Itinera

final class TripDateRangeTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    func testFirstTapChoosesStartSecondTapCompletesAndThirdRestarts() throws {
        let today = try date(2026, 3, 7)
        var range = TripDateRangeSelection()

        XCTAssertEqual(range.select(try date(2026, 3, 8), today: today, calendar: calendar), .selectedStart)
        XCTAssertEqual(range.phase, .choosingEnd)
        XCTAssertEqual(range.select(try date(2026, 3, 11), today: today, calendar: calendar), .completed)
        XCTAssertEqual(range.phase, .complete)
        XCTAssertEqual(range.select(try date(2026, 3, 20), today: today, calendar: calendar), .selectedStart)
        XCTAssertEqual(range.phase, .choosingEnd)
        XCTAssertNil(range.end)
    }

    func testRejectsPastDatesAndRangesLongerThanThirtyDays() throws {
        let today = try date(2026, 7, 12)
        var range = TripDateRangeSelection()

        XCTAssertEqual(range.select(try date(2026, 7, 11), today: today, calendar: calendar), .rejectedPast)
        XCTAssertEqual(range.phase, .empty)
        XCTAssertEqual(range.select(today, today: today, calendar: calendar), .selectedStart)
        XCTAssertEqual(range.select(try date(2026, 8, 12), today: today, calendar: calendar), .rejectedTooLong)
        XCTAssertEqual(range.phase, .choosingEnd)
    }

    func testAcceptsExactlyThirtyDays() throws {
        let today = try date(2026, 7, 12)
        var range = TripDateRangeSelection()

        XCTAssertEqual(range.select(today, today: today, calendar: calendar), .selectedStart)
        XCTAssertEqual(
            range.select(try date(2026, 8, 11), today: today, calendar: calendar),
            .completed
        )
        XCTAssertEqual(range.phase, .complete)
    }

    func testLocalCalendarIterationStaysOnCalendarDaysAcrossDST() throws {
        let start = try date(2026, 3, 7)
        let end = try date(2026, 3, 10)
        let range = TripDateRangeSelection(start: start, end: end, calendar: calendar)

        let components = range.selectedDateComponents(calendar: calendar)

        XCTAssertEqual(components.count, 4)
        XCTAssertTrue(components.contains(DateComponents(year: 2026, month: 3, day: 8)))
        XCTAssertTrue(components.contains(DateComponents(year: 2026, month: 3, day: 9)))
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day)))
    }
}

final class LocationSearchStatusTests: XCTestCase {
    func testEditingQueryReenablesSearchAndOldCompletionCannotDisableNewSearch() {
        var status = LocationSearchStatus.idle

        status.begin(query: "Lisbon")
        XCTAssertTrue(status.isSearching)

        status.supersede()
        XCTAssertFalse(status.isSearching)

        status.begin(query: "Lisbon, Portugal")
        status.finish(query: "Lisbon")
        XCTAssertTrue(status.isSearching)

        status.finish(query: "Lisbon, Portugal")
        XCTAssertFalse(status.isSearching)
    }

    func testReverseGeocodeCancellationAndLateCompletionCannotHideNewRequest() {
        let first = LocationCoordinate(latitude: 38.7223, longitude: -9.1393)
        let second = LocationCoordinate(latitude: 41.1579, longitude: -8.6291)
        var status = LocationReverseGeocodeStatus.idle

        status.begin(coordinate: first)
        XCTAssertTrue(status.isResolving)

        status.supersede()
        XCTAssertFalse(status.isResolving)

        status.begin(coordinate: first)
        status.begin(coordinate: second)
        status.finish(coordinate: first)
        XCTAssertTrue(status.isResolving)

        status.finish(coordinate: second)
        XCTAssertFalse(status.isResolving)
    }
}
