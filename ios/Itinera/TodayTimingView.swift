import SwiftUI

struct TodayTimingPanel: View {
    @Environment(\.itineraTheme) private var theme

    let activity: Activity
    let state: TodayTimingState
    let selectedMode: TripTransportMode
    let timeZone: TimeZone
    let canRefresh: Bool
    let fixedCurrentTime: Date?
    let onSelectMode: (TripTransportMode) -> Void
    let onRefresh: () -> Void
    let onAdjust: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            adaptiveHeader
            Divider().overlay(theme.border.opacity(0.7))

            switch state {
            case .route(let estimate):
                if let fixedCurrentTime {
                    routeContent(
                        estimate,
                        currentTime: fixedCurrentTime
                    )
                } else {
                    TimelineView(
                        .periodic(from: estimate.checkedAt, by: 60)
                    ) { timeline in
                        routeContent(
                            estimate,
                            currentTime: timeline.date
                        )
                    }
                }
            case .checking(let context):
                plannedContent(start: context.plannedStart)
                Label {
                    Text(
                        "Checking the \(modeName(context.mode).lowercased()) planned leg from \(context.originName) to \(context.destinationName)…"
                    )
                } icon: {
                    ProgressView()
                }
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
                .accessibilityLabel(
                    "Checking the \(modeName(context.mode).lowercased()) planned route from \(context.originName) to \(context.destinationName)"
                )
            case .unavailable(let context):
                plannedContent(start: context.plannedStart)
                ItineraStatusBanner(
                    message: "Apple Maps couldn't check the \(modeName(context.mode).lowercased()) planned leg from \(context.originName) to \(context.destinationName). Your plan hasn't changed.",
                    kind: .warning
                )
                retryButton
            case .planned(let timing):
                plannedContent(start: timing.plannedStart)
                Text(plannedExplanation(timing))
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if timing.reason == .notChecked {
                    retryButton
                }
            case .idle:
                Text("No timing is needed for this stop.")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
            }

            Button(action: onAdjust) {
                HStack(spacing: 12) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Running late?")
                            .font(.headline)
                        Text("Review today's options")
                            .font(.caption)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .tint(theme.highlightStrong)
            .accessibilityLabel("Running late? Review today's options")
            .accessibilityHint(
                "Explains adjustment choices. Opening it does not change the itinerary."
            )
        }
        .environment(\.timeZone, timeZone)
    }

    @ViewBuilder
    private var adaptiveHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                timingTitle
                Spacer(minLength: 12)
                modeMenu
            }
            VStack(alignment: .leading, spacing: 8) {
                timingTitle
                modeMenu
            }
        }
    }

    private var timingTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(stateIsRouteDerived ? "ROUTE ESTIMATE" : "PLANNED TIME")
                .font(.caption.monospacedDigit().weight(.bold))
                .tracking(1.1)
                .foregroundStyle(
                    stateIsRouteDerived ? theme.route : theme.highlightStrong
                )
            Text(activity.name)
                .font(.system(.headline, design: .serif, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modeMenu: some View {
        Menu {
            ForEach(TripTransportMode.allCases) { mode in
                Button {
                    onSelectMode(mode)
                } label: {
                    Label(
                        mode.title,
                        systemImage: mode == selectedMode
                            ? "checkmark"
                            : mode.systemImage
                    )
                }
            }
        } label: {
            Label(
                "Mode: \(selectedMode.title)",
                systemImage: selectedMode.systemImage
            )
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(theme.accent)
        .accessibilityLabel("Route mode")
        .accessibilityValue(selectedMode.title)
    }

    private func routeContent(
        _ estimate: TodayRouteEstimate,
        currentTime: Date
    ) -> some View {
        let projectedArrival = currentTime.addingTimeInterval(
            estimate.expectedTravelTime
        )
        let deadlinePassed = estimate.isLeaveByPast(at: currentTime)
        let arrivalTitle: String
        let arrivalDate: Date
        let leaveTitle: String
        let leaveDate: Date
        let routeBasisExplanation: String
        switch estimate.basis {
        case .current:
            leaveTitle = deadlinePassed
                ? "LEAVE NOW FROM \(estimate.context.originName.uppercased())"
                : "LEAVE BY"
            leaveDate = deadlinePassed ? currentTime : estimate.leaveBy
            arrivalTitle = "ETA IF LEAVING \(estimate.context.originName.uppercased()) NOW"
            arrivalDate = projectedArrival
            routeBasisExplanation = "ETA assumes departing \(estimate.context.originName) now (\(timeLabel(currentTime))). It does not use your location."
        case .arriveBy(let requestedArrival):
            leaveTitle = deadlinePassed ? "LEAVE-BY PASSED" : "LEAVE BY"
            leaveDate = estimate.leaveBy
            arrivalTitle = "ARRIVE BY"
            arrivalDate = requestedArrival
            routeBasisExplanation = "Transit timing uses an Apple Maps route requested to arrive by the planned start, \(timeLabel(requestedArrival)). It does not use your location."
        }

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        timingMetric(
                            title: leaveTitle,
                            date: leaveDate,
                            systemImage: "figure.walk.departure"
                        )
                        Divider()
                        timingMetric(
                            title: arrivalTitle,
                            date: arrivalDate,
                            systemImage: "flag.checkered"
                        )
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        timingMetric(
                            title: leaveTitle,
                            date: leaveDate,
                            systemImage: "figure.walk.departure"
                        )
                        Divider()
                        timingMetric(
                            title: arrivalTitle,
                            date: arrivalDate,
                            systemImage: "flag.checkered"
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        "\(modeName(estimate.context.mode)) · \(estimate.travelTimeLabel)",
                        systemImage: estimate.context.mode.systemImage
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.primaryText)

                    Text(
                        "Planned leg: \(estimate.context.originName) → \(estimate.context.destinationName)"
                    )
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                    Text(routeBasisExplanation)
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                    Text(
                        "Apple Maps · checked \(timeLabel(estimate.checkedAt)) · planned start \(timeLabel(estimate.context.plannedStart))"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if deadlinePassed {
                    ItineraStatusBanner(
                        message: deadlineMessage(
                            estimate,
                            projectedArrival: projectedArrival
                        ),
                        kind: .warning
                    )
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                estimate.accessibilitySummary(
                    currentTime: currentTime,
                    timeZone: timeZone
                )
            )

            retryButton
        }
    }

    private var retryButton: some View {
        Button(action: onRefresh) {
            Label("Check route again", systemImage: "arrow.clockwise")
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(theme.route)
        .disabled(!canRefresh)
        .accessibilityHint(
            canRefresh
                ? "Checks the named planned leg without changing the itinerary."
                : "Available after trip progress finishes loading."
        )
    }

    private func deadlineMessage(
        _ estimate: TodayRouteEstimate,
        projectedArrival: Date
    ) -> String {
        switch estimate.basis {
        case .current:
            return "Leave now from \(estimate.context.originName) to follow this planned leg. The calculated leave-by was \(timeLabel(estimate.leaveBy)); departing that named origin now gives an estimated arrival of \(timeLabel(projectedArrival))."
        case .arriveBy(let requestedArrival):
            return "The arrive-by route's calculated leave-by of \(timeLabel(estimate.leaveBy)) has passed, and that scheduled service may no longer be available. Check the route again for current transit options or review today's adjustments. Its requested arrival was \(timeLabel(requestedArrival))."
        }
    }

    private func plannedContent(start: Date?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("PLANNED START")
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(theme.secondaryText)
            if let start {
                Text(start, style: .time)
                    .font(.system(.title2, design: .serif, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(theme.primaryText)
            } else {
                Text(activity.time)
                    .font(.system(.title2, design: .serif, weight: .bold))
                    .foregroundStyle(theme.primaryText)
            }
            Text("This is itinerary time, not a route-derived leave-by.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    private func timingMetric(
        title: String,
        date: Date,
        systemImage: String
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(date, style: .time)
                    .font(.system(.title2, design: .serif, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(theme.primaryText)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(theme.route)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var stateIsRouteDerived: Bool {
        if case .route = state { return true }
        return false
    }

    private func plannedExplanation(_ timing: TodayPlannedTiming) -> String {
        switch timing.reason {
        case .notChecked:
            return "Route timing has not been checked yet. The planned start remains unchanged."
        case .noAdjacentOrigin:
            return "There is no reliable adjacent planned origin for this stop, so a route-derived leave-by is unavailable."
        case .skippedOrigin:
            return "The adjacent planned origin was skipped, so Itinera is not assuming where this leg begins."
        case .missingTimeZone:
            return "This itinerary has no valid destination time zone, so Itinera cannot turn the planned text into an absolute leave-by."
        case .invalidPlannedStart:
            return "This planned time could not be read, so Itinera cannot derive a truthful leave-by."
        }
    }

    private func modeName(_ mode: TripTransportMode) -> String {
        switch mode {
        case .walking: return "Walking"
        case .transit: return "Transit"
        case .driving: return "Driving"
        }
    }

    private func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}

struct TodayAdjustmentSheet: View {
    static let protectionCopy = "Quick refinements won't remove locked stops; nothing changes until you apply an edit."

    @Environment(\.dismiss) private var dismiss
    @Environment(\.itineraTheme) private var theme

    let trip: SavedItinerary
    let dayNumber: Int
    let timingState: TodayTimingState
    let timingActivity: Activity?
    let onApplyRevision: (Itinerary, Int) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                ItineraBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ItineraBrandHeader(
                            eyebrow: "Adjust today",
                            title: "When the day shifts.",
                            message: "Review the plan without losing your place. Nothing changes just by opening these options."
                        )

                        ItineraSurface {
                            VStack(alignment: .leading, spacing: 10) {
                                ItineraSectionHeading(
                                    number: "CURRENT CONTEXT",
                                    title: timingActivity?.name ?? "Today's plan",
                                    message: adjustmentContext
                                )
                                Label(
                                    Self.protectionCopy,
                                    systemImage: "lock.shield"
                                )
                                    .font(.footnote)
                                    .foregroundStyle(theme.secondaryText)
                            }
                        }

                        if let itinerary = trip.result {
                            NavigationLink {
                                TripEditorView(
                                    jobID: trip.jobId,
                                    tripTitle: trip.displayTitle,
                                    itinerary: itinerary,
                                    version: trip.version,
                                    initialDay: dayNumber,
                                    onApply: onApplyRevision
                                )
                            } label: {
                                Label(
                                    "Review today's plan",
                                    systemImage: "slider.horizontal.3"
                                )
                            }
                            .buttonStyle(ItineraPrimaryButtonStyle())
                            .accessibilityHint(
                                "Opens the existing itinerary editor. A change happens only after you choose an edit."
                            )
                        }

                        Button("Keep current plan") { dismiss() }
                            .buttonStyle(.bordered)
                            .tint(theme.accent)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                    }
                    .padding(18)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Adjust today")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var adjustmentContext: String {
        switch timingState {
        case .route(let estimate):
            return "\(estimate.travelTimeLabel) \(modeName(estimate.context.mode).lowercased()) planned leg from \(estimate.context.originName) to \(estimate.context.destinationName)."
        case .checking(let context), .unavailable(let context):
            return "Planned leg from \(context.originName) to \(context.destinationName)."
        case .planned(let timing):
            return "Planned timing only for \(timing.destinationName)."
        case .idle:
            return "No route timing is available."
        }
    }

    private func modeName(_ mode: TripTransportMode) -> String {
        switch mode {
        case .walking: return "Walking"
        case .transit: return "Transit"
        case .driving: return "Driving"
        }
    }
}
