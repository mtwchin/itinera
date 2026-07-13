import Foundation
import XCTest
@testable import Itinera

@MainActor
final class TodayTripViewModelTests: XCTestCase {
    func testSelectsTodayDayAndAdvancesCurrentStopAsProgressChanges() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 2,
                    hour: 12,
                    minute: 30
                )
            )
        )
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = root.appending(path: "progress.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let model = TodayTripViewModel(
            trip: trip,
            progressStore: TripProgressStore(fileURL: fileURL),
            calendar: calendar,
            now: { now }
        )
        await model.load()

        XCTAssertEqual(model.day?.day, 2)
        XCTAssertEqual(model.currentActivity?.name, "Pastéis de Belém")
        XCTAssertNil(model.nextActivity)
        XCTAssertNil(
            model.liveActivityState?.leaveBy,
            "A scheduled start time must not be presented as a route-aware leave-by ETA."
        )

        let first = try XCTUnwrap(model.day?.activities.first)
        let second = try XCTUnwrap(model.day?.activities.last)
        await model.set(.completed, for: first)
        XCTAssertEqual(model.currentActivity, second)
        XCTAssertEqual(model.completedCount, 1)

        await model.set(.skipped, for: second)
        XCTAssertNil(model.currentActivity)
        XCTAssertEqual(model.skippedCount, 1)
        XCTAssertEqual(model.progressFraction, 1)
    }

    func testSelectsDestinationDayAndCurrentStopAcrossDateLine() async throws {
        var deviceCalendar = Calendar(identifier: .gregorian)
        deviceCalendar.timeZone = try XCTUnwrap(
            TimeZone(identifier: "America/Los_Angeles")
        )
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-12T00:30:00Z")
        )
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        var itinerary = Itinerary.preview
        itinerary.timeZoneIdentifier = "Asia/Tokyo"
        itinerary.itinerary[0].date = "2026-07-12"
        itinerary.itinerary[1].date = "2026-07-13"
        itinerary.itinerary[2].date = "2026-07-14"
        var destinationTrip = trip
        destinationTrip.arrivalDate = "2026-07-12"
        destinationTrip.departureDate = "2026-07-14"
        destinationTrip.result = itinerary

        let model = TodayTripViewModel(
            trip: destinationTrip,
            progressStore: TripProgressStore(
                fileURL: root.appending(path: "progress.json")
            ),
            calendar: deviceCalendar,
            now: { now }
        )
        await model.load()

        // The phone is still on July 11 in Los Angeles, while the trip is
        // already on July 12 at 09:30 in Tokyo.
        XCTAssertEqual(model.day?.day, 1)
        XCTAssertEqual(
            model.currentActivity?.name,
            "Miradouro da Senhora do Monte"
        )
    }

    private var trip: SavedItinerary {
        SavedItinerary(
            jobId: "trip-1",
            status: .succeeded,
            title: "Lisbon",
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
}
