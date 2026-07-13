import ActivityKit
import Foundation
import SwiftUI

struct TripLiveActivityManager: Sendable {
    static let shared = TripLiveActivityManager()

    func start(
        tripID: String,
        tripTitle: String,
        state: TripActivityAttributes.ContentState
    ) throws -> String? {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }
        let activity = try ActivityKit.Activity<TripActivityAttributes>.request(
            attributes: TripActivityAttributes(tripID: tripID, tripTitle: tripTitle),
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil
        )
        return activity.id
    }

    func update(
        activityID: String,
        state: TripActivityAttributes.ContentState,
        staleDate: Date? = nil
    ) async {
        guard let activity = ActivityKit.Activity<TripActivityAttributes>.activities
            .first(where: { $0.id == activityID }) else { return }
        await activity.update(ActivityContent(state: state, staleDate: staleDate))
    }

    func end(
        activityID: String,
        finalState: TripActivityAttributes.ContentState
    ) async {
        guard let activity = ActivityKit.Activity<TripActivityAttributes>.activities
            .first(where: { $0.id == activityID }) else { return }
        await activity.end(
            ActivityContent(state: finalState, staleDate: nil),
            dismissalPolicy: .default
        )
    }

    func endAll() async {
        for activity in ActivityKit.Activity<TripActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

/// Compact in-app representation of the shared Live Activity state.
struct TripLiveActivityCompactView: View {
    @Environment(\.itineraTheme) private var theme

    let tripTitle: String
    let state: TripActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ItineraLogoMark(size: 24)
                Text(tripTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text("\(state.stopNumber)/\(state.totalStops)")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(theme.secondaryText)
            }

            Text(state.nextStop)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            HStack {
                ProgressView(value: state.progress)
                    .tint(theme.accent)
                if let leaveBy = state.leaveBy {
                    Text(timerInterval: Date()...max(Date(), leaveBy), countsDown: true)
                        .font(.caption.monospacedDigit())
                }
            }
        }
        .padding(12)
        .foregroundStyle(theme.primaryText)
        .background(theme.surface)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var summary = "\(tripTitle). Next stop: \(state.nextStop). Stop \(state.stopNumber) of \(state.totalStops)."
        if let leaveBy = state.leaveBy {
            summary += " Leave by \(leaveBy.formatted(date: .omitted, time: .shortened))."
        }
        return summary
    }
}
