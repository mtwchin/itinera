import XCTest
@testable import Itinera

final class NativeTripActionsTests: XCTestCase {
    func testCalendarPlannerMapsDaysTimesAndDurations() throws {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Lisbon"))
        calendar.timeZone = timeZone
        let start = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 10))
        )

        let events = ItineraryCalendarPlanner.makeEvents(
            itinerary: itinerary,
            tripStartDate: start,
            timeZone: timeZone,
            calendar: calendar
        )

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].title, "Alfama Walk")
        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day, .hour, .minute], from: events[0].startDate),
            DateComponents(year: 2026, month: 9, day: 10, hour: 9, minute: 30)
        )
        XCTAssertEqual(events[0].endDate.timeIntervalSince(events[0].startDate), 90 * 60)
        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day, .hour, .minute], from: events[1].startDate),
            DateComponents(year: 2026, month: 9, day: 11, hour: 14, minute: 0)
        )
    }

    func testDurationParserSupportsHoursAndMinutes() {
        XCTAssertEqual(ItineraryCalendarPlanner.durationInMinutes("1.5 hours"), 90)
        XCTAssertEqual(ItineraryCalendarPlanner.durationInMinutes("45 minutes"), 45)
        XCTAssertNil(ItineraryCalendarPlanner.durationInMinutes("until sunset"))
    }

    func testSharePayloadIncludesRouteDetailsAndAttribution() {
        let payload = ItinerarySharePayload.make(
            itinerary: itinerary,
            tripTitle: "Lisbon Field Notes",
            dateRange: "Sep 10–11, 2026"
        )

        XCTAssertEqual(payload.title, "Lisbon Field Notes")
        XCTAssertTrue(payload.text.contains("Day 1 — Old Lisbon"))
        XCTAssertTrue(payload.text.contains("9:30 AM · Alfama Walk"))
        XCTAssertTrue(payload.text.contains("Estimated budget: €300"))
        XCTAssertTrue(payload.text.hasSuffix("Planned with Itinera"))
    }

    func testNotificationContentCarriesDeepLinkMetadata() {
        let notification = GenerationNotificationContent.tripReady(
            jobID: "job-123",
            tripTitle: "Lisbon Field Notes"
        )

        XCTAssertEqual(notification.title, "Your trip is ready")
        XCTAssertEqual(notification.body, "Lisbon Field Notes is ready to explore.")
        XCTAssertEqual(notification.userInfo["itinera_job_id"], "job-123")
        XCTAssertEqual(notification.userInfo["itinera_destination"], "trip")
    }

    func testNotificationContentUsesSafeFallbacksForUntitledAndFailedTrips() {
        let ready = GenerationNotificationContent.tripReady(
            jobID: "job-untitled",
            tripTitle: "   "
        )
        let failed = GenerationNotificationContent.generationFailed(jobID: "job-failed")

        XCTAssertEqual(ready.body, "Open Itinera to explore your new route.")
        XCTAssertEqual(failed.title, "Your trip needs attention")
        XCTAssertEqual(failed.userInfo["itinera_job_id"], "job-failed")
    }

    @MainActor
    func testNotificationCleanupRecognizesGenerationAndReminderIdentifiers() {
        XCTAssertTrue(
            GenerationNotificationManager.isItineraNotificationIdentifier(
                "com.itinera.generation.job-123"
            )
        )
        XCTAssertTrue(
            GenerationNotificationManager.isItineraNotificationIdentifier(
                "com.itinera.reminder.job-123.activity-1"
            )
        )
        XCTAssertFalse(
            GenerationNotificationManager.isItineraNotificationIdentifier(
                "com.example.unrelated"
            )
        )
    }

    func testCalendarPlannerSkipsUnparseableTimesAndDefaultsUnknownDuration() throws {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Lisbon"))
        calendar.timeZone = timeZone
        let start = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 10))
        )
        let input = Itinerary(
            itinerary: [
                ItineraryDay(
                    day: 1,
                    theme: "Old Lisbon",
                    activities: [
                        activity(time: "morning-ish", name: "Invalid", duration: "1 hour"),
                        activity(time: "10 AM", name: "Valid", duration: "until lunch"),
                    ]
                )
            ],
            tips: [],
            accommodationInfo: AccommodationInfo(
                morningStart: "",
                eveningReturn: "",
                transportationTips: ""
            ),
            estimatedBudget: ""
        )

        let events = ItineraryCalendarPlanner.makeEvents(
            itinerary: input,
            tripStartDate: start,
            timeZone: timeZone,
            calendar: calendar
        )

        XCTAssertEqual(events.map(\.title), ["Valid"])
        XCTAssertEqual(events[0].endDate.timeIntervalSince(events[0].startDate), 60 * 60)
    }

    func testLiveActivityProgressIsClamped() {
        let state = TripActivityAttributes.ContentState(
            dayNumber: 1,
            stopNumber: 1,
            totalStops: 3,
            currentStop: nil,
            nextStop: "Alfama Walk",
            leaveBy: nil,
            progress: 1.5
        )

        XCTAssertEqual(state.progress, 1)
    }

    private var itinerary: Itinerary {
        Itinerary(
            itinerary: [
                ItineraryDay(
                    day: 1,
                    theme: "Old Lisbon",
                    activities: [activity(time: "9:30 AM", name: "Alfama Walk", duration: "1.5 hours")]
                ),
                ItineraryDay(
                    day: 2,
                    theme: "River Light",
                    activities: [activity(time: "14:00", name: "Belém Tower", duration: "45 minutes")]
                ),
            ],
            tips: [],
            accommodationInfo: AccommodationInfo(
                morningStart: "",
                eveningReturn: "",
                transportationTips: ""
            ),
            estimatedBudget: "€300"
        )
    }

    private func activity(time: String, name: String, duration: String) -> Activity {
        Activity(
            time: time,
            name: name,
            type: "sightseeing",
            duration: duration,
            description: "A memorable stop.",
            address: "Lisbon, Portugal",
            coordinates: Coordinates(lat: 38.7, lng: -9.1)
        )
    }
}
