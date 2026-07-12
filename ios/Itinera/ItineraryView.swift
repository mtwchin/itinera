import SwiftUI
import MapKit

struct ItineraryView: View {
    let itinerary: Itinerary

    @State private var selectedDay = 1

    private var day: ItineraryDay? {
        itinerary.itinerary.first { $0.day == selectedDay }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Day", selection: $selectedDay) {
                ForEach(itinerary.itinerary) { day in
                    Text("Day \(day.day)").tag(day.day)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            if let day {
                DayMapView(activities: day.activities)
                    .frame(height: 240)

                List {
                    Section(day.theme) {
                        ForEach(day.activities) { activity in
                            ActivityRow(activity: activity)
                        }
                    }
                    if selectedDay == itinerary.itinerary.last?.day {
                        Section("Tips") {
                            ForEach(itinerary.tips, id: \.self) { tip in
                                Label(tip, systemImage: "lightbulb")
                                    .font(.footnote)
                            }
                            Label(itinerary.estimatedBudget, systemImage: "dollarsign.circle")
                                .font(.footnote)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }
}

struct DayMapView: View {
    let activities: [Activity]

    var body: some View {
        Map {
            ForEach(Array(activities.enumerated()), id: \.element.id) { index, activity in
                Marker(
                    "\(index + 1). \(activity.name)",
                    systemImage: icon(for: activity.type),
                    coordinate: CLLocationCoordinate2D(
                        latitude: activity.coordinates.lat,
                        longitude: activity.coordinates.lng
                    )
                )
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }

    private func icon(for type: String) -> String {
        switch type {
        case "food": return "fork.knife"
        case "culture": return "building.columns"
        case "nature": return "leaf"
        case "shopping": return "bag"
        default: return "mappin"
        }
    }
}

struct ActivityRow: View {
    let activity: Activity

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(activity.time)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(activity.duration)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(activity.name)
                .font(.headline)
            Text(activity.description)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(activity.address)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
