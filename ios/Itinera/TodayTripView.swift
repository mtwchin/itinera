import Combine
import MapKit
import SwiftUI
import WidgetKit

struct TodayRootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settingsPreferences: SettingsPreferences
    @Environment(\.itineraTheme) private var theme
    @Environment(\.privateAppSession) private var privateAppSession

    var onPlanTrip: () -> Void = {}
    var onOpenTrips: () -> Void = {}

    @State private var trips: [SavedItinerary] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var isShowingOfflineCopy = false
    @State private var isRetryingEmptyLibrary = false
    @AccessibilityFocusState private var retryErrorIsFocused: Bool

    private var serverSessionNeedsRecovery: Bool {
        if case .recoveryRequired = appState.identityPhase { return true }
        return false
    }

    private var activeTrip: SavedItinerary? {
        trips.first {
            TripLibraryOrganizer.group(for: $0) == .active
                && $0.result != nil
        }
    }

    private var nextTrip: SavedItinerary? {
        trips.first {
            TripLibraryOrganizer.group(for: $0) == .upcoming
                && $0.result != nil
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let activeTrip {
                    if let privateAppSession,
                       let progressStore = appState.tripProgressStore(
                           session: privateAppSession
                       ) {
                        TodayTripView(
                            trip: activeTrip,
                            progressStore: progressStore
                        )
                    }
                } else {
                    unavailableState
                }
            }
            .task(id: appState.libraryRevision) { await load() }
        }
    }

    private var unavailableState: some View {
        ZStack {
            ItineraBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ItineraBrandHeader(
                        eyebrow: "On the road",
                        title: "Your day will meet you here.",
                        message: "When a trip is active, Today shows the next stop, one-tap directions, and progress—even from your offline copy."
                    )

                    if let errorMessage {
                        ItineraStatusBanner(
                            message: errorMessage,
                            kind: .warning
                        )
                        .accessibilityFocused($retryErrorIsFocused)
                    }

                    if isShowingOfflineCopy && trips.isEmpty {
                        PrivateLibraryEmptyCard(
                            state: .noOfflineTrips,
                            actionTitle: serverSessionNeedsRecovery
                                ? "Retry Session"
                                : nil,
                            isWorking: isRetryingEmptyLibrary,
                            action: { Task { await retryEmptyLibrary() } }
                        )
                    } else {
                        ItineraSurface {
                            VStack(spacing: 17) {
                                Image(systemName: "location.fill.viewfinder")
                                    .font(.system(size: 38))
                                    .foregroundStyle(theme.route)
                                    .frame(width: 80, height: 80)
                                    .background(theme.route.opacity(0.1), in: Circle())

                                VStack(spacing: 6) {
                                    Text(nextTrip == nil ? "No active trip" : "Your next trip is ready")
                                        .font(.system(.title2, design: .serif, weight: .bold))
                                        .foregroundStyle(theme.primaryText)
                                    if let nextTrip {
                                        Text(nextTrip.displayTitle)
                                            .font(.headline)
                                            .foregroundStyle(theme.primaryText)
                                        if let arrivalDate = nextTrip.arrivalDate {
                                            Text("Starts \(arrivalDate)")
                                                .font(.subheadline.monospacedDigit())
                                                .foregroundStyle(theme.secondaryText)
                                        }
                                    } else {
                                        Text("Plan a dated trip or open your library to choose a route.")
                                            .font(.subheadline)
                                            .foregroundStyle(theme.secondaryText)
                                            .multilineTextAlignment(.center)
                                    }
                                }

                                Button(action: nextTrip == nil ? onPlanTrip : onOpenTrips) {
                                    Label(
                                        nextTrip == nil ? "Plan a trip" : "Open trip library",
                                        systemImage: nextTrip == nil ? "plus" : "suitcase.fill"
                                    )
                                }
                                .buttonStyle(ItineraPrimaryButtonStyle())
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(18)
                .padding(.bottom, 24)
            }

            if isLoading && trips.isEmpty {
                ProgressView()
                    .controlSize(.large)
                    .tint(theme.route)
                    .accessibilityLabel("Loading today's trip")
            }
        }
        .navigationTitle("Today")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let privateAppSession else { return }
        let presentationSession = privateAppSession.presentationSession
        await appState.loadCachedTrips(session: privateAppSession)
        guard await appState.isCurrent(privateAppSession) else { return }
        trips = appState.cachedTrips
        isShowingOfflineCopy = !trips.isEmpty
        do {
            let remoteTrips = try await appState.refreshTripLibrary(
                session: privateAppSession
            )
            guard await appState.isCurrent(privateAppSession) else {
                return
            }
            trips = remoteTrips
            if settingsPreferences.tripRemindersEnabled {
                try? await GenerationNotificationManager.shared
                    .scheduleTripReminders(
                        for: remoteTrips,
                        expectedSession: presentationSession
                    )
            }
            await appState.reconcilePending(
                with: remoteTrips,
                session: privateAppSession
            )
            errorMessage = nil
            isShowingOfflineCopy = false
        } catch is CancellationError {
            return
        } catch {
            guard await appState.isCurrent(privateAppSession) else { return }
            if trips.isEmpty {
                errorMessage = nil
            } else {
                errorMessage = "Today is using the offline copy saved on this iPhone."
            }
            isShowingOfflineCopy = true
        }
        guard await appState.isCurrent(privateAppSession) else { return }
        if activeTrip == nil {
            if TripWidgetSnapshotStore.clearSnapshot(
                expectedSession: presentationSession
            ) {
                WidgetCenter.shared.reloadTimelines(
                    ofKind: ItineraWidgetKind.nextStop
                )
            }
        }
    }

    private func retryEmptyLibrary() async {
        guard !isRetryingEmptyLibrary else { return }
        guard let privateAppSession else { return }
        isRetryingEmptyLibrary = true
        defer { isRetryingEmptyLibrary = false }
        retryErrorIsFocused = false
        if serverSessionNeedsRecovery {
            do {
                try await appState.retryServerSession(
                    session: privateAppSession
                )
            } catch {
                guard await appState.isCurrent(privateAppSession) else { return }
                errorMessage = error.localizedDescription
                retryErrorIsFocused = true
                return
            }
        }
        await load()
    }
}

#Preview(
    "Today · Offline empty · Compact accessibility",
    traits: .fixedLayout(width: 320, height: 760)
) {
    NavigationStack {
        ZStack {
            ItineraBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ItineraBrandHeader(
                        eyebrow: "On the road",
                        title: "Your day will meet you here.",
                        message: "Today can use only trips saved for this private library on this iPhone while offline."
                    )
                    PrivateLibraryEmptyCard(
                        state: .noOfflineTrips,
                        action: {}
                    )
                }
                .padding(18)
            }
        }
        .navigationTitle("Today")
        .navigationBarTitleDisplayMode(.inline)
    }
    .environment(\.itineraTheme, .atlas)
    .environment(\.dynamicTypeSize, .accessibility2)
    .preferredColorScheme(.light)
}

@MainActor
final class TodayTripViewModel: ObservableObject {
    @Published private(set) var trip: SavedItinerary

    @Published private(set) var statuses: [TripStopID: TripStopStatus] = [:]
    @Published private(set) var errorMessage: String?
    @Published private(set) var timingState: TodayTimingState = .idle
    @Published private(set) var transportMode: TripTransportMode = .walking
    @Published private(set) var hasLoadedProgress = false

    private let progressStore: SessionBoundTripProgressStore
    private let progressLoader: @MainActor () async throws -> [
        TripStopID: TripStopStatus
    ]
    private let calendar: Calendar
    private let now: () -> Date
    private let routeLoader: TodayRouteLoader
    private var activeTimingRequestID: UUID?

    var destinationTimeZone: TimeZone? {
        guard let identifier = trip.result?.timeZoneIdentifier else {
            return nil
        }
        return TimeZone(identifier: identifier)
    }

    var destinationCalendar: Calendar {
        var value = calendar
        if let timeZone = destinationTimeZone {
            value.timeZone = timeZone
        }
        return value
    }

    init(
        trip: SavedItinerary,
        progressStore: SessionBoundTripProgressStore,
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
    ) {
        self.trip = trip
        self.progressStore = progressStore
        self.calendar = calendar
        self.now = now
        self.progressLoader = progressLoader ?? {
            let progress = try await progressStore.progress(for: trip.jobId)
            guard await progressStore.canPublish(progress) else {
                throw IdentityCoordinatorError.staleIdentity
            }
            return progress.value
        }
        self.routeLoader = routeLoader
        setPlannedTimingState()
    }

    var day: ItineraryDay? {
        guard let itinerary = trip.result?.itinerary, !itinerary.isEmpty else {
            return nil
        }
        let calendar = destinationCalendar
        let today = calendar.startOfDay(for: now())
        if let datedDay = itinerary.first(where: {
            TripLibraryOrganizer.localDate($0.date, calendar: calendar) == today
        }) {
            return datedDay
        }
        guard let arrival = TripLibraryOrganizer.localDate(
            trip.arrivalDate,
            calendar: calendar
        ) else {
            return itinerary.first
        }
        let startOfToday = calendar.startOfDay(for: now())
        let offset = calendar.dateComponents(
            [.day],
            from: arrival,
            to: startOfToday
        ).day ?? 0
        let index = min(max(offset, 0), itinerary.count - 1)
        return itinerary[index]
    }

    var completedCount: Int {
        day?.activities.filter { status(for: $0) == .completed }.count ?? 0
    }

    var skippedCount: Int {
        day?.activities.filter { status(for: $0) == .skipped }.count ?? 0
    }

    var progressFraction: Double {
        guard let count = day?.activities.count, count > 0 else { return 0 }
        return Double(completedCount + skippedCount) / Double(count)
    }

    var currentActivity: Activity? {
        guard let day else { return nil }
        let calendar = destinationCalendar
        let actionable = day.activities.filter { status(for: $0) == .upcoming }
        guard !actionable.isEmpty else { return nil }

        let currentMinutes = calendar.component(.hour, from: now()) * 60
            + calendar.component(.minute, from: now())
        return actionable.last {
            guard let minutes = Self.minutesSinceMidnight($0.time) else {
                return false
            }
            return minutes <= currentMinutes
        } ?? actionable.first
    }

    var nextActivity: Activity? {
        guard
            let day,
            let currentActivity,
            let currentIndex = day.activities.firstIndex(of: currentActivity)
        else {
            return nil
        }
        return day.activities.dropFirst(currentIndex + 1).first {
            status(for: $0) == .upcoming
        }
    }

    /// The route estimate enhances the stop after the current planned stop
    /// when one exists. For the final actionable stop, it uses the immediately
    /// preceding planned stop. Neither case implies the traveler's location.
    var timingActivity: Activity? {
        nextActivity ?? currentActivity
    }

    var timingOriginActivity: Activity? {
        guard let day, let destination = timingActivity else { return nil }
        if let nextActivity, nextActivity.id == destination.id {
            return currentActivity
        }
        guard
            let destinationIndex = day.activities.firstIndex(of: destination),
            destinationIndex > 0
        else {
            return nil
        }
        return day.activities[destinationIndex - 1]
    }

    var routeRequestID: String {
        let origin = timingOriginActivity?.id ?? "no-origin"
        let destination = timingActivity?.id ?? "no-destination"
        let originStatus = timingOriginActivity.map { status(for: $0).rawValue }
            ?? "none"
        let timeZone = trip.result?.timeZoneIdentifier ?? "no-time-zone"
        return "\(trip.version)|\(timeZone)|\(origin)|\(originStatus)|\(destination)|\(transportMode.rawValue)"
    }

    var routeEstimate: TodayRouteEstimate? {
        guard case .route(let estimate) = timingState else { return nil }
        return estimate
    }

    func plannedStart(for activity: Activity) -> Date? {
        guard
            destinationTimeZone != nil,
            let day,
            let minutes = Self.minutesSinceMidnight(activity.time),
            let dayDate = itineraryDate(for: day)
        else {
            return nil
        }

        let calendar = destinationCalendar
        var components = calendar.dateComponents(
            [.era, .year, .month, .day],
            from: dayDate
        )
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.hour = minutes / 60
        components.minute = minutes % 60
        components.second = 0
        guard let date = calendar.date(from: components) else { return nil }
        let resolved = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        guard
            resolved.year == components.year,
            resolved.month == components.month,
            resolved.day == components.day,
            resolved.hour == components.hour,
            resolved.minute == components.minute
        else {
            return nil
        }
        return date
    }

    func selectTransportMode(_ mode: TripTransportMode) {
        guard mode != transportMode else { return }
        transportMode = mode
        activeTimingRequestID = nil
        setPlannedTimingState()
    }

    func loadTiming() async {
        guard let destination = timingActivity else {
            activeTimingRequestID = nil
            timingState = .idle
            return
        }
        guard destinationTimeZone != nil else {
            activeTimingRequestID = nil
            timingState = .planned(
                TodayPlannedTiming(
                    destinationID: destination.id,
                    destinationName: destination.name,
                    plannedStart: nil,
                    mode: transportMode,
                    reason: .missingTimeZone
                )
            )
            return
        }
        guard let plannedStart = plannedStart(for: destination) else {
            activeTimingRequestID = nil
            timingState = .planned(
                TodayPlannedTiming(
                    destinationID: destination.id,
                    destinationName: destination.name,
                    plannedStart: nil,
                    mode: transportMode,
                    reason: .invalidPlannedStart
                )
            )
            return
        }
        guard let origin = timingOriginActivity else {
            activeTimingRequestID = nil
            timingState = .planned(
                TodayPlannedTiming(
                    destinationID: destination.id,
                    destinationName: destination.name,
                    plannedStart: plannedStart,
                    mode: transportMode,
                    reason: .noAdjacentOrigin
                )
            )
            return
        }
        guard status(for: origin) != .skipped else {
            activeTimingRequestID = nil
            timingState = .planned(
                TodayPlannedTiming(
                    destinationID: destination.id,
                    destinationName: destination.name,
                    plannedStart: plannedStart,
                    mode: transportMode,
                    reason: .skippedOrigin
                )
            )
            return
        }

        let context = TodayTimingContext(
            originID: origin.id,
            originName: origin.name,
            destinationID: destination.id,
            destinationName: destination.name,
            mode: transportMode,
            plannedStart: plannedStart
        )
        let requestID = UUID()
        activeTimingRequestID = requestID
        timingState = .checking(context)

        do {
            guard await progressStore.isCurrent() else {
                throw IdentityCoordinatorError.staleIdentity
            }
            let plannedArrival = transportMode == .transit
                && plannedStart > now()
                ? plannedStart
                : nil
            let legs = try await routeLoader(
                [origin, destination],
                transportMode,
                plannedArrival
            )
            try Task.checkCancellation()
            guard await progressStore.isCurrent() else {
                throw IdentityCoordinatorError.staleIdentity
            }
            guard activeTimingRequestID == requestID else { return }
            guard
                let leg = legs.first,
                leg.expectedTravelTime.isFinite,
                leg.expectedTravelTime > 0
            else {
                activeTimingRequestID = nil
                timingState = .unavailable(context)
                return
            }
            let checkedAt = now()
            let basis: TodayRouteTimingBasis = plannedArrival.map {
                .arriveBy($0)
            } ?? .current
            activeTimingRequestID = nil
            timingState = .route(
                TodayRouteEstimate(
                    context: context,
                    basis: basis,
                    expectedTravelTime: leg.expectedTravelTime,
                    distance: leg.distance,
                    leaveBy: plannedStart.addingTimeInterval(
                        -leg.expectedTravelTime
                    ),
                    estimatedArrival: plannedArrival
                        ?? checkedAt.addingTimeInterval(
                            leg.expectedTravelTime
                        ),
                    checkedAt: checkedAt
                )
            )
        } catch is CancellationError {
            guard activeTimingRequestID == requestID else { return }
            activeTimingRequestID = nil
            setPlannedTimingState()
            return
        } catch is IdentityCoordinatorError {
            return
        } catch {
            guard await progressStore.isCurrent() else { return }
            guard activeTimingRequestID == requestID else { return }
            activeTimingRequestID = nil
            timingState = .unavailable(context)
        }
    }

    func loadTimingIfProgressReady() async {
        guard hasLoadedProgress else { return }
        await loadTiming()
    }

    func applyRevision(_ itinerary: Itinerary, version: Int) {
        let previousRequestID = routeRequestID
        trip.result = itinerary
        trip.version = version
        if routeRequestID != previousRequestID {
            activeTimingRequestID = nil
            setPlannedTimingState()
        }
    }

    var liveActivityState: TripActivityAttributes.ContentState? {
        guard let day, let currentActivity else { return nil }
        let currentIndex = day.activities.firstIndex(of: currentActivity) ?? 0
        return TripActivityAttributes.ContentState(
            dayNumber: day.day,
            stopNumber: currentIndex + 1,
            totalStops: day.activities.count,
            currentStop: currentIndex > 0 ? day.activities[currentIndex - 1].name : nil,
            nextStop: currentActivity.name,
            // Activity times describe the planned start, not a route-aware ETA.
            leaveBy: nil,
            progress: progressFraction
        )
    }

    func status(for activity: Activity) -> TripStopStatus {
        guard let day else { return .upcoming }
        return statuses[
            TripStopID(tripID: trip.jobId, day: day.day, activity: activity)
        ] ?? .upcoming
    }

    func load() async {
        do {
            let previousRequestID = routeRequestID
            let loadedStatuses = try await progressLoader()
            guard await progressStore.isCurrent() else { return }
            statuses = loadedStatuses
            if routeRequestID != previousRequestID {
                activeTimingRequestID = nil
                setPlannedTimingState()
            }
            errorMessage = nil
            hasLoadedProgress = true
        } catch is CancellationError {
            return
        } catch is IdentityCoordinatorError {
            return
        } catch {
            guard await progressStore.isCurrent() else { return }
            errorMessage = "Trip progress could not be loaded on this iPhone."
            hasLoadedProgress = true
        }
    }

    func set(_ status: TripStopStatus, for activity: Activity) async {
        guard let day else { return }
        let stopID = TripStopID(
            tripID: trip.jobId,
            day: day.day,
            activity: activity
        )
        do {
            let previousRequestID = routeRequestID
            try await progressStore.set(status, for: stopID)
            let scopedStatus = IdentityScopedValue(
                value: status,
                lease: progressStore.lease
            )
            guard await progressStore.canPublish(scopedStatus) else {
                throw IdentityCoordinatorError.staleIdentity
            }
            statuses[stopID] = status
            if routeRequestID != previousRequestID {
                activeTimingRequestID = nil
                setPlannedTimingState()
            }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch is IdentityCoordinatorError {
            return
        } catch {
            guard await progressStore.isCurrent() else { return }
            errorMessage = "That update could not be saved on this iPhone."
        }
    }

    private func itineraryDate(for day: ItineraryDay) -> Date? {
        let calendar = destinationCalendar
        if let datedDay = TripLibraryOrganizer.localDate(
            day.date,
            calendar: calendar
        ) {
            return datedDay
        }
        guard
            let arrival = TripLibraryOrganizer.localDate(
                trip.arrivalDate,
                calendar: calendar
            ),
            let itinerary = trip.result?.itinerary,
            let index = itinerary.firstIndex(where: { $0.day == day.day })
        else {
            return nil
        }
        return calendar.date(byAdding: .day, value: index, to: arrival)
    }

    private func setPlannedTimingState() {
        guard let destination = timingActivity else {
            timingState = .idle
            return
        }
        let reason: TodayTimingFallbackReason
        if destinationTimeZone == nil {
            reason = .missingTimeZone
        } else if plannedStart(for: destination) == nil {
            reason = .invalidPlannedStart
        } else if let origin = timingOriginActivity,
                  status(for: origin) == .skipped {
            reason = .skippedOrigin
        } else if timingOriginActivity != nil {
            reason = .notChecked
        } else {
            reason = .noAdjacentOrigin
        }
        timingState = .planned(
            TodayPlannedTiming(
                destinationID: destination.id,
                destinationName: destination.name,
                plannedStart: plannedStart(for: destination),
                mode: transportMode,
                reason: reason
            )
        )
    }

    static func minutesSinceMidnight(_ value: String) -> Int? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !normalized.isEmpty else { return nil }

        let suffix: String?
        let clock: String
        if normalized.hasSuffix("AM") || normalized.hasSuffix("PM") {
            suffix = String(normalized.suffix(2))
            clock = String(normalized.dropLast(2))
                .trimmingCharacters(in: .whitespaces)
        } else {
            suffix = nil
            clock = normalized
        }
        guard
            !clock.contains("AM"),
            !clock.contains("PM")
        else {
            return nil
        }
        let pieces = clock.split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard
            pieces.count == 2,
            !pieces[0].isEmpty,
            !pieces[1].isEmpty,
            pieces.allSatisfy({ $0.allSatisfy(\.isNumber) }),
            let parsedHour = Int(pieces[0]),
            let minute = Int(pieces[1]),
            (0...59).contains(minute)
        else {
            return nil
        }
        var hour = parsedHour
        let isAM = suffix == "AM"
        let isPM = suffix == "PM"
        if isAM || isPM {
            guard (1...12).contains(hour) else { return nil }
            if hour == 12 { hour = 0 }
            if isPM { hour += 12 }
        } else if !(0...23).contains(hour) {
            return nil
        }
        return hour * 60 + minute
    }
}

struct TodayTripView: View {
    @Environment(\.itineraTheme) private var theme
    @EnvironmentObject private var appState: AppState
    @Environment(\.privateAppSession) private var privateAppSession
    @StateObject private var model: TodayTripViewModel
    @State private var liveActivityID: String?
    @State private var liveActivityError: String?
    @State private var isShowingAdjustment = false
    @State private var presentationSession: PrivatePresentationSession?
    private let fixedTimingDate: Date?

    init(
        trip: SavedItinerary,
        progressStore: SessionBoundTripProgressStore,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init,
        fixedTimingDate: Date? = nil,
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
    ) {
        self.fixedTimingDate = fixedTimingDate
        _model = StateObject(
            wrappedValue: TodayTripViewModel(
                trip: trip,
                progressStore: progressStore,
                calendar: calendar,
                now: now,
                routeLoader: routeLoader
            )
        )
    }

    var body: some View {
        let progressReady = model.hasLoadedProgress
        let timingTaskID = "\(progressReady)|\(model.routeRequestID)"

        ZStack {
            ItineraBackground()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ItineraBrandHeader(
                        eyebrow: model.day.map { "Day \($0.day) · Today" } ?? "Today",
                        title: model.trip.displayTitle.isEmpty
                            ? "Your day at a glance."
                            : model.trip.displayTitle,
                        message: model.day?.theme
                            ?? "This trip does not have a route available yet."
                    )

                    if let errorMessage = model.errorMessage {
                        ItineraStatusBanner(
                            message: errorMessage,
                            kind: .warning
                        )
                    }

                    if let liveActivityError {
                        ItineraStatusBanner(
                            message: liveActivityError,
                            kind: .warning
                        )
                    }

                    if let day = model.day {
                        if let current = model.currentActivity {
                            ItineraSectionHeading(
                                number: "NOW",
                                title: "Your next move",
                                message: "Directions and progress stay one tap away."
                            )
                            currentStopCard(current)

                            if let timingActivity = model.timingActivity {
                                ItineraSectionHeading(
                                    number: "TIMING",
                                    title: "Plan the next leg",
                                    message: "Route estimates are separate from your itinerary's planned time."
                                )
                                ItineraSurface {
                                    TodayTimingPanel(
                                        activity: timingActivity,
                                        state: model.timingState,
                                        selectedMode: model.transportMode,
                                        timeZone: model.destinationCalendar.timeZone,
                                        canRefresh: progressReady,
                                        fixedCurrentTime: fixedTimingDate,
                                        onSelectMode: model.selectTransportMode,
                                        onRefresh: {
                                            Task {
                                                await model
                                                    .loadTimingIfProgressReady()
                                            }
                                        },
                                        onAdjust: {
                                            isShowingAdjustment = true
                                        }
                                    )
                                }
                            }
                        } else {
                            completedDayCard
                        }

                        if let next = model.nextActivity {
                            ItineraSectionHeading(
                                number: "NEXT",
                                title: "Coming up",
                                message: nil
                            )
                            compactStopCard(next)
                        }

                        progressCard(day: day)

                        ItineraSectionHeading(
                            number: "DAY \(day.day)",
                            title: "All stops",
                            message: "Completed and skipped stops are saved offline."
                        )
                        ForEach(day.activities) { activity in
                            TodayStopProgressRow(
                                activity: activity,
                                status: model.status(for: activity),
                                onSetStatus: { status in
                                    Task { await model.set(status, for: activity) }
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 36)
            }
        }
        .navigationTitle("Today")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await toggleLiveActivity() }
                } label: {
                    Label(
                        liveActivityID == nil ? "Show on Lock Screen" : "End Live Activity",
                        systemImage: liveActivityID == nil ? "livephoto" : "livephoto.slash"
                    )
                }
                .disabled(model.liveActivityState == nil)
            }
        }
        .task {
            guard let privateAppSession else { return }
            let session = privateAppSession.presentationSession
            presentationSession = session
            await model.load()
            guard await appState.isCurrent(privateAppSession) else {
                return
            }
            updateWidgetSnapshot()
        }
        .task(id: timingTaskID) {
            guard progressReady else { return }
            await model.loadTimingIfProgressReady()
        }
        .onChange(of: model.statuses) { _, _ in
            updateWidgetSnapshot()
            Task { await updateLiveActivity() }
        }
        .sheet(isPresented: $isShowingAdjustment) {
            if let day = model.day {
                TodayAdjustmentSheet(
                    trip: model.trip,
                    dayNumber: day.day,
                    timingState: model.timingState,
                    timingActivity: model.timingActivity,
                    onApplyRevision: model.applyRevision
                )
                .environment(\.itineraTheme, theme)
            }
        }
    }

    private func progressCard(day: ItineraryDay) -> some View {
        ItineraSurface {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        progressTitle
                        Spacer()
                        progressValue(day: day)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        progressTitle
                        progressValue(day: day)
                    }
                }
                ProgressView(value: model.progressFraction)
                    .tint(theme.route)
                    .accessibilityLabel("Day progress")
                    .accessibilityValue(
                        "\(model.completedCount) complete, \(model.skippedCount) skipped, out of \(day.activities.count) stops"
                    )
                if model.skippedCount > 0 {
                    Text("\(model.skippedCount) skipped")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
    }

    private func currentStopCard(_ activity: Activity) -> some View {
        ItineraSurface {
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        ItineraPill(
                            text: "Starts at \(activity.time)",
                            systemImage: "clock.fill",
                            highlighted: true
                        )
                    ItineraPill(text: activity.duration, systemImage: "clock")
                    Spacer()
                }
                    VStack(alignment: .leading, spacing: 8) {
                        ItineraPill(
                            text: "Starts at \(activity.time)",
                            systemImage: "clock.fill",
                            highlighted: true
                        )
                        ItineraPill(
                            text: activity.duration,
                            systemImage: "clock"
                        )
                    }
                }

                Text(activity.name)
                    .font(.system(.title2, design: .serif, weight: .bold))
                    .foregroundStyle(theme.primaryText)
                Text(activity.description)
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                Label(activity.address, systemImage: "mappin")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)

                Button {
                    openInMaps(activity)
                } label: {
                    Label(
                        "Directions in Apple Maps",
                        systemImage: "arrow.triangle.turn.up.right.diamond.fill"
                    )
                }
                .buttonStyle(ItineraPrimaryButtonStyle())

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        completeButton(for: activity)
                        skipButton(for: activity)
                    }
                    VStack(spacing: 10) {
                        completeButton(for: activity)
                        skipButton(for: activity)
                    }
                }
            }
        }
    }

    private var progressTitle: some View {
        Text("Day progress")
            .font(.headline)
            .foregroundStyle(theme.primaryText)
    }

    private func progressValue(day: ItineraryDay) -> some View {
        Text("\(model.completedCount) of \(day.activities.count) complete")
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(theme.secondaryText)
    }

    private func completeButton(for activity: Activity) -> some View {
        Button {
            Task { await model.set(.completed, for: activity) }
        } label: {
            Label("Complete", systemImage: "checkmark.circle.fill")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(theme.success)
    }

    private func skipButton(for activity: Activity) -> some View {
        Button {
            Task { await model.set(.skipped, for: activity) }
        } label: {
            Label("Skip", systemImage: "forward.fill")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(theme.secondaryText)
    }

    private func compactStopCard(_ activity: Activity) -> some View {
        ItineraSurface {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(activity.time)
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(theme.route)
                    Text(activity.name)
                        .font(.system(.headline, design: .serif, weight: .bold))
                        .foregroundStyle(theme.primaryText)
                    Text(activity.address)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer()
                Button { openInMaps(activity) } label: {
                    Image(systemName: "location.fill")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Directions to \(activity.name)")
            }
        }
    }

    private var completedDayCard: some View {
        ItineraSurface {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.largeTitle)
                    .foregroundStyle(theme.success)
                Text("Today's route is wrapped up")
                    .font(.system(.title3, design: .serif, weight: .bold))
                    .foregroundStyle(theme.primaryText)
                Text("Every stop is complete or intentionally skipped.")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func openInMaps(_ activity: Activity) {
        let coordinate = CLLocationCoordinate2D(
            latitude: activity.coordinates.lat,
            longitude: activity.coordinates.lng
        )
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = activity.name
        item.openInMaps()
    }

    @MainActor
    private func toggleLiveActivity() async {
        guard let presentationSession,
              let privateAppSession,
              await appState.isCurrent(privateAppSession) else { return }
        if let liveActivityID, let state = model.liveActivityState {
            await TripLiveActivityManager.shared.end(
                activityID: liveActivityID,
                expectedSession: presentationSession,
                finalState: state
            )
            guard await appState.isCurrent(privateAppSession) else { return }
            self.liveActivityID = nil
            liveActivityError = nil
            return
        }

        guard let state = model.liveActivityState else { return }
        do {
            liveActivityID = try TripLiveActivityManager.shared.start(
                presentationSession: presentationSession,
                tripID: model.trip.jobId,
                tripTitle: model.trip.displayTitle,
                state: state
            )
            if liveActivityID == nil {
                liveActivityError = "Live Activities are disabled in iOS Settings."
            } else {
                liveActivityError = nil
            }
        } catch {
            liveActivityError = "The Lock Screen activity couldn't be started."
        }
    }

    @MainActor
    private func updateLiveActivity() async {
        guard let liveActivityID,
              let presentationSession,
              let privateAppSession,
              await appState.isCurrent(privateAppSession) else { return }
        guard let state = model.liveActivityState else {
            await TripLiveActivityManager.shared.end(
                activityID: liveActivityID,
                expectedSession: presentationSession,
                finalState: .init(
                    dayNumber: 1,
                    stopNumber: 0,
                    totalStops: 0,
                    currentStop: nil,
                    nextStop: "Trip complete",
                    leaveBy: nil,
                    progress: 1
                )
            )
            guard await appState.isCurrent(privateAppSession) else { return }
            self.liveActivityID = nil
            return
        }
        await TripLiveActivityManager.shared.update(
            activityID: liveActivityID,
            expectedSession: presentationSession,
            state: state,
            staleDate: state.leaveBy?.addingTimeInterval(90 * 60)
        )
    }

    private func updateWidgetSnapshot() {
        guard let presentationSession else { return }
        guard let state = model.liveActivityState else {
            if TripWidgetSnapshotStore.clearSnapshot(
                expectedSession: presentationSession
            ) {
                WidgetCenter.shared.reloadTimelines(
                    ofKind: ItineraWidgetKind.nextStop
                )
            }
            return
        }
        let snapshot = TripWidgetSnapshot(
            presentationSession: presentationSession,
            tripID: model.trip.jobId,
            tripTitle: model.trip.displayTitle,
            dayNumber: state.dayNumber,
            stopNumber: state.stopNumber,
            totalStops: state.totalStops,
            currentStop: state.currentStop,
            nextStop: state.nextStop,
            leaveBy: state.leaveBy,
            progress: state.progress
        )
        if TripWidgetSnapshotStore.save(
            snapshot,
            expectedSession: presentationSession
        ) {
            WidgetCenter.shared.reloadTimelines(ofKind: ItineraWidgetKind.nextStop)
        }
    }
}

struct TodayStopProgressRow: View {
    @Environment(\.itineraTheme) private var theme

    let activity: Activity
    let status: TripStopStatus
    let onSetStatus: (TripStopStatus) -> Void

    var body: some View {
        ItineraSurface(padding: 14) {
            HStack(spacing: 12) {
                Image(systemName: statusIcon)
                    .font(.title3)
                    .foregroundStyle(statusColor)
                    .frame(width: 34, height: 34)
                    .background(statusColor.opacity(0.1), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(activity.name)
                        .font(.headline)
                        .foregroundStyle(theme.primaryText)
                        .strikethrough(status == .skipped)
                    Text("\(activity.time) · \(activity.duration)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                }

                Spacer(minLength: 0)

                Menu {
                    Button {
                        onSetStatus(.upcoming)
                    } label: {
                        Label("Mark upcoming", systemImage: "clock")
                    }
                    Button {
                        onSetStatus(.completed)
                    } label: {
                        Label("Mark complete", systemImage: "checkmark.circle")
                    }
                    Button {
                        onSetStatus(.skipped)
                    } label: {
                        Label("Mark skipped", systemImage: "forward")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Change status for \(activity.name)")
                .accessibilityValue(status.accessibilityName)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var statusIcon: String {
        switch status {
        case .upcoming: return "clock.fill"
        case .completed: return "checkmark.circle.fill"
        case .skipped: return "forward.circle.fill"
        }
    }

    private var statusColor: Color {
        switch status {
        case .upcoming: return theme.route
        case .completed: return theme.success
        case .skipped: return theme.secondaryText
        }
    }
}

private extension TripStopStatus {
    var accessibilityName: String {
        switch self {
        case .upcoming: return "Upcoming"
        case .completed: return "Complete"
        case .skipped: return "Skipped"
        }
    }
}

#Preview("Atlas · Route timing") {
    let context = TodayPreviewContext()
    NavigationStack {
        TodayTripView(
            trip: context.trip,
            progressStore: context.progressStore,
            calendar: context.calendar,
            now: { context.now },
            fixedTimingDate: context.now,
            routeLoader: { activities, mode, _ in
                [
                    DayRouteLeg(
                        id: "preview-\(mode.rawValue)",
                        originName: activities[0].name,
                        destinationName: activities[1].name,
                        coordinates: [],
                        expectedTravelTime: 20 * 60,
                        distance: 1_300
                    )
                ]
            }
        )
    }
    .environment(\.itineraTheme, .atlas)
    .preferredColorScheme(.light)
}

#Preview(
    "Atlas · Planned fallback · Compact",
    traits: .fixedLayout(width: 320, height: 900)
) {
    let context = TodayPreviewContext()
    NavigationStack {
        TodayTripView(
            trip: context.trip,
            progressStore: context.progressStore,
            calendar: context.calendar,
            now: { context.now },
            fixedTimingDate: context.now,
            routeLoader: { _, _, _ in
                throw TodayPreviewRouteError.unavailable
            }
        )
    }
    .environment(\.itineraTheme, .atlas)
    .preferredColorScheme(.light)
    .dynamicTypeSize(.accessibility2)
}

@MainActor
private struct TodayPreviewContext {
    let calendar: Calendar
    let now: Date
    let trip: SavedItinerary
    let progressStore: SessionBoundTripProgressStore

    init() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")
            ?? .current
        self.calendar = calendar
        self.now = calendar.date(
            from: DateComponents(
                year: 2026,
                month: 8,
                day: 2,
                hour: 11,
                minute: 5
            )
        ) ?? Date()

        var itinerary = Itinerary.preview
        itinerary.timeZoneIdentifier = "Europe/Lisbon"
        self.trip = SavedItinerary(
            jobId: "adaptive-today-preview",
            status: .succeeded,
            title: "Lisbon field guide",
            sourcePublicItineraryId: nil,
            city: "Lisbon",
            country: "Portugal",
            arrivalDate: "2026-08-01",
            departureDate: "2026-08-03",
            result: itinerary,
            error: nil,
            createdAt: "2026-01-01T00:00:00Z"
        )
        let scope = try! PrincipalScope(
            validating: String(repeating: "a", count: 64)
        )
        let presentationSessionID = UUID(
            uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        )!
        let lease = IdentityLease(
            scope: scope,
            epoch: 1,
            presentationSessionID: presentationSessionID
        )
        let coordinator = IdentityCoordinator(
            initialScope: scope,
            initialEpoch: lease.epoch,
            initialPresentationSessionID: presentationSessionID
        )
        let store = TripProgressStore(
            fileURL: FileManager.default.temporaryDirectory.appending(
                path: "itinera-adaptive-today-preview-progress.json"
            ),
            lease: lease,
            identityCoordinator: coordinator
        )
        progressStore = SessionBoundTripProgressStore(
            store: store,
            lease: lease,
            identityCoordinator: coordinator
        )
    }
}

private enum TodayPreviewRouteError: Error {
    case unavailable
}
