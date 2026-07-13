import ActivityKit
import Foundation
import SwiftUI

enum PrivateSurfaceScopeError: LocalizedError, Equatable, Sendable {
    case activeScopeRequired
    case staleScope

    var errorDescription: String? {
        switch self {
        case .activeScopeRequired:
            return "Itinera is still opening your private library."
        case .staleScope:
            return "This update belongs to a private library that is no longer active."
        }
    }
}

@MainActor
protocol TripLiveActivitySurfaceManaging: AnyObject {
    var hasActiveActivities: Bool { get }

    func establishActiveSession(_ session: PrivatePresentationSession)
    func invalidateActiveSession()
    func endAll() async
}

@MainActor
final class TripLiveActivityManager: TripLiveActivitySurfaceManaging {
    static let shared = TripLiveActivityManager()

    private struct ScopeLease: Equatable {
        let session: PrivatePresentationSession
        let generation: UInt64
    }

    private var activeSession: PrivatePresentationSession?
    private var generation: UInt64 = 0

    var hasActiveActivities: Bool {
        ActivityKit.Activity<TripActivityAttributes>.activities.contains {
            $0.activityState != .ended && $0.activityState != .dismissed
        }
    }

    func establishActiveSession(_ session: PrivatePresentationSession) {
        guard activeSession != session else { return }
        advanceGeneration()
        activeSession = generation == .max ? nil : session
    }

    func invalidateActiveSession() {
        advanceGeneration()
        activeSession = nil
    }

    func start(
        presentationSession: PrivatePresentationSession,
        tripID: String,
        tripTitle: String,
        state: TripActivityAttributes.ContentState
    ) throws -> String? {
        _ = try captureLease(expectedSession: presentationSession)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }
        let activity = try ActivityKit.Activity<TripActivityAttributes>.request(
            attributes: TripActivityAttributes(
                presentationSession: presentationSession,
                tripID: tripID,
                tripTitle: tripTitle
            ),
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil
        )
        return activity.id
    }

    func update(
        activityID: String,
        expectedSession: PrivatePresentationSession,
        state: TripActivityAttributes.ContentState,
        staleDate: Date? = nil
    ) async {
        guard let lease = try? captureLease(expectedSession: expectedSession) else {
            return
        }
        await Self.updateActivity(
            activityID: activityID,
            expectedSession: expectedSession,
            state: state,
            staleDate: staleDate
        )
        if !isCurrent(lease) {
            await Self.endActivityImmediately(
                activityID: activityID,
                expectedSession: expectedSession
            )
        }
    }

    func end(
        activityID: String,
        expectedSession: PrivatePresentationSession,
        finalState: TripActivityAttributes.ContentState
    ) async {
        await Self.endActivity(
            activityID: activityID,
            expectedSession: expectedSession,
            finalState: finalState
        )
    }

    func endActivities(notMatching session: PrivatePresentationSession) async {
        await Self.endActivitiesNotMatching(session)
    }

    func endAll() async {
        await Self.endAllActivities()
    }

    private func captureLease(
        expectedSession: PrivatePresentationSession
    ) throws -> ScopeLease {
        guard activeSession == expectedSession else {
            throw activeSession == nil
                ? PrivateSurfaceScopeError.activeScopeRequired
                : PrivateSurfaceScopeError.staleScope
        }
        return ScopeLease(session: expectedSession, generation: generation)
    }

    private func isCurrent(_ lease: ScopeLease) -> Bool {
        activeSession == lease.session && generation == lease.generation
    }

    private func advanceGeneration() {
        guard generation < .max else {
            activeSession = nil
            return
        }
        generation += 1
    }

    private nonisolated static func updateActivity(
        activityID: String,
        expectedSession: PrivatePresentationSession,
        state: TripActivityAttributes.ContentState,
        staleDate: Date?
    ) async {
        guard let activity = ActivityKit.Activity<TripActivityAttributes>.activities
            .first(where: {
                $0.id == activityID
                    && $0.attributes.presentationSession == expectedSession
            }) else { return }
        await activity.update(ActivityContent(state: state, staleDate: staleDate))
    }

    private nonisolated static func endActivity(
        activityID: String,
        expectedSession: PrivatePresentationSession,
        finalState: TripActivityAttributes.ContentState
    ) async {
        guard let activity = ActivityKit.Activity<TripActivityAttributes>.activities
            .first(where: {
                $0.id == activityID
                    && $0.attributes.presentationSession == expectedSession
            }) else { return }
        await activity.end(
            ActivityContent(state: finalState, staleDate: nil),
            dismissalPolicy: .default
        )
    }

    private nonisolated static func endActivityImmediately(
        activityID: String,
        expectedSession: PrivatePresentationSession
    ) async {
        guard let activity = ActivityKit.Activity<TripActivityAttributes>.activities
            .first(where: {
                $0.id == activityID
                    && $0.attributes.presentationSession == expectedSession
            }) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    private nonisolated static func endActivitiesNotMatching(
        _ session: PrivatePresentationSession
    ) async {
        let oldActivities = ActivityKit.Activity<TripActivityAttributes>.activities
            .filter { $0.attributes.presentationSession != session }
        for activity in oldActivities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private nonisolated static func endAllActivities() async {
        let activities = ActivityKit.Activity<TripActivityAttributes>.activities
        for activity in activities {
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
        .privacySensitive()
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
