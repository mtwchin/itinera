import Foundation
import XCTest
@testable import Itinera

@MainActor
final class TodayTripViewModelTests: XCTestCase {
    func testTimingGateWaitsForProgressThenMakesOneRouteRequest() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 2,
                    hour: 11
                )
            )
        )
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var requestCount = 0
        let model = try makeModel(
            trip: trip,
            progressFileURL: root.appending(path: "progress.json"),
            calendar: calendar,
            now: { now },
            routeLoader: { activities, mode, _ in
                requestCount += 1
                return [
                    Self.leg(
                        from: activities[0],
                        to: activities[1],
                        mode: mode,
                        travelTime: 15 * 60
                    )
                ]
            }
        )

        await model.loadTimingIfProgressReady()
        XCTAssertEqual(requestCount, 0)
        XCTAssertFalse(model.hasLoadedProgress)

        await model.load()
        XCTAssertTrue(model.hasLoadedProgress)
        await model.loadTimingIfProgressReady()

        XCTAssertEqual(requestCount, 1)
        guard case .route = model.timingState else {
            return XCTFail("Expected timing after the progress gate opened")
        }
    }

    func testCancelledProgressLoadKeepsTimingGateClosed() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 2,
                    hour: 11
                )
            )
        )
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let progressHarness = ControlledTodayProgressLoader()
        var routeRequestCount = 0
        let model = try makeModel(
            trip: trip,
            progressFileURL: root.appending(path: "progress.json"),
            calendar: calendar,
            now: { now },
            progressLoader: { try await progressHarness.load() },
            routeLoader: { _, _, _ in
                routeRequestCount += 1
                return []
            }
        )

        let progressTask = Task { await model.load() }
        for _ in 0..<10 where !progressHarness.isSuspended {
            await Task.yield()
        }
        XCTAssertTrue(progressHarness.isSuspended)

        progressTask.cancel()
        progressHarness.cancel()
        await progressTask.value
        await model.loadTimingIfProgressReady()

        XCTAssertFalse(model.hasLoadedProgress)
        XCTAssertEqual(routeRequestCount, 0)
    }

    func testDerivesLeaveByAndETAFromNamedAdjacentStopRoute() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 2,
                    hour: 11,
                    minute: 5
                )
            )
        )
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var requestedNames: [String] = []
        var requestedMode: TripTransportMode?

        let model = try makeModel(
            trip: trip,
            progressFileURL: root.appending(path: "progress.json"),
            calendar: calendar,
            now: { now },
            routeLoader: { activities, mode, plannedArrival in
                requestedNames = activities.map(\.name)
                requestedMode = mode
                XCTAssertNil(plannedArrival)
                return [
                    Self.leg(
                        from: activities[0],
                        to: activities[1],
                        mode: mode,
                        travelTime: 20 * 60
                    )
                ]
            }
        )
        guard case .planned(let initialTiming) = model.timingState else {
            return XCTFail("Expected a neutral planned state before checking")
        }
        XCTAssertEqual(initialTiming.reason, .notChecked)
        await model.load()
        await model.loadTiming()

        guard case .route(let estimate) = model.timingState else {
            return XCTFail("Expected a route-derived timing state")
        }
        let plannedStart = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 2,
                    hour: 12
                )
            )
        )
        XCTAssertEqual(
            requestedNames,
            ["Jerónimos Monastery", "Pastéis de Belém"]
        )
        XCTAssertEqual(requestedMode, .walking)
        XCTAssertEqual(estimate.context.originName, "Jerónimos Monastery")
        XCTAssertEqual(estimate.context.destinationName, "Pastéis de Belém")
        XCTAssertEqual(estimate.context.plannedStart, plannedStart)
        XCTAssertEqual(estimate.basis, .current)
        XCTAssertEqual(
            estimate.leaveBy,
            plannedStart.addingTimeInterval(-20 * 60)
        )
        XCTAssertEqual(
            estimate.estimatedArrival,
            now.addingTimeInterval(20 * 60)
        )
        XCTAssertEqual(estimate.checkedAt, now)
        XCTAssertFalse(estimate.isLeaveByPast(at: now))
        XCTAssertTrue(estimate.isLeaveByPast(at: estimate.leaveBy))
        XCTAssertEqual(estimate.travelTimeLabel, "20 min")
        let accessibilitySummary = estimate.accessibilitySummary(
            currentTime: now,
            timeZone: calendar.timeZone,
            locale: Locale(identifier: "en_US_POSIX")
        )
        var summaryCursor = accessibilitySummary.startIndex
        for expectedText in [
            "Pastéis de Belém",
            "Planned start",
            "Leave by",
            "Estimated arrival",
            "Planned leg from Jerónimos Monastery to Pastéis de Belém",
            "Walking",
            "Apple Maps",
            "checked",
        ] {
            guard let range = accessibilitySummary.range(
                of: expectedText,
                range: summaryCursor..<accessibilitySummary.endIndex
            ) else {
                return XCTFail(
                    "Expected ordered VoiceOver text '\(expectedText)' in: \(accessibilitySummary)"
                )
            }
            summaryCursor = range.upperBound
        }
        XCTAssertTrue(
            accessibilitySummary.contains("does not use your location")
        )
        XCTAssertNil(
            model.liveActivityState?.leaveBy,
            "Transient Today timing must not lose timezone provenance in other surfaces."
        )
    }

    func testFutureTransitCarriesArriveByBasisWithoutPromisingLeaveNow() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 2,
                    hour: 11,
                    minute: 5
                )
            )
        )
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var requestedArrivals: [Date?] = []
        let model = try makeModel(
            trip: trip,
            progressFileURL: root.appending(path: "progress.json"),
            calendar: calendar,
            now: { now },
            routeLoader: { activities, mode, plannedArrival in
                requestedArrivals.append(plannedArrival)
                return [
                    Self.leg(
                        from: activities[0],
                        to: activities[1],
                        mode: mode,
                        travelTime: 70 * 60
                    )
                ]
            }
        )
        model.selectTransportMode(.transit)

        await model.loadTiming()

        guard case .route(let estimate) = model.timingState else {
            return XCTFail("Expected an arrive-by transit estimate")
        }
        let plannedStart = try XCTUnwrap(
            model.plannedStart(for: try XCTUnwrap(model.timingActivity))
        )
        XCTAssertEqual(requestedArrivals.count, 1)
        XCTAssertEqual(requestedArrivals[0], plannedStart)
        XCTAssertEqual(estimate.basis, .arriveBy(plannedStart))
        XCTAssertEqual(estimate.estimatedArrival, plannedStart)
        XCTAssertTrue(estimate.isLeaveByPast(at: now))
        let summary = estimate.accessibilitySummary(
            currentTime: now,
            timeZone: calendar.timeZone,
            locale: Locale(identifier: "en_US_POSIX")
        )
        XCTAssertTrue(summary.contains("calculated leave-by has passed"))
        XCTAssertTrue(summary.contains("Recheck the transit route"))
        XCTAssertTrue(summary.contains("requested to arrive by"))
        XCTAssertFalse(summary.contains("Leave now"))
        XCTAssertFalse(summary.contains("if departing"))
    }

    func testPastTransitUsesCurrentRouteBasis() async throws {
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
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var requestedArrivals: [Date?] = []
        let model = try makeModel(
            trip: trip,
            progressFileURL: root.appending(path: "progress.json"),
            calendar: calendar,
            now: { now },
            routeLoader: { activities, mode, plannedArrival in
                requestedArrivals.append(plannedArrival)
                return [
                    Self.leg(
                        from: activities[0],
                        to: activities[1],
                        mode: mode,
                        travelTime: 20 * 60
                    )
                ]
            }
        )
        model.selectTransportMode(.transit)

        await model.loadTiming()

        guard case .route(let estimate) = model.timingState else {
            return XCTFail("Expected a current transit estimate")
        }
        XCTAssertEqual(requestedArrivals.count, 1)
        XCTAssertNil(requestedArrivals[0])
        XCTAssertEqual(estimate.basis, .current)
        let summary = estimate.accessibilitySummary(
            currentTime: now,
            timeZone: calendar.timeZone,
            locale: Locale(identifier: "en_US_POSIX")
        )
        XCTAssertTrue(summary.contains("Leave now"))
        XCTAssertTrue(summary.contains("if departing"))
    }

    func testRouteFailureRetainsPlannedStartWithoutLeaveBy() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 2,
                    hour: 11
                )
            )
        )
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(
            trip: trip,
            progressFileURL: root.appending(path: "progress.json"),
            calendar: calendar,
            now: { now },
            routeLoader: { _, _, _ in throw RouteTestError.unavailable }
        )

        await model.loadTiming()

        guard case .unavailable(let context) = model.timingState else {
            return XCTFail("Expected unavailable route timing")
        }
        XCTAssertEqual(context.destinationName, "Pastéis de Belém")
        XCTAssertEqual(
            context.plannedStart,
            model.plannedStart(for: try XCTUnwrap(model.timingActivity))
        )
        XCTAssertNil(model.routeEstimate)
    }

    func testInvalidRouteDurationFallsBackToUnavailable() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 2,
                    hour: 11
                )
            )
        )
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(
            trip: trip,
            progressFileURL: root.appending(path: "progress.json"),
            calendar: calendar,
            now: { now },
            routeLoader: { activities, mode, _ in
                [
                    Self.leg(
                        from: activities[0],
                        to: activities[1],
                        mode: mode,
                        travelTime: .infinity
                    )
                ]
            }
        )

        await model.loadTiming()

        guard case .unavailable(let context) = model.timingState else {
            return XCTFail("Expected invalid route data to be unavailable")
        }
        XCTAssertEqual(context.destinationName, "Pastéis de Belém")
        XCTAssertNil(model.routeEstimate)
    }

    func testCancellationReturnsToNeutralPlannedState() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 2,
                    hour: 11
                )
            )
        )
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(
            trip: trip,
            progressFileURL: root.appending(path: "progress.json"),
            calendar: calendar,
            now: { now },
            routeLoader: { _, _, _ in throw CancellationError() }
        )

        await model.loadTiming()

        guard case .planned(let timing) = model.timingState else {
            return XCTFail("Cancellation must not leave a checking state")
        }
        XCTAssertEqual(timing.reason, .notChecked)
        XCTAssertNotNil(timing.plannedStart)
    }

    func testFirstStopUsesPlannedTimingWithoutCallingRouteProvider() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 1,
                    hour: 8
                )
            )
        )
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var singleStopTrip = trip
        var singleStopDay = Itinerary.preview.itinerary[0]
        singleStopDay.activities = Array(singleStopDay.activities.prefix(1))
        singleStopTrip.result?.itinerary = [singleStopDay]
        singleStopTrip.departureDate = singleStopTrip.arrivalDate
        var routeWasCalled = false
        let model = try makeModel(
            trip: singleStopTrip,
            progressFileURL: root.appending(path: "progress.json"),
            calendar: calendar,
            now: { now },
            routeLoader: { _, _, _ in
                routeWasCalled = true
                return []
            }
        )

        await model.loadTiming()

        guard case .planned(let timing) = model.timingState else {
            return XCTFail("Expected planned-only timing")
        }
        XCTAssertEqual(timing.destinationName, "Miradouro da Senhora do Monte")
        XCTAssertEqual(timing.reason, .noAdjacentOrigin)
        XCTAssertNotNil(timing.plannedStart)
        XCTAssertFalse(routeWasCalled)
    }

    func testMalformedPlannedTimeDoesNotProduceRouteTiming() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 2,
                    hour: 11
                )
            )
        )
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var malformedTrip = trip
        malformedTrip.result?.itinerary[1].activities[1].time = "after lunch"
        var routeWasCalled = false
        let model = try makeModel(
            trip: malformedTrip,
            progressFileURL: root.appending(path: "progress.json"),
            calendar: calendar,
            now: { now },
            routeLoader: { _, _, _ in
                routeWasCalled = true
                return []
            }
        )

        await model.loadTiming()

        guard case .planned(let timing) = model.timingState else {
            return XCTFail("Expected planned-only timing")
        }
        XCTAssertEqual(timing.reason, .invalidPlannedStart)
        XCTAssertNil(timing.plannedStart)
        XCTAssertFalse(routeWasCalled)
    }

    func testClockParserRejectsLossyMalformedComponents() {
        for value in [
            "12:bogus:30 PM",
            "12:bogus PM",
            "12::30 PM",
            ":30 PM",
            "12:30:45",
            "12:30 AM PM",
            "12:30 PM extra",
        ] {
            XCTAssertNil(
                TodayTripViewModel.minutesSinceMidnight(value),
                "Expected malformed clock to be rejected: \(value)"
            )
        }
        XCTAssertEqual(
            TodayTripViewModel.minutesSinceMidnight("12:30 PM"),
            12 * 60 + 30
        )
        XCTAssertEqual(
            TodayTripViewModel.minutesSinceMidnight("00:05"),
            5
        )
    }

    func testMissingDestinationTimeZoneStaysPlannedOnly() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(
            TimeZone(identifier: "America/Los_Angeles")
        )
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-02T18:00:00Z")
        )
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var missingZoneTrip = trip
        missingZoneTrip.result?.timeZoneIdentifier = nil
        var routeWasCalled = false
        let model = try makeModel(
            trip: missingZoneTrip,
            progressFileURL: root.appending(path: "progress.json"),
            calendar: calendar,
            now: { now },
            routeLoader: { _, _, _ in
                routeWasCalled = true
                return []
            }
        )

        await model.loadTiming()

        guard case .planned(let timing) = model.timingState else {
            return XCTFail("Expected missing-zone planned fallback")
        }
        XCTAssertEqual(timing.reason, .missingTimeZone)
        XCTAssertNil(timing.plannedStart)
        XCTAssertEqual(model.timingActivity?.time, "12:00")
        XCTAssertFalse(routeWasCalled)
    }

    func testInvalidDestinationTimeZoneStaysPlannedOnly() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(
            TimeZone(identifier: "America/Los_Angeles")
        )
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-02T18:00:00Z")
        )
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var invalidZoneTrip = trip
        invalidZoneTrip.result?.timeZoneIdentifier = "Mars/Olympus"
        var routeWasCalled = false
        let model = try makeModel(
            trip: invalidZoneTrip,
            progressFileURL: root.appending(path: "progress.json"),
            calendar: calendar,
            now: { now },
            routeLoader: { _, _, _ in
                routeWasCalled = true
                return []
            }
        )

        await model.loadTiming()

        guard case .planned(let timing) = model.timingState else {
            return XCTFail("Expected invalid-zone planned fallback")
        }
        XCTAssertEqual(timing.reason, .missingTimeZone)
        XCTAssertNil(timing.plannedStart)
        XCTAssertEqual(model.timingActivity?.time, "12:00")
        XCTAssertFalse(routeWasCalled)
    }

    func testAdjustmentProtectionCopyMatchesQuickRefinementBehavior() {
        XCTAssertEqual(
            TodayAdjustmentSheet.protectionCopy,
            "Quick refinements won't remove locked stops; nothing changes until you apply an edit."
        )
    }

    func testSkippedAdjacentOriginFallsBackWithoutRouteRequest() async throws {
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
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var routeWasCalled = false
        let model = try makeModel(
            trip: trip,
            progressFileURL: root.appending(path: "progress.json"),
            calendar: calendar,
            now: { now },
            routeLoader: { _, _, _ in
                routeWasCalled = true
                return []
            }
        )
        let origin = try XCTUnwrap(model.day?.activities.first)
        await model.set(.skipped, for: origin)

        await model.loadTiming()

        guard case .planned(let timing) = model.timingState else {
            return XCTFail("Expected planned-only timing")
        }
        XCTAssertEqual(timing.reason, .skippedOrigin)
        XCTAssertFalse(routeWasCalled)
    }

    func testProgressLoadDoesNotDiscardUnchangedInFlightRoute() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 2,
                    hour: 11
                )
            )
        )
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = ControlledTodayRouteLoader()
        let model = try makeModel(
            trip: trip,
            progressFileURL: root.appending(path: "progress.json"),
            calendar: calendar,
            now: { now },
            routeLoader: { activities, mode, _ in
                try await harness.load(activities: activities, mode: mode)
            }
        )

        let routeRequest = Task { await model.loadTiming() }
        for _ in 0..<10 where !harness.isWalkingRequestSuspended {
            await Task.yield()
        }
        XCTAssertTrue(harness.isWalkingRequestSuspended)

        await model.load()
        harness.resumeWalking()
        await routeRequest.value

        guard case .route(let estimate) = model.timingState else {
            return XCTFail("Unchanged progress must not discard the route response")
        }
        XCTAssertEqual(estimate.context.mode, .walking)
        XCTAssertEqual(estimate.expectedTravelTime, 45 * 60)
    }

    func testStaleRouteResponseCannotReplaceNewerMode() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 2,
                    hour: 11
                )
            )
        )
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = ControlledTodayRouteLoader()
        let model = try makeModel(
            trip: trip,
            progressFileURL: root.appending(path: "progress.json"),
            calendar: calendar,
            now: { now },
            routeLoader: { activities, mode, _ in
                try await harness.load(activities: activities, mode: mode)
            }
        )

        let staleRequest = Task { await model.loadTiming() }
        for _ in 0..<10 where !harness.isWalkingRequestSuspended {
            await Task.yield()
        }
        XCTAssertTrue(harness.isWalkingRequestSuspended)

        model.selectTransportMode(.driving)
        await model.loadTiming()
        harness.resumeWalking()
        await staleRequest.value

        guard case .route(let estimate) = model.timingState else {
            return XCTFail("Expected the newer driving estimate")
        }
        XCTAssertEqual(estimate.context.mode, .driving)
        XCTAssertEqual(estimate.expectedTravelTime, 8 * 60)
    }

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

        let model = try makeModel(
            trip: trip,
            progressFileURL: fileURL,
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

        let model = try makeModel(
            trip: destinationTrip,
            progressFileURL: root.appending(path: "progress.json"),
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

    private func makeModel(
        trip: SavedItinerary,
        progressFileURL: URL,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init,
        progressLoader: (@MainActor () async throws -> [
            TripStopID: TripStopStatus
        ])? = nil,
        routeLoader: @escaping TodayRouteLoader = {
            activities,
            mode,
            plannedArrival in
            try await DayRoutePlanner.route(
                activities: activities,
                mode: mode,
                arrivalDate: plannedArrival
            )
        }
    ) throws -> TodayTripViewModel {
        let storage = try PrivateStorageTestContext()
        return TodayTripViewModel(
            trip: trip,
            progressStore: SessionBoundTripProgressStore(
                store: storage.tripProgressStore(
                    fileURL: progressFileURL
                ),
                lease: storage.lease,
                identityCoordinator: storage.identityCoordinator
            ),
            calendar: calendar,
            now: now,
            progressLoader: progressLoader,
            routeLoader: routeLoader
        )
    }

    private var trip: SavedItinerary {
        var itinerary = Itinerary.preview
        itinerary.timeZoneIdentifier = "Etc/UTC"
        return SavedItinerary(
            jobId: "trip-1",
            status: .succeeded,
            title: "Lisbon",
            sourcePublicItineraryId: nil,
            city: "Lisbon",
            country: "Portugal",
            arrivalDate: "2026-08-01",
            departureDate: "2026-08-03",
            result: itinerary,
            error: nil,
            createdAt: "2026-01-01T00:00:00Z"
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    fileprivate static func leg(
        from origin: Activity,
        to destination: Activity,
        mode: TripTransportMode,
        travelTime: TimeInterval
    ) -> DayRouteLeg {
        DayRouteLeg(
            id: "\(origin.id)-\(destination.id)-\(mode.rawValue)",
            originName: origin.name,
            destinationName: destination.name,
            coordinates: [],
            expectedTravelTime: travelTime,
            distance: 1_200
        )
    }
}

private enum RouteTestError: Error {
    case unavailable
}

@MainActor
private final class ControlledTodayProgressLoader {
    private var continuation: CheckedContinuation<
        [TripStopID: TripStopStatus],
        Error
    >?

    var isSuspended: Bool {
        continuation != nil
    }

    func load() async throws -> [TripStopID: TripStopStatus] {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func cancel() {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: CancellationError())
    }
}

@MainActor
private final class ControlledTodayRouteLoader {
    private var walkingContinuation: CheckedContinuation<
        [DayRouteLeg],
        Error
    >?
    private var walkingActivities: [Activity] = []

    var isWalkingRequestSuspended: Bool {
        walkingContinuation != nil
    }

    func load(
        activities: [Activity],
        mode: TripTransportMode
    ) async throws -> [DayRouteLeg] {
        if mode == .walking {
            walkingActivities = activities
            return try await withCheckedThrowingContinuation { continuation in
                walkingContinuation = continuation
            }
        }
        return [
            TodayTripViewModelTests.leg(
                from: activities[0],
                to: activities[1],
                mode: mode,
                travelTime: 8 * 60
            )
        ]
    }

    func resumeWalking() {
        guard let continuation = walkingContinuation else { return }
        walkingContinuation = nil
        continuation.resume(
            returning: [
                TodayTripViewModelTests.leg(
                    from: walkingActivities[0],
                    to: walkingActivities[1],
                    mode: .walking,
                    travelTime: 45 * 60
                )
            ]
        )
    }
}
