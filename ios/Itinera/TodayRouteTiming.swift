import Foundation

typealias TodayRouteLoader = @MainActor (
    [Activity],
    TripTransportMode,
    Date?
) async throws -> [DayRouteLeg]

enum TodayTimingFallbackReason: Equatable {
    case notChecked
    case noAdjacentOrigin
    case skippedOrigin
    case missingTimeZone
    case invalidPlannedStart
}

struct TodayTimingContext: Equatable {
    let originID: String
    let originName: String
    let destinationID: String
    let destinationName: String
    let mode: TripTransportMode
    let plannedStart: Date
}

struct TodayPlannedTiming: Equatable {
    let destinationID: String
    let destinationName: String
    let plannedStart: Date?
    let mode: TripTransportMode
    let reason: TodayTimingFallbackReason
}

enum TodayRouteTimingBasis: Equatable {
    case current
    case arriveBy(Date)
}

struct TodayRouteEstimate: Equatable {
    let context: TodayTimingContext
    let basis: TodayRouteTimingBasis
    let expectedTravelTime: TimeInterval
    let distance: Double
    let leaveBy: Date
    let estimatedArrival: Date
    let checkedAt: Date

    var travelTimeLabel: String {
        let minutes = max(1, Int((expectedTravelTime / 60).rounded()))
        if minutes < 60 {
            return "\(minutes) min"
        }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0
            ? "\(hours) hr"
            : "\(hours) hr \(remainder) min"
    }

    func isLeaveByPast(at date: Date) -> Bool {
        date >= leaveBy
    }

    func accessibilitySummary(
        currentTime: Date,
        timeZone: TimeZone,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let deadlineStatus: String
        if isLeaveByPast(at: currentTime) {
            switch basis {
            case .current:
                deadlineStatus = " Leave now from \(context.originName); the calculated leave-by has passed."
            case .arriveBy:
                deadlineStatus = " The calculated leave-by has passed. Recheck the transit route for current options or adjust the plan."
            }
        } else {
            deadlineStatus = ""
        }
        let arrivalSummary: String
        switch basis {
        case .current:
            let projectedArrival = currentTime.addingTimeInterval(
                expectedTravelTime
            )
            arrivalSummary = " Estimated arrival \(formatter.string(from: projectedArrival)) if departing \(context.originName) now at \(formatter.string(from: currentTime))."
        case .arriveBy(let arrival):
            arrivalSummary = " Estimated arrival \(formatter.string(from: arrival)) on an Apple Maps transit route requested to arrive by the planned start."
        }
        return "\(context.destinationName). Route estimate. "
            + "Planned start \(formatter.string(from: context.plannedStart)). "
            + "Leave by \(formatter.string(from: leaveBy))."
            + deadlineStatus
            + arrivalSummary + " "
            + "Planned leg from \(context.originName) to \(context.destinationName), \(Self.modeName(context.mode)), \(travelTimeLabel). "
            + "Apple Maps, checked \(formatter.string(from: checkedAt)). Itinera does not use your location."
    }

    private static func modeName(_ mode: TripTransportMode) -> String {
        switch mode {
        case .walking: return "Walking"
        case .transit: return "Transit"
        case .driving: return "Driving"
        }
    }
}

enum TodayTimingState: Equatable {
    case idle
    case planned(TodayPlannedTiming)
    case checking(TodayTimingContext)
    case route(TodayRouteEstimate)
    case unavailable(TodayTimingContext)

    var destinationID: String? {
        switch self {
        case .idle:
            return nil
        case .planned(let timing):
            return timing.destinationID
        case .checking(let context),
             .unavailable(let context):
            return context.destinationID
        case .route(let estimate):
            return estimate.context.destinationID
        }
    }
}
