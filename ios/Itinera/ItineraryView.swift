import MapKit
import SwiftUI

struct ItineraryView: View {
    @Environment(\.itineraTheme) private var theme

    @State private var itinerary: Itinerary
    let tripID: String?
    let tripTitle: String?
    let tripStartDate: String?
    let tripEndDate: String?

    @State private var selectedDay = 1
    @State private var selectedActivity: Activity?
    @State private var isShowingGoogleMapsExport = false
    @State private var transportMode: TripTransportMode = .walking
    @State private var routeLegs: [DayRouteLeg] = []
    @State private var routeState: RouteLoadState = .idle
    @State private var calendarStatusMessage: String?
    @State private var calendarErrorMessage: String?
    @State private var currentVersion: Int
    @State private var isShowingEditor = false
    @State private var isShowingTripTools = false
    @State private var isShowingAIEdit = false

    init(
        itinerary: Itinerary,
        tripID: String? = nil,
        tripTitle: String? = nil,
        tripStartDate: String? = nil,
        tripEndDate: String? = nil,
        tripVersion: Int = 1
    ) {
        _itinerary = State(initialValue: itinerary)
        self.tripID = tripID
        self.tripTitle = tripTitle
        self.tripStartDate = tripStartDate
        self.tripEndDate = tripEndDate
        _currentVersion = State(initialValue: tripVersion)
    }

    private var day: ItineraryDay? {
        itinerary.itinerary.first { $0.day == selectedDay }
    }

    var body: some View {
        ZStack {
            ItineraBackground()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let day {
                        ItineraBrandHeader(
                            eyebrow: "Day \(day.day) of \(itinerary.itinerary.count)",
                            title: day.theme,
                            message: "A paced overview of the day's stops."
                        )

                        if let calendarStatusMessage {
                            ItineraStatusBanner(
                                message: calendarStatusMessage,
                                kind: .success
                            )
                        }
                        if let calendarErrorMessage {
                            ItineraStatusBanner(
                                message: calendarErrorMessage,
                                kind: .error
                            )
                        }

                        daySelector

                        mapCard(for: day)

                        travelLegsCard(for: day)

                        HStack(spacing: 8) {
                            ItineraPill(
                                text: "\(day.activities.count) \(day.activities.count == 1 ? "stop" : "stops")",
                                systemImage: "mappin.and.ellipse"
                            )
                            ItineraPill(
                                text: itinerary.estimatedBudget,
                                systemImage: "banknote"
                            )
                        }

                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(day.activities.enumerated()), id: \.element.id) { index, activity in
                                ActivityTimelineRow(
                                    activity: activity,
                                    index: index,
                                    isLast: index == day.activities.count - 1,
                                    onSelect: { selectedActivity = activity }
                                )
                            }
                        }

                        if selectedDay == itinerary.itinerary.last?.day {
                            tripNotes
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 36)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        isShowingGoogleMapsExport = true
                    } label: {
                        Label("Export day to Google Maps", systemImage: "arrow.up.right.square")
                    }

                    ItineraryShareButton(
                        itinerary: itinerary,
                        tripTitle: resolvedTripTitle,
                        dateRange: tripDateRange
                    )

                    ItineraryPDFShareButton(
                        itinerary: itinerary,
                        tripTitle: resolvedTripTitle,
                        dateRange: tripDateRange
                    )

                    Button {
                        Task { await exportToCalendar() }
                    } label: {
                        Label("Add stops to Calendar", systemImage: "calendar.badge.plus")
                    }
                    .disabled(calendarStartDate == nil)

                    if tripID != nil {
                        Divider()
                        Button {
                            isShowingAIEdit = true
                        } label: {
                            Label("Ask AI to edit", systemImage: "sparkles")
                        }
                        Button {
                            isShowingEditor = true
                        } label: {
                            Label("Edit itinerary", systemImage: "slider.horizontal.3")
                        }
                        Button {
                            isShowingTripTools = true
                        } label: {
                            Label("Trip tools", systemImage: "checklist")
                        }
                    }
                } label: {
                    Label("Trip actions", systemImage: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            selectedDay = itinerary.itinerary.first?.day ?? 1
        }
        .onChange(of: selectedDay) { _, _ in
            selectedActivity = nil
            routeLegs = []
            routeState = .idle
        }
        .task(id: routeRequestID) {
            await loadRoute()
        }
        .sheet(item: $selectedActivity) { activity in
            ActivityDetailSheet(activity: activity, jobID: tripID)
                .environment(\.itineraTheme, theme)
        }
        .sheet(isPresented: $isShowingGoogleMapsExport) {
            if let day {
                GoogleMapsExportSheet(day: day)
                    .environment(\.itineraTheme, theme)
            }
        }
        .sheet(isPresented: $isShowingEditor) {
            if let tripID {
                NavigationStack {
                    TripEditorView(
                        jobID: tripID,
                        tripTitle: resolvedTripTitle,
                        itinerary: itinerary,
                        version: currentVersion
                    ) { revised, version in
                        itinerary = revised
                        currentVersion = version
                    }
                }
                .environment(\.itineraTheme, theme)
            }
        }
        .sheet(isPresented: $isShowingTripTools) {
            if let tripID {
                NavigationStack {
                    TripToolsView(jobID: tripID, tripTitle: resolvedTripTitle)
                }
                .environment(\.itineraTheme, theme)
            }
        }
        .sheet(isPresented: $isShowingAIEdit) {
            if let tripID {
                AIEditSheet(
                    jobID: tripID,
                    currentDay: selectedDay,
                    dayTheme: day?.theme ?? "",
                    version: currentVersion
                ) { revised, version in
                    itinerary = revised
                    currentVersion = version
                }
                .environment(\.itineraTheme, theme)
            }
        }
    }

    private var resolvedTripTitle: String {
        let cleaned = tripTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.flatMap { $0.isEmpty ? nil : $0 }
            ?? day?.theme
            ?? "Itinera trip"
    }

    private var calendarStartDate: Date? {
        TripLibraryOrganizer.localDate(tripStartDate ?? itinerary.itinerary.first?.date)
    }

    private var tripDateRange: String? {
        switch (tripStartDate, tripEndDate) {
        case let (start?, end?): "\(start) → \(end)"
        case let (start?, nil): start
        default: nil
        }
    }

    @MainActor
    private func exportToCalendar() async {
        guard let calendarStartDate else { return }
        calendarStatusMessage = nil
        calendarErrorMessage = nil
        do {
            let count = try await ItineraryCalendarExporter().export(
                itinerary: itinerary,
                tripStartDate: calendarStartDate,
                calendarTitle: resolvedTripTitle
            )
            calendarStatusMessage = "Added \(count) \(count == 1 ? "stop" : "stops") to Calendar."
        } catch {
            calendarErrorMessage = error.localizedDescription
        }
    }

    private var daySelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(itinerary.itinerary) { itineraryDay in
                    Button {
                        withAnimation(.snappy) {
                            selectedDay = itineraryDay.day
                        }
                    } label: {
                        HStack(spacing: 7) {
                            if selectedDay == itineraryDay.day {
                                Image(systemName: "location.fill")
                                    .font(.caption)
                            }
                            Text("Day \(itineraryDay.day)")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(
                            selectedDay == itineraryDay.day
                                ? theme.accentContrast
                                : theme.primaryText
                        )
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(
                            selectedDay == itineraryDay.day
                                ? theme.accent
                                : theme.surface,
                            in: Capsule()
                        )
                        .overlay {
                            if selectedDay != itineraryDay.day {
                                Capsule().stroke(theme.border, lineWidth: 1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(
                        selectedDay == itineraryDay.day ? .isSelected : []
                    )
                }
            }
        }
    }

    private func mapCard(for day: ItineraryDay) -> some View {
        DayMapView(
            activities: day.activities,
            routeLegs: routeLegs,
            selectedActivity: $selectedActivity
        )
            .frame(height: 270)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
            .overlay(alignment: .topLeading) {
                ItineraPill(text: "Stop overview", systemImage: "point.topleft.down.to.point.bottomright.curvepath", highlighted: true)
                    .padding(14)
            }
            .overlay {
                RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                    .stroke(theme.border.opacity(0.9), lineWidth: 1)
            }
            .shadow(color: theme.shadow, radius: 18, y: 8)
    }

    private var routeRequestID: String {
        "\(selectedDay)-\(transportMode.rawValue)-\(day?.activities.map(\.id).joined(separator: "|") ?? "empty")"
    }

    private func travelLegsCard(for day: ItineraryDay) -> some View {
        ItineraSurface {
            VStack(alignment: .leading, spacing: 14) {
                ItineraSectionHeading(
                    number: "GETTING AROUND",
                    title: "Live travel legs",
                    message: "Times and paths come from Apple Maps and may change with local conditions."
                )

                Picker("Travel mode", selection: $transportMode) {
                    ForEach(TripTransportMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch routeState {
                case .idle, .loading:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Checking live routes…")
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryText)
                    }
                    .frame(minHeight: 44)
                case .loaded:
                    if routeLegs.isEmpty {
                        Text(day.activities.count < 2 ? "Add another stop to compare travel time." : "No travel legs are needed.")
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryText)
                    } else {
                        ForEach(Array(routeLegs.enumerated()), id: \.element.id) { index, leg in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: transportMode.systemImage)
                                    .foregroundStyle(theme.route)
                                    .frame(width: 28, height: 28)
                                    .background(theme.route.opacity(0.1), in: Circle())

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Stop \(index + 1) → \(index + 2)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(theme.secondaryText)
                                    Text("\(leg.travelTimeLabel) · \(leg.distanceLabel)")
                                        .font(.headline)
                                        .foregroundStyle(theme.primaryText)
                                    Text("\(leg.originName) to \(leg.destinationName)")
                                        .font(.caption)
                                        .foregroundStyle(theme.secondaryText)
                                        .lineLimit(2)
                                }

                                Spacer(minLength: 0)
                            }
                        }
                    }
                case .fallback:
                    ItineraStatusBanner(
                        message: "Live directions aren't available right now. The map still shows your stop order.",
                        kind: .warning
                    )
                }
            }
        }
    }

    @MainActor
    private func loadRoute() async {
        guard let day else {
            routeLegs = []
            routeState = .loaded
            return
        }

        routeState = .loading
        do {
            let loaded = try await DayRoutePlanner.route(
                activities: day.activities,
                mode: transportMode
            )
            try Task.checkCancellation()
            routeLegs = loaded
            routeState = .loaded
        } catch is CancellationError {
            return
        } catch {
            routeLegs = []
            routeState = .fallback
        }
    }

    private var tripNotes: some View {
        VStack(spacing: 14) {
            ItineraSurface {
                VStack(alignment: .leading, spacing: 13) {
                    ItineraSectionHeading(
                        number: "FIELD NOTES",
                        title: "Good to know",
                        message: "A few details to keep the route smooth."
                    )

                    ForEach(itinerary.tips, id: \.self) { tip in
                        Label {
                            Text(tip)
                                .font(.subheadline)
                                .foregroundStyle(theme.primaryText)
                        } icon: {
                            Image(systemName: "sparkles")
                                .foregroundStyle(theme.highlight)
                        }
                    }
                }
            }

            ItineraSurface {
                HStack(spacing: 14) {
                    Image(systemName: "banknote.fill")
                        .font(.title2)
                        .foregroundStyle(theme.route)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Estimated trip budget")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                        Text(itinerary.estimatedBudget)
                            .font(.headline)
                            .foregroundStyle(theme.primaryText)
                    }
                    Spacer()
                }
            }
        }
    }
}

private struct GoogleMapsExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.itineraTheme) private var theme
    @Environment(\.openURL) private var openURL

    let day: ItineraryDay

    private var routeResult: Result<[GoogleMapsRouteSegment], Error> {
        Result { try GoogleMapsURLBuilder.routeSegments(for: day.activities) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ItineraBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ItineraBrandHeader(
                            eyebrow: "Day \(day.day) · Route export",
                            title: "Continue in Google Maps.",
                            message: "Your stops stay in itinerary order. Google Maps may adjust the path for live conditions."
                        )

                        switch routeResult {
                        case .success(let routes) where routes.isEmpty:
                            ItineraStatusBanner(
                                message: "This day doesn't have any stops to export.",
                                kind: .warning
                            )
                        case .success(let routes):
                            if routes.count > 1 {
                                ItineraStatusBanner(
                                    message: "This day uses \(routes.count) routes (Google Maps supports up to 5 stops per route). Open them in order; each route repeats the handoff stop.",
                                    kind: .warning
                                )
                            }

                            ForEach(routes) { route in
                                ItineraSurface {
                                    VStack(alignment: .leading, spacing: 14) {
                                        ItineraSectionHeading(
                                            number: routes.count == 1 ? "GOOGLE MAPS" : "ROUTE \(route.index) OF \(route.totalSegments)",
                                            title: route.activityNames.joined(separator: " → "),
                                            message: route.activityNames.count == 1
                                                ? "1 stop"
                                                : "\(route.activityNames.count) ordered stops"
                                        )

                                        Button {
                                            if let appURL = route.appURL {
                                                openURL(appURL) { accepted in
                                                    if !accepted { openURL(route.url) }
                                                }
                                            } else {
                                                openURL(route.url)
                                            }
                                        } label: {
                                            Label(route.title, systemImage: "arrow.up.right.square.fill")
                                        }
                                        .buttonStyle(ItineraPrimaryButtonStyle())
                                        .accessibilityHint("Opens Google Maps app")
                                    }
                                }
                            }
                        case .failure(let error):
                            ItineraStatusBanner(
                                message: error.localizedDescription,
                                kind: .error
                            )
                        }
                    }
                    .padding(18)
                    .padding(.bottom, 18)
                }
            }
            .navigationTitle("Google Maps")
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
}

struct DayMapView: View {
    @Environment(\.itineraTheme) private var theme

    let activities: [Activity]
    let routeLegs: [DayRouteLeg]
    @Binding var selectedActivity: Activity?

    @State private var cameraPosition: MapCameraPosition = .automatic

    private var hasValidCoordinates: Bool {
        activities.contains { $0.coordinates.lat != 0.0 || $0.coordinates.lng != 0.0 }
    }

    private var coordinates: [CLLocationCoordinate2D] {
        activities.map {
            CLLocationCoordinate2D(
                latitude: $0.coordinates.lat,
                longitude: $0.coordinates.lng
            )
        }
    }

    var body: some View {
        if !hasValidCoordinates {
            ContentUnavailableView(
                "Map unavailable",
                systemImage: "map.fill",
                description: Text("Location data isn't available for these stops.")
            )
        } else {
        Map(position: $cameraPosition) {
            if !routeLegs.isEmpty {
                ForEach(routeLegs) { leg in
                    MapPolyline(coordinates: leg.coordinates)
                        .stroke(
                            theme.route,
                            style: StrokeStyle(
                                lineWidth: 4,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                }
            } else if coordinates.count > 1 {
                MapPolyline(coordinates: coordinates)
                    .stroke(
                        theme.route,
                        style: StrokeStyle(
                            lineWidth: 3,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: [8, 7]
                        )
                    )
            }

            ForEach(Array(activities.enumerated()), id: \.element.id) { index, activity in
                Annotation(
                    "",
                    coordinate: CLLocationCoordinate2D(
                        latitude: activity.coordinates.lat,
                        longitude: activity.coordinates.lng
                    ),
                    anchor: .bottom
                ) {
                    Button {
                        selectedActivity = activity
                    } label: {
                        ZStack {
                            Circle()
                                .fill(theme.highlightStrong)
                                .frame(width: 38, height: 38)
                                .overlay {
                                    Circle().stroke(Color.white.opacity(0.9), lineWidth: 2)
                                }
                                .shadow(color: Color.black.opacity(0.22), radius: 5, y: 3)
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit().weight(.bold))
                                .foregroundStyle(Color.white)
                        }
                        .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop \(index + 1), \(activity.name)")
                    .accessibilityHint("Shows stop details")
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .onChange(of: activities) { _, _ in
            cameraPosition = .automatic
        }
        }
    }

}

private enum RouteLoadState {
    case idle
    case loading
    case loaded
    case fallback
}

struct ActivityTimelineRow: View {
    @Environment(\.itineraTheme) private var theme

    let activity: Activity
    let index: Int
    let isLast: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(theme.highlightStrong)
                        .frame(width: 34, height: 34)
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(Color.white)
                }
                .accessibilityHidden(true)

                if !isLast {
                    Rectangle()
                        .fill(theme.route.opacity(0.5))
                        .frame(width: 2)
                        .frame(minHeight: 128, maxHeight: .infinity)
                }
            }

            Button(action: onSelect) {
                ItineraSurface(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text(activity.time)
                                .font(.caption.monospacedDigit().weight(.bold))
                                .foregroundStyle(theme.route)
                            ItineraPill(text: activity.duration, systemImage: "clock")
                            Spacer(minLength: 0)
                            Image(systemName: icon(for: activity.type))
                                .foregroundStyle(theme.highlightStrong)
                                .accessibilityLabel(activity.type)
                        }

                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(activity.name)
                                .font(.system(.title3, design: .serif, weight: .bold))
                                .foregroundStyle(theme.primaryText)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(theme.secondaryText)
                        }

                        Text(activity.description)
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        Label(activity.address, systemImage: "mappin")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .padding(.bottom, isLast ? 0 : 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Stop \(index + 1), \(activity.name)")
    }

    private func icon(for type: String) -> String {
        switch type {
        case "food": return "fork.knife"
        case "culture": return "building.columns.fill"
        case "nature": return "leaf.fill"
        case "shopping": return "bag.fill"
        default: return "mappin.circle.fill"
        }
    }

}

private struct ActivityDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.itineraTheme) private var theme

    let activity: Activity
    let jobID: String?
    @State private var isReportingPlace = false
    @State private var reportStatus: String?

    var body: some View {
        NavigationStack {
            ZStack {
                ItineraBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ItineraBrandHeader(
                            eyebrow: "\(activity.time) · \(activity.duration)",
                            title: activity.name,
                            message: activity.description
                        )

                        StopMapView(activity: activity)
                            .frame(height: 220)
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: theme.cornerRadius,
                                    style: .continuous
                                )
                            )
                            .overlay {
                                RoundedRectangle(
                                    cornerRadius: theme.cornerRadius,
                                    style: .continuous
                                )
                                .stroke(theme.border, lineWidth: 1)
                            }

                        ItineraSurface {
                            VStack(alignment: .leading, spacing: 14) {
                                ItineraSectionHeading(
                                    number: activity.type.uppercased(),
                                    title: "Stop details",
                                    message: "Everything you need before you go."
                                )

                                Label(activity.address, systemImage: "mappin.and.ellipse")
                                    .font(.subheadline)
                                    .foregroundStyle(theme.primaryText)

                                if let openingHours = activity.openingHours, !openingHours.isEmpty {
                                    detailRow(
                                        title: "Hours",
                                        value: openingHours.joined(separator: "\n"),
                                        systemImage: "clock"
                                    )
                                }

                                if let estimatedCost = activity.estimatedCost, !estimatedCost.isEmpty {
                                    detailRow(
                                        title: "Estimated cost",
                                        value: estimatedCost,
                                        systemImage: "banknote"
                                    )
                                }

                                if let accessibilityNotes = activity.accessibilityNotes,
                                   !accessibilityNotes.isEmpty {
                                    detailRow(
                                        title: "Accessibility",
                                        value: accessibilityNotes,
                                        systemImage: "accessibility"
                                    )
                                }

                                if let phone = activity.phone,
                                   let phoneURL = URL(string: "tel:\(phone.filter { $0.isNumber || $0 == "+" })") {
                                    Link(destination: phoneURL) {
                                        Label("Call \(phone)", systemImage: "phone.fill")
                                    }
                                    .font(.subheadline.weight(.semibold))
                                }

                                if let reservationURL = activity.reservationUrl,
                                   let url = URL(string: reservationURL) {
                                    Link(destination: url) {
                                        Label("Reservation options", systemImage: "calendar.badge.plus")
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(theme.accent)
                                }

                                if let websiteURL = activity.websiteUrl,
                                   let url = URL(string: websiteURL) {
                                    Link(destination: url) {
                                        Label("Visit website", systemImage: "safari")
                                    }
                                    .font(.subheadline.weight(.semibold))
                                }

                                Button(action: openInMaps) {
                                    Label(
                                        "Open in Apple Maps",
                                        systemImage: "arrow.triangle.turn.up.right.diamond.fill"
                                    )
                                }
                                .buttonStyle(ItineraPrimaryButtonStyle())

                                if jobID != nil {
                                    Button {
                                        isReportingPlace = true
                                    } label: {
                                        Label("Report inaccurate place", systemImage: "exclamationmark.bubble")
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(theme.warning)
                                }

                                if let reportStatus {
                                    ItineraStatusBanner(message: reportStatus, kind: .success)
                                }
                            }
                        }
                    }
                    .padding(18)
                    .padding(.bottom, 18)
                }
            }
            .navigationTitle("Stop details")
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
        .sheet(isPresented: $isReportingPlace) {
            if let jobID {
                NavigationStack {
                    PlaceReportSheet(jobID: jobID, activity: activity) {
                        reportStatus = "Thanks—this place was flagged for review."
                    }
                }
                .environment(\.itineraTheme, theme)
            }
        }
    }

    private func detailRow(
        title: String,
        value: String,
        systemImage: String
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(theme.primaryText)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(theme.route)
        }
    }

    private func openInMaps() {
        let coordinate = CLLocationCoordinate2D(
            latitude: activity.coordinates.lat,
            longitude: activity.coordinates.lng
        )
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        mapItem.name = activity.name
        mapItem.openInMaps()
    }
}

private struct StopMapView: View {
    @Environment(\.itineraTheme) private var theme

    let activity: Activity

    @State private var cameraPosition: MapCameraPosition

    init(activity: Activity) {
        self.activity = activity
        let coordinate = CLLocationCoordinate2D(
            latitude: activity.coordinates.lat,
            longitude: activity.coordinates.lng
        )
        _cameraPosition = State(
            initialValue: .region(
                MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
                )
            )
        )
    }

    var body: some View {
        Map(position: $cameraPosition) {
            Annotation(
                activity.name,
                coordinate: CLLocationCoordinate2D(
                    latitude: activity.coordinates.lat,
                    longitude: activity.coordinates.lng
                )
            ) {
                ItineraLogoMark(size: 38)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .including([.cafe, .museum, .park, .restaurant])))
        .mapControls {
            MapCompass()
        }
    }
}

#Preview("Atlas · Itinerary") {
    NavigationStack {
        ItineraryView(itinerary: .preview)
            .navigationTitle("Lisbon, Portugal")
    }
    .environment(\.itineraTheme, .atlas)
    .preferredColorScheme(.light)
}

private struct AIEditSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.itineraTheme) private var theme

    let jobID: String
    let currentDay: Int
    let dayTheme: String
    let version: Int
    let onApply: (Itinerary, Int) -> Void

    @State private var message = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private let suggestions: [(label: String, prompt: String)] = [
        ("More food stops", "Add more local food spots and dining experiences to the afternoon"),
        ("Add morning activity", "Add an early morning activity before the first listed stop"),
        ("More relaxed pace", "Make this day more relaxed — fewer stops, more time at each location"),
        ("Hidden gems only", "Replace touristy spots with lesser-known local favorites that most visitors miss"),
        ("Optimize route order", "Reorder the activities to create a smarter route with less backtracking"),
        ("Add a sunset stop", "Add a scenic viewpoint or rooftop stop timed to catch the sunset"),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                ItineraBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ItineraBrandHeader(
                            eyebrow: "Day \(currentDay) · AI assistant",
                            title: "What would you like to change?",
                            message: "Tap a suggestion to apply it instantly, or describe your own change below."
                        )

                        if let errorMessage {
                            ItineraStatusBanner(message: errorMessage, kind: .error)
                        }

                        ItineraSurface {
                            VStack(alignment: .leading, spacing: 4) {
                                ItineraSectionHeading(
                                    number: "QUICK EDITS",
                                    title: dayTheme.isEmpty ? "Day \(currentDay)" : dayTheme,
                                    message: "Tap to apply to the current day"
                                )
                                VStack(spacing: 0) {
                                    ForEach(suggestions, id: \.label) { suggestion in
                                        Button {
                                            Task { await submit(suggestion.prompt) }
                                        } label: {
                                            HStack {
                                                Text(suggestion.label)
                                                    .font(.subheadline)
                                                    .foregroundStyle(theme.primaryText)
                                                Spacer()
                                                if isWorking && message == suggestion.prompt {
                                                    ProgressView()
                                                        .scaleEffect(0.8)
                                                } else {
                                                    Image(systemName: "chevron.right")
                                                        .font(.caption)
                                                        .foregroundStyle(theme.secondaryText)
                                                }
                                            }
                                            .padding(.vertical, 12)
                                        }
                                        .disabled(isWorking)

                                        if suggestion.label != suggestions.last?.label {
                                            Divider()
                                        }
                                    }
                                }
                            }
                        }

                        ItineraSurface {
                            VStack(alignment: .leading, spacing: 14) {
                                ItineraSectionHeading(
                                    number: "CUSTOM",
                                    title: "Your own request",
                                    message: "Describe any change in your own words"
                                )
                                TextField(
                                    "e.g. Swap the museum for a rooftop bar at sunset",
                                    text: $message,
                                    axis: .vertical
                                )
                                .lineLimit(3...6)
                                .textFieldStyle(.plain)
                                .font(.subheadline)
                                .foregroundStyle(theme.primaryText)
                                .disabled(isWorking)

                                Button {
                                    Task { await submit(message) }
                                } label: {
                                    if isWorking && !suggestions.map(\.prompt).contains(message) {
                                        HStack {
                                            ProgressView()
                                                .scaleEffect(0.85)
                                                .tint(.white)
                                            Text("Updating itinerary...")
                                        }
                                    } else {
                                        Label("Apply change", systemImage: "sparkles")
                                    }
                                }
                                .buttonStyle(ItineraPrimaryButtonStyle())
                                .disabled(isWorking || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                    .padding(18)
                    .padding(.bottom, 18)
                }
            }
            .navigationTitle("Ask AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isWorking)
    }

    @MainActor
    private func submit(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        message = text
        do {
            let response = try await appState.aiEditTrip(
                jobID: jobID,
                message: trimmed,
                day: currentDay,
                expectedVersion: version
            )
            onApply(response.result, response.toVersion)
            dismiss()
        } catch {
            isWorking = false
            errorMessage = error.localizedDescription
        }
    }
}

#Preview("Wayfinder · Itinerary") {
    NavigationStack {
        ItineraryView(itinerary: .preview)
            .navigationTitle("Lisbon, Portugal")
    }
    .environment(\.itineraTheme, .wayfinder)
    .preferredColorScheme(.light)
}
