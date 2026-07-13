import Foundation
import XCTest
@testable import Itinera

final class TripLibraryOrganizerTests: XCTestCase {
    func testGroupsTripsByStatusAndLocalTravelDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let today = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 2))
        )

        XCTAssertEqual(
            TripLibraryOrganizer.group(
                for: trip(id: "active", arrival: "2026-08-01", departure: "2026-08-03"),
                today: today,
                calendar: calendar
            ),
            .active
        )
        XCTAssertEqual(
            TripLibraryOrganizer.group(
                for: trip(id: "future", arrival: "2026-09-01", departure: "2026-09-03"),
                today: today,
                calendar: calendar
            ),
            .upcoming
        )
        XCTAssertEqual(
            TripLibraryOrganizer.group(
                for: trip(id: "past", arrival: "2026-07-01", departure: "2026-07-03"),
                today: today,
                calendar: calendar
            ),
            .past
        )
        XCTAssertEqual(
            TripLibraryOrganizer.group(
                for: trip(id: "pending", status: .running),
                today: today,
                calendar: calendar
            ),
            .generating
        )
    }

    func testSearchIncludesActivityNamesAndAddresses() {
        let trip = trip(id: "lisbon")
        let matches = TripLibraryOrganizer.groups(
            for: [trip],
            searchText: "Jerónimos"
        )
        XCTAssertEqual(matches.flatMap(\.trips).map(\.jobId), ["lisbon"])

        XCTAssertTrue(
            TripLibraryOrganizer.groups(
                for: [trip],
                searchText: "not in this trip"
            ).isEmpty
        )
    }

    func testActiveGroupingUsesDestinationTimezone() throws {
        var deviceCalendar = Calendar(identifier: .gregorian)
        deviceCalendar.timeZone = try XCTUnwrap(
            TimeZone(identifier: "America/Los_Angeles")
        )
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-12T00:30:00Z")
        )
        var destinationTrip = trip(
            id: "tokyo",
            arrival: "2026-07-12",
            departure: "2026-07-14"
        )
        destinationTrip.result?.timeZoneIdentifier = "Asia/Tokyo"

        XCTAssertEqual(
            TripLibraryOrganizer.group(
                for: destinationTrip,
                today: now,
                calendar: deviceCalendar
            ),
            .active
        )
    }

    func testLocalDateRejectsCalendarNormalizedInvalidDate() {
        XCTAssertNil(TripLibraryOrganizer.localDate("2026-02-31"))
        XCTAssertNil(TripLibraryOrganizer.localDate("not-a-date"))
    }

    private func trip(
        id: String,
        status: JobState = .succeeded,
        arrival: String? = nil,
        departure: String? = nil
    ) -> SavedItinerary {
        SavedItinerary(
            jobId: id,
            status: status,
            title: "Lisbon field guide",
            sourcePublicItineraryId: nil,
            city: "Lisbon",
            country: "Portugal",
            arrivalDate: arrival,
            departureDate: departure,
            result: status == .succeeded ? .preview : nil,
            error: nil,
            createdAt: "2026-01-01T00:00:00Z"
        )
    }
}
