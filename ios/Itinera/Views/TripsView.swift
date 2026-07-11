import SwiftUI

struct TripsView: View {
    @EnvironmentObject private var tripStore: TripStore

    var body: some View {
        NavigationStack {
            Group {
                if tripStore.trips.isEmpty {
                    ContentUnavailableView(
                        "No trips yet",
                        systemImage: "suitcase",
                        description: Text("Generate an itinerary in the Plan tab and save it — saved trips work offline.")
                    )
                } else {
                    List {
                        ForEach(tripStore.trips) { trip in
                            NavigationLink(value: trip) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(trip.destination)
                                        .font(.headline)
                                    Text("\(trip.dayCount) day\(trip.dayCount == 1 ? "" : "s") · \(trip.startDate.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .onDelete { offsets in
                            tripStore.delete(at: offsets)
                        }
                    }
                }
            }
            .navigationTitle("My Trips")
            .navigationDestination(for: SavedTrip.self) { trip in
                ItineraryView(trip: trip)
            }
        }
    }
}

#Preview {
    TripsView()
        .environmentObject(TripStore())
}
