import ActivityKit
import Foundation

struct TripActivityAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        let dayNumber: Int
        let stopNumber: Int
        let totalStops: Int
        let currentStop: String?
        let nextStop: String
        let leaveBy: Date?
        let progress: Double

        init(
            dayNumber: Int,
            stopNumber: Int,
            totalStops: Int,
            currentStop: String?,
            nextStop: String,
            leaveBy: Date?,
            progress: Double
        ) {
            self.dayNumber = dayNumber
            self.stopNumber = stopNumber
            self.totalStops = totalStops
            self.currentStop = currentStop
            self.nextStop = nextStop
            self.leaveBy = leaveBy
            self.progress = min(max(progress, 0), 1)
        }
    }

    let presentationSession: PrivatePresentationSession
    let tripID: String
    let tripTitle: String
}
