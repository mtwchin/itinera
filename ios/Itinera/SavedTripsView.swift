import SwiftUI

struct SavedTripsView: View {
    @State private var trips: [SavedItinerary] = []
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            Group {
                if trips.isEmpty && !isLoading {
                    ContentUnavailableView(
                        "No trips yet",
                        systemImage: "suitcase",
                        description: Text(errorMessage ?? "Generate your first itinerary from the New Trip tab.")
                    )
                } else {
                    List(trips) { trip in
                        if let itinerary = trip.result {
                            NavigationLink {
                                ItineraryView(itinerary: itinerary)
                                    .navigationTitle(trip.title)
                            } label: {
                                TripRow(trip: trip)
                            }
                        } else {
                            TripRow(trip: trip)
                        }
                    }
                    .refreshable { await load() }
                }
            }
            .navigationTitle("My Trips")
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            trips = try await APIClient.shared.savedItineraries()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct TripRow: View {
    let trip: SavedItinerary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(trip.title.isEmpty ? "Trip" : trip.title)
                .font(.headline)
            if let arrival = trip.arrivalDate, let departure = trip.departureDate {
                Text("\(arrival) → \(departure)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            switch trip.status {
            case .failed:
                Label(trip.error ?? "Failed", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.red)
            case .pending, .running:
                Label("Generating…", systemImage: "hourglass")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            case .succeeded:
                EmptyView()
            }
        }
    }
}
