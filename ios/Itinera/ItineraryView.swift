import MapKit
import SwiftUI

struct ItineraryView: View {
    @Environment(\.itineraTheme) private var theme

    let itinerary: Itinerary

    @State private var selectedDay = 1
    @State private var selectedActivity: Activity?

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

                        daySelector

                        mapCard(for: day)

                        HStack(spacing: 8) {
                            ItineraPill(
                                text: "\(day.activities.count) stops",
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
        .onAppear {
            selectedDay = itinerary.itinerary.first?.day ?? 1
        }
        .onChange(of: selectedDay) { _, _ in
            selectedActivity = nil
        }
        .sheet(item: $selectedActivity) { activity in
            ActivityDetailSheet(activity: activity)
                .environment(\.itineraTheme, theme)
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

struct DayMapView: View {
    @Environment(\.itineraTheme) private var theme

    let activities: [Activity]
    @Binding var selectedActivity: Activity?

    @State private var cameraPosition: MapCameraPosition = .automatic

    private var coordinates: [CLLocationCoordinate2D] {
        activities.map {
            CLLocationCoordinate2D(
                latitude: $0.coordinates.lat,
                longitude: $0.coordinates.lng
            )
        }
    }

    var body: some View {
        Map(position: $cameraPosition) {
            if coordinates.count > 1 {
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

                                Button(action: openInMaps) {
                                    Label(
                                        "Open in Apple Maps",
                                        systemImage: "arrow.triangle.turn.up.right.diamond.fill"
                                    )
                                }
                                .buttonStyle(ItineraPrimaryButtonStyle())
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

#Preview("Wayfinder · Itinerary") {
    NavigationStack {
        ItineraryView(itinerary: .preview)
            .navigationTitle("Lisbon, Portugal")
    }
    .environment(\.itineraTheme, .wayfinder)
    .preferredColorScheme(.light)
}
