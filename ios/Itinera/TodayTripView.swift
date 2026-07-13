import Combine
import MapKit
import SwiftUI
import WidgetKit

struct TodayRootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settingsPreferences: SettingsPreferences
    @Environment(\.itineraTheme) private var theme

    var onPlanTrip: () -> Void = {}
    var onOpenTrips: () -> Void = {}

    @State private var trips: [SavedItinerary] = []
    @State private var errorMessage: String?
    @State private var isLoading = false

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
                    TodayTripView(
                        trip: activeTrip,
                        progressStore: appState.tripProgressStore
                    )
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
                    }

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
        await appState.loadCachedTrips()
        trips = appState.cachedTrips
        do {
            let remoteTrips = try await appState.refreshTripLibrary()
            trips = remoteTrips
            if settingsPreferences.tripRemindersEnabled {
                try? await GenerationNotificationManager.shared
                    .scheduleTripReminders(for: remoteTrips)
            }
            await appState.reconcilePending(with: remoteTrips)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            if trips.isEmpty {
                errorMessage = error.localizedDescription
            } else {
                errorMessage = "Today is using the offline copy saved on this iPhone."
            }
        }
        if activeTrip == nil {
            TripWidgetSnapshotStore.clear()
            WidgetCenter.shared.reloadTimelines(ofKind: ItineraWidgetKind.nextStop)
        }
    }
}

@MainActor
final class TodayTripViewModel: ObservableObject {
    let trip: SavedItinerary

    @Published private(set) var statuses: [TripStopID: TripStopStatus] = [:]
    @Published private(set) var errorMessage: String?

    private let progressStore: TripProgressStore
    private let calendar: Calendar
    private let now: () -> Date

    private var destinationCalendar: Calendar {
        var value = calendar
        if let identifier = trip.result?.timeZoneIdentifier,
           let timeZone = TimeZone(identifier: identifier) {
            value.timeZone = timeZone
        }
        return value
    }

    init(
        trip: SavedItinerary,
        progressStore: TripProgressStore,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.trip = trip
        self.progressStore = progressStore
        self.calendar = calendar
        self.now = now
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
            statuses = try await progressStore.progress(for: trip.jobId)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Trip progress could not be loaded on this iPhone."
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
            try await progressStore.set(status, for: stopID)
            statuses[stopID] = status
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "That update could not be saved on this iPhone."
        }
    }

    private static func minutesSinceMidnight(_ value: String) -> Int? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let isPM = normalized.hasSuffix("PM")
        let isAM = normalized.hasSuffix("AM")
        let clock = normalized
            .replacingOccurrences(of: "AM", with: "")
            .replacingOccurrences(of: "PM", with: "")
            .trimmingCharacters(in: .whitespaces)
        let pieces = clock.split(separator: ":").compactMap { Int($0) }
        guard pieces.count == 2, (0...59).contains(pieces[1]) else { return nil }
        var hour = pieces[0]
        if isAM || isPM {
            guard (1...12).contains(hour) else { return nil }
            if hour == 12 { hour = 0 }
            if isPM { hour += 12 }
        } else if !(0...23).contains(hour) {
            return nil
        }
        return hour * 60 + pieces[1]
    }
}

struct TodayTripView: View {
    @Environment(\.itineraTheme) private var theme
    @StateObject private var model: TodayTripViewModel
    @State private var liveActivityID: String?
    @State private var liveActivityError: String?

    init(trip: SavedItinerary, progressStore: TripProgressStore) {
        _model = StateObject(
            wrappedValue: TodayTripViewModel(
                trip: trip,
                progressStore: progressStore
            )
        )
    }

    var body: some View {
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
                        progressCard(day: day)

                        if let current = model.currentActivity {
                            ItineraSectionHeading(
                                number: "NOW",
                                title: "Your next move",
                                message: "Directions and progress stay one tap away."
                            )
                            currentStopCard(current)
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
            await model.load()
            updateWidgetSnapshot()
        }
        .onChange(of: model.statuses) { _, _ in
            updateWidgetSnapshot()
            Task { await updateLiveActivity() }
        }
    }

    private func progressCard(day: ItineraryDay) -> some View {
        ItineraSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Day progress")
                        .font(.headline)
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    Text("\(model.completedCount) of \(day.activities.count) complete")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(theme.secondaryText)
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
                    HStack {
                        ItineraPill(
                            text: "Starts at \(activity.time)",
                            systemImage: "clock.fill",
                            highlighted: true
                        )
                    ItineraPill(text: activity.duration, systemImage: "clock")
                    Spacer()
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

                HStack(spacing: 10) {
                    Button {
                        Task { await model.set(.completed, for: activity) }
                    } label: {
                        Label("Complete", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(theme.success)

                    Button {
                        Task { await model.set(.skipped, for: activity) }
                    } label: {
                        Label("Skip", systemImage: "forward.fill")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(theme.secondaryText)
                }
            }
        }
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
        if let liveActivityID, let state = model.liveActivityState {
            await TripLiveActivityManager.shared.end(
                activityID: liveActivityID,
                finalState: state
            )
            self.liveActivityID = nil
            liveActivityError = nil
            return
        }

        guard let state = model.liveActivityState else { return }
        do {
            liveActivityID = try TripLiveActivityManager.shared.start(
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
        guard let liveActivityID else { return }
        guard let state = model.liveActivityState else {
            await TripLiveActivityManager.shared.endAll()
            self.liveActivityID = nil
            return
        }
        await TripLiveActivityManager.shared.update(
            activityID: liveActivityID,
            state: state,
            staleDate: state.leaveBy?.addingTimeInterval(90 * 60)
        )
    }

    private func updateWidgetSnapshot() {
        guard let state = model.liveActivityState else {
            TripWidgetSnapshotStore.clear()
            WidgetCenter.shared.reloadTimelines(ofKind: ItineraWidgetKind.nextStop)
            return
        }
        let snapshot = TripWidgetSnapshot(
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
        if TripWidgetSnapshotStore.save(snapshot) {
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
