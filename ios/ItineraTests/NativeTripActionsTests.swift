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
        let session = presentationSession(scopeCharacter: "a", session: 1)
        let notification = GenerationNotificationContent.tripReady(
            jobID: "job-123",
            tripTitle: "Lisbon Field Notes",
            session: session
        )

        XCTAssertEqual(notification.title, "Your trip is ready")
        XCTAssertEqual(notification.body, "Lisbon Field Notes is ready to explore.")
        XCTAssertEqual(notification.userInfo["itinera_job_id"], "job-123")
        XCTAssertEqual(notification.userInfo["itinera_destination"], "trip")
        XCTAssertEqual(notification.userInfo["itinera_principal_scope"], session.scope.digest)
        XCTAssertEqual(
            notification.userInfo["itinera_presentation_session"],
            session.id.uuidString.lowercased()
        )
    }

    func testNotificationContentUsesSafeFallbacksForUntitledAndFailedTrips() {
        let session = presentationSession(scopeCharacter: "b", session: 2)
        let ready = GenerationNotificationContent.tripReady(
            jobID: "job-untitled",
            tripTitle: "   ",
            session: session
        )
        let failed = GenerationNotificationContent.generationFailed(
            jobID: "job-failed",
            session: session
        )

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

    @MainActor
    func testNotificationIdentifiersRoundTripPresentationSession() {
        let session = presentationSession(scopeCharacter: "c", session: 3)
        let generation = GenerationNotificationManager.identifier(
            for: "job.with.periods",
            session: session
        )
        let reminder = GenerationNotificationManager.reminderIdentifier(
            jobID: "job-123",
            activityID: "activity-1",
            session: session
        )

        XCTAssertEqual(
            GenerationNotificationManager.presentationSession(from: generation),
            session
        )
        XCTAssertEqual(
            GenerationNotificationManager.presentationSession(from: reminder),
            session
        )
        XCTAssertNil(
            GenerationNotificationManager.presentationSession(
                from: "com.itinera.generation.job-legacy"
            )
        )
    }

    @MainActor
    func testDelayedA1NotificationTapIsRejectedDuringLaterA3Session() {
        let firstA = presentationSession(scopeCharacter: "d", session: 4)
        let laterA = presentationSession(scopeCharacter: "d", session: 5)
        let content = GenerationNotificationContent.tripReady(
            jobID: "job-old",
            tripTitle: nil,
            session: firstA
        )
        let erasedUserInfo = Dictionary<AnyHashable, Any>(
            uniqueKeysWithValues: content.userInfo.map { (AnyHashable($0.key), $0.value) }
        )
        let identifier = GenerationNotificationManager.identifier(
            for: "job-old",
            session: firstA
        )

        XCTAssertTrue(GenerationNotificationMetadata.belongs(erasedUserInfo, to: firstA))
        XCTAssertFalse(GenerationNotificationMetadata.belongs(erasedUserInfo, to: laterA))
        XCTAssertEqual(
            GenerationNotificationManager.presentationSession(
                from: identifier,
                userInfo: erasedUserInfo
            ),
            firstA
        )

        let laterContent = GenerationNotificationContent.tripReady(
            jobID: "job-new",
            tripTitle: nil,
            session: laterA
        )
        let mismatchedUserInfo = Dictionary<AnyHashable, Any>(
            uniqueKeysWithValues: laterContent.userInfo.map {
                (AnyHashable($0.key), $0.value)
            }
        )
        XCTAssertNil(
            GenerationNotificationManager.presentationSession(
                from: identifier,
                userInfo: mismatchedUserInfo
            )
        )

        let wrongJobContent = GenerationNotificationContent.tripReady(
            jobID: "job-different",
            tripTitle: nil,
            session: firstA
        )
        let wrongJobUserInfo = Dictionary<AnyHashable, Any>(
            uniqueKeysWithValues: wrongJobContent.userInfo.map {
                (AnyHashable($0.key), $0.value)
            }
        )
        XCTAssertNil(
            GenerationNotificationManager.presentationSession(
                from: identifier,
                userInfo: wrongJobUserInfo
            )
        )
    }

    @MainActor
    func testForegroundAndTapGateRequireStrictCurrentIdentifierMetadataPair() {
        let firstA = presentationSession(scopeCharacter: "f", session: 8)
        let laterA = presentationSession(scopeCharacter: "f", session: 9)
        let manager = GenerationNotificationManager()
        manager.establishActiveSession(laterA)

        func isAccepted(
            identifier: String,
            content: GenerationNotificationContent
        ) -> Bool {
            let userInfo = Dictionary<AnyHashable, Any>(
                uniqueKeysWithValues: content.userInfo.map {
                    (AnyHashable($0.key), $0.value)
                }
            )
            guard let parsed = GenerationNotificationManager
                .presentationSession(
                    from: identifier,
                    userInfo: userInfo
                ) else {
                return false
            }
            return manager.isCurrent(parsed)
        }

        let staleContent = GenerationNotificationContent.tripReady(
            jobID: "job-a1",
            tripTitle: nil,
            session: firstA
        )
        XCTAssertFalse(
            isAccepted(
                identifier: GenerationNotificationManager.identifier(
                    for: "job-a1",
                    session: firstA
                ),
                content: staleContent
            )
        )

        let currentContent = GenerationNotificationContent.tripReady(
            jobID: "job-a3",
            tripTitle: nil,
            session: laterA
        )
        XCTAssertTrue(
            isAccepted(
                identifier: GenerationNotificationManager.identifier(
                    for: "job-a3",
                    session: laterA
                ),
                content: currentContent
            )
        )
        XCTAssertFalse(
            isAccepted(
                identifier: "com.itinera.generation.job-a3",
                content: currentContent
            ),
            "Legacy unscoped notifications must be silent and non-navigable."
        )
        XCTAssertFalse(
            isAccepted(
                identifier: GenerationNotificationManager.identifier(
                    for: "different-job",
                    session: laterA
                ),
                content: currentContent
            ),
            "Identifier and userInfo must agree on both session and job."
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

    @MainActor
    func testLiveActivityStartRejectsEarlierSessionForSamePrincipal() {
        let manager = TripLiveActivityManager()
        let firstA = presentationSession(scopeCharacter: "e", session: 6)
        let laterA = presentationSession(scopeCharacter: "e", session: 7)
        manager.establishActiveSession(firstA)
        manager.establishActiveSession(laterA)
        let state = TripActivityAttributes.ContentState(
            dayNumber: 1,
            stopNumber: 1,
            totalStops: 2,
            currentStop: nil,
            nextStop: "Belém Tower",
            leaveBy: nil,
            progress: 0
        )

        XCTAssertThrowsError(
            try manager.start(
                presentationSession: firstA,
                tripID: "trip-old",
                tripTitle: "Old A trip",
                state: state
            )
        ) { error in
            XCTAssertEqual(error as? PrivateSurfaceScopeError, .staleScope)
        }
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

    private func presentationSession(
        scopeCharacter: Character,
        session: Int
    ) -> PrivatePresentationSession {
        let scope = try! PrincipalScope(
            validating: String(repeating: scopeCharacter, count: PrincipalScope.digestLength)
        )
        let id = UUID(
            uuidString: String(format: "00000000-0000-0000-0000-%012d", session)
        )!
        return PrivatePresentationSession(scope: scope, id: id)
    }
}
