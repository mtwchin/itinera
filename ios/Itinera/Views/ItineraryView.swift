import SwiftUI
import MapKit
import UIKit

private struct MapStop: Identifiable {
    let id: Int
    let activity: Activity
    let coordinate: CLLocationCoordinate2D
}

struct ItineraryView: View {
    let trip: SavedTrip
    var allowSaving: Bool = false

    @EnvironmentObject private var tripStore: TripStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDay: Int = 1
    @State private var cameraPosition: MapCameraPosition = .automatic

    private var days: [DayPlan] { trip.itinerary.itinerary }

    private var currentDay: DayPlan? {
        days.first { $0.day == selectedDay } ?? days.first
    }

    private var isSaved: Bool { tripStore.contains(id: trip.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                dayMap

                dayPicker

                if let day = currentDay {
                    if let theme = day.theme, !theme.isEmpty {
                        Text(theme)
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal)
                    }

                    VStack(spacing: 12) {
                        ForEach(Array(day.allActivities.enumerated()), id: \.offset) { _, activity in
                            ActivityCard(activity: activity)
                        }
                    }
                    .padding(.horizontal)

                    if let routeURL = googleMapsRouteURL(for: day) {
                        Link(destination: routeURL) {
                            Label("Open Day \(day.day) route in Maps", systemImage: "map")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.horizontal)
                    }
                }

                tipsAndBudget
            }
            .padding(.vertical)
        }
        .navigationTitle(trip.destination)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: TripFormatter.shareText(for: trip)) {
                    Image(systemName: "square.and.arrow.up")
                }
                if allowSaving {
                    Button(isSaved ? "Saved" : "Save") {
                        if !isSaved { tripStore.add(trip) }
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
        .onAppear {
            selectedDay = days.first?.day ?? 1
        }
        .onChange(of: selectedDay) {
            cameraPosition = .automatic
        }
    }

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
                }
            }
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
        }
    }

    private var dayPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(days, id: \.day) { day in
                    Button {
                        selectedDay = day.day
                    } label: {
                        Text("Day \(day.day)")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                selectedDay == day.day ? Color.accentColor : Color(.secondarySystemBackground),
                                in: Capsule()
                            )
                            .foregroundStyle(selectedDay == day.day ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var tipsAndBudget: some View {
        if let tips = trip.itinerary.tips, !tips.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tips")
                    .font(.headline)
                ForEach(Array(tips.enumerated()), id: \.offset) { _, tip in
                    Label(tip, systemImage: "lightbulb")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
        }

        if let budget = trip.itinerary.estimatedBudget, !budget.isEmpty {
            LabeledContent("Estimated budget", value: budget)
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)
        }

        Text("AI-generated itinerary — verify opening hours, prices, and addresses before visiting.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
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

struct ActivityCard: View {
    let activity: Activity

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 6) {
                Image(systemName: activity.systemImageName)
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                if let time = activity.time {
                    Text(time)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .frame(width: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(activity.displayName)
                    .font(.headline)
                if let duration = activity.duration, !duration.isEmpty {
                    Text(duration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                    .foregroundStyle(Color.accentColor)
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func openInAppleMaps(address: String) {
        var components = URLComponents(string: "https://maps.apple.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: address)]
        if let url = components.url {
            UIApplication.shared.open(url)
        }
    }
}

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
                startDate: .now,
                endDate: .now.addingTimeInterval(86400 * 3),
                budget: "Medium",
                createdAt: .now,
                itinerary: Itinerary(
                    itinerary: [
                        DayPlan(day: 1, theme: "Old Town", activities: [
                            Activity(
                                time: "9:00 AM",
                                name: "São Jorge Castle",
                                type: "landmark",
                                duration: "2 hours",
                                description: "Panoramic views over Alfama.",
                                address: "R. de Santa Cruz do Castelo, Lisbon",
                                coordinates: Coordinates(lat: 38.7139, lng: -9.1335)
                            ),
                        ]),
                    ],
                    tips: ["Wear comfortable shoes — Lisbon is hilly."],
                    accommodationInfo: nil,
                    estimatedBudget: "$400–600 per person"
                )
            ),
            allowSaving: true
        )
        .environmentObject(TripStore())
    }
}
