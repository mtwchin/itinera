import SwiftUI

struct TripsView: View {
    @EnvironmentObject private var tripStore: TripStore

    @State private var renamingTrip: SavedTrip?
    @State private var newName = ""

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
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(tripStore.trips) { trip in
                                NavigationLink(value: trip) {
                                    TripCard(trip: trip)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    ShareLink(item: TripFormatter.shareText(for: trip)) {
                                        Label("Share", systemImage: "square.and.arrow.up")
                                    }
                                    Button {
                                        newName = trip.destination
                                        renamingTrip = trip
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        tripStore.delete(id: trip.id)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                    .background(Color(.systemGroupedBackground))
                }
            }
            .navigationTitle("My Trips")
            .navigationDestination(for: SavedTrip.self) { trip in
                ItineraryView(trip: trip)
            }
            .alert("Rename trip", isPresented: .init(
                get: { renamingTrip != nil },
                set: { if !$0 { renamingTrip = nil } }
            )) {
                TextField("Trip name", text: $newName)
                Button("Save") {
                    if let trip = renamingTrip {
                        tripStore.rename(id: trip.id, to: newName)
                    }
                    renamingTrip = nil
                }
                Button("Cancel", role: .cancel) { renamingTrip = nil }
            }
        }
    }
}

struct TripCard: View {
    let trip: SavedTrip

    private var countdown: String? {
        Format.countdown(to: trip.startDate, end: trip.endDate)
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.gradient)
                    .frame(width: 52, height: 52)
                Text(String(trip.destination.prefix(1)).uppercased())
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(trip.destination)
                    .font(.system(.headline, design: .rounded))
                    .lineLimit(1)
                Text("\(trip.dayCount) day\(trip.dayCount == 1 ? "" : "s") · \(Format.dateRange(trip.startDate, trip.endDate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if let countdown {
                    Text(countdown)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.brandStart.opacity(0.12), in: Capsule())
                        .foregroundStyle(Theme.brandStart)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .cardBackground()
    }
}

#Preview {
    TripsView()
        .environmentObject(TripStore())
}
