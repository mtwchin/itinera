import SwiftUI
import MapKit
import UIKit

private struct MapStop: Identifiable {
    let id: Int
    let activity: Activity
    let coordinate: CLLocationCoordinate2D
}

struct ItineraryView: View {
    @State private var trip: SavedTrip
    private let allowSaving: Bool

    @EnvironmentObject private var tripStore: TripStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDay: Int = 1
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var showingRefineSheet = false

    init(trip: SavedTrip, allowSaving: Bool = false) {
        _trip = State(initialValue: trip)
        self.allowSaving = allowSaving
    }

    private var days: [DayPlan] { trip.itinerary.itinerary }

    private var currentDay: DayPlan? {
        days.first { $0.day == selectedDay } ?? days.first
    }

    private var isSaved: Bool { tripStore.contains(id: trip.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero

                dayMap

                dayPicker

                if let day = currentDay {
                    if let theme = day.theme, !theme.isEmpty {
                        Text(theme)
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .padding(.horizontal)
                    }

                    timeline(for: day)

                    if let routeURL = googleMapsRouteURL(for: day) {
                        Link(destination: routeURL) {
                            Label("Open Day \(day.day) route in Maps", systemImage: "map.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .padding(.horizontal)
                    }
                }

                tipsAndBudget
                trendingSection
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(trip.destination)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Haptics.tap()
                    showingRefineSheet = true
                } label: {
                    Image(systemName: "wand.and.rays")
                }

                ShareLink(item: TripFormatter.shareText(for: trip)) {
                    Image(systemName: "square.and.arrow.up")
                }

                if allowSaving {
                    Button(isSaved ? "Saved" : "Save") {
                        if !isSaved {
                            Haptics.success()
                            tripStore.add(trip)
                        }
                    }
                    .disabled(isSaved)
                }
            }
            if allowSaving {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showingRefineSheet) {
            RefineSheet(itinerary: trip.itinerary) { refined in
                trip.itinerary = refined
                selectedDay = refined.itinerary.first?.day ?? 1
                cameraPosition = .automatic
                if isSaved {
                    tripStore.update(trip)
                }
            }
        }
        .onAppear {
            selectedDay = days.first?.day ?? 1
        }
        .onChange(of: selectedDay) {
            cameraPosition = .automatic
        }
    }

    // MARK: - Header

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(trip.destination)
                .font(.system(.title, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
            HStack(spacing: 12) {
                Label(Format.dateRange(trip.startDate, trip.endDate), systemImage: "calendar")
                Label("\(trip.dayCount) day\(trip.dayCount == 1 ? "" : "s")", systemImage: "clock")
            }
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.9))

            if let countdown = Format.countdown(to: trip.startDate, end: trip.endDate) {
                Text(countdown)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.2), in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Theme.gradient)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal)
    }

    // MARK: - Map

    private var mapStops: [MapStop] {
        (currentDay?.allActivities ?? [])
            .enumerated()
            .compactMap { index, activity in
                guard let coords = activity.coordinates, coords.isValid else { return nil }
                return MapStop(
                    id: index,
                    activity: activity,
                    coordinate: CLLocationCoordinate2D(latitude: coords.lat, longitude: coords.lng)
                )
            }
    }

    @ViewBuilder
    private var dayMap: some View {
        let stops = mapStops
        if !stops.isEmpty {
            Map(position: $cameraPosition) {
                ForEach(stops) { stop in
                    Marker(
                        stop.activity.displayName,
                        systemImage: stop.activity.systemImageName,
                        coordinate: stop.coordinate
                    )
                    .tint(Theme.color(forActivityType: stop.activity.type))
                }
            }
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal)
        }
    }

    // MARK: - Day picker

    private var dayPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(days, id: \.day) { day in
                    Button {
                        Haptics.tap()
                        withAnimation(.snappy) { selectedDay = day.day }
                    } label: {
                        Text("Day \(day.day)")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background {
                                if selectedDay == day.day {
                                    Capsule().fill(Theme.gradient)
                                } else {
                                    Capsule().fill(Color(.secondarySystemGroupedBackground))
                                }
                            }
                            .foregroundStyle(selectedDay == day.day ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Timeline

    private func timeline(for day: DayPlan) -> some View {
        let activities = day.allActivities
        return VStack(spacing: 0) {
            ForEach(Array(activities.enumerated()), id: \.offset) { index, activity in
                TimelineActivityRow(
                    activity: activity,
                    isFirst: index == 0,
                    isLast: index == activities.count - 1
                )
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Footer sections

    @ViewBuilder
    private var tipsAndBudget: some View {
        if let tips = trip.itinerary.tips, !tips.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Tips", systemImage: "lightbulb.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.brandStart)
                ForEach(Array(tips.enumerated()), id: \.offset) { _, tip in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(Theme.brandStart.opacity(0.5))
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)
                        Text(tip)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .cardBackground()
            .padding(.horizontal)
        }

        if let budget = trip.itinerary.estimatedBudget, !budget.isEmpty {
            HStack {
                Label("Estimated budget", systemImage: "banknote")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(budget)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(16)
            .cardBackground()
            .padding(.horizontal)
        }

        Text("AI-generated itinerary — verify opening hours, prices, and addresses before visiting.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
    }

    @ViewBuilder
    private var trendingSection: some View {
        if let places = trip.trendingPlaces, !places.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Trending right now", systemImage: "flame.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(places.enumerated()), id: \.offset) { _, place in
                            TrendingPlaceCard(place: place)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    private func googleMapsRouteURL(for day: DayPlan) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")

        let stops = day.allActivities
            .compactMap { $0.address }
            .filter { !$0.isEmpty }
            .compactMap { $0.addingPercentEncoding(withAllowedCharacters: allowed) }

        guard stops.count >= 2 else { return nil }
        return URL(string: "https://www.google.com/maps/dir/" + stops.joined(separator: "/"))
    }
}

// MARK: - Timeline row

struct TimelineActivityRow: View {
    let activity: Activity
    let isFirst: Bool
    let isLast: Bool

    private var accent: Color { Theme.color(forActivityType: activity.type) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : Color(.separator))
                    .frame(width: 2, height: 12)
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.15))
                        .frame(width: 34, height: 34)
                    Image(systemName: activity.systemImageName)
                        .font(.caption)
                        .foregroundStyle(accent)
                }
                if !isLast {
                    Rectangle()
                        .fill(Color(.separator))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if let time = activity.time, !time.isEmpty {
                        Text(time)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(accent)
                    }
                    Spacer()
                    if let duration = activity.duration, !duration.isEmpty {
                        Text(duration)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(activity.displayName)
                    .font(.system(.headline, design: .rounded))
                if let description = activity.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let address = activity.address, !address.isEmpty {
                    Button {
                        openInAppleMaps(address: address)
                    } label: {
                        Label(address, systemImage: "mappin")
                            .font(.caption)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()
            .padding(.bottom, 10)
        }
    }

    private func openInAppleMaps(address: String) {
        var components = URLComponents(string: "https://maps.apple.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: address)]
        if let url = components.url {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Trending card

struct TrendingPlaceCard: View {
    let place: TrendingPlace

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: place.systemImageName)
                    .foregroundStyle(Theme.color(forActivityType: place.type))
                Spacer()
                if let views = place.views, views > 0 {
                    Label(Format.compactCount(views), systemImage: "eye")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(place.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2, reservesSpace: true)
            if let address = place.address, !address.isEmpty {
                Text(address)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(width: 170, alignment: .leading)
        .cardBackground()
    }
}

// MARK: - Share text

enum TripFormatter {
    static func shareText(for trip: SavedTrip) -> String {
        var lines: [String] = ["\(trip.destination) — \(trip.dayCount) day itinerary (made with Itinera)"]

        for day in trip.itinerary.itinerary {
            lines.append("")
            var header = "Day \(day.day)"
            if let theme = day.theme, !theme.isEmpty { header += ": \(theme)" }
            lines.append(header)

            for activity in day.allActivities {
                var line = "• "
                if let time = activity.time, !time.isEmpty { line += "\(time) — " }
                line += activity.displayName
                if let address = activity.address, !address.isEmpty { line += " (\(address))" }
                lines.append(line)
            }
        }

        if let tips = trip.itinerary.tips, !tips.isEmpty {
            lines.append("")
            lines.append("Tips:")
            lines.append(contentsOf: tips.map { "• \($0)" })
        }

        if let budget = trip.itinerary.estimatedBudget, !budget.isEmpty {
            lines.append("")
            lines.append("Estimated budget: \(budget)")
        }

        return lines.joined(separator: "\n")
    }
}

#Preview {
    NavigationStack {
        ItineraryView(
            trip: SavedTrip(
                id: UUID(),
                destination: "Lisbon, Portugal",
                startDate: .now.addingTimeInterval(86400 * 10),
                endDate: .now.addingTimeInterval(86400 * 13),
                budget: "Medium",
                createdAt: .now,
                itinerary: Itinerary(
                    itinerary: [
                        DayPlan(day: 1, theme: "Old Town & Views", activities: [
                            Activity(
                                time: "9:00 AM",
                                name: "São Jorge Castle",
                                type: "landmark",
                                duration: "2 hours",
                                description: "Panoramic views over Alfama.",
                                address: "R. de Santa Cruz do Castelo, Lisbon",
                                coordinates: Coordinates(lat: 38.7139, lng: -9.1335)
                            ),
                            Activity(
                                time: "12:30 PM",
                                name: "Time Out Market",
                                type: "food",
                                duration: "1.5 hours",
                                description: "Lisbon's best food hall.",
                                address: "Av. 24 de Julho 49, Lisbon",
                                coordinates: Coordinates(lat: 38.7067, lng: -9.1459)
                            ),
                        ]),
                        DayPlan(day: 2, theme: "Belém", activities: []),
                    ],
                    tips: ["Wear comfortable shoes — Lisbon is hilly."],
                    accommodationInfo: nil,
                    estimatedBudget: "$400–600 per person"
                ),
                trendingPlaces: [
                    TrendingPlace(
                        name: "Pastéis de Belém",
                        type: "food",
                        description: "The original custard tarts",
                        address: "R. de Belém 84, Lisbon",
                        views: 2_340_000,
                        engagement: 180_000,
                        coordinates: nil
                    ),
                ]
            ),
            allowSaving: true
        )
        .environmentObject(TripStore())
    }
}
