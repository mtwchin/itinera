import SwiftUI

struct ArchivedTripsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.itineraTheme) private var theme

    @State private var trips: [SavedItinerary] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var workingIDs: Set<String> = []
    @State private var deleteTarget: SavedItinerary?

    var body: some View {
        ZStack {
            ItineraBackground()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ItineraBrandHeader(
                        eyebrow: "Stored away",
                        title: "Archived trips",
                        message: "Restore a field guide to your library or permanently remove it."
                    )

                    if let errorMessage {
                        ItineraStatusBanner(message: errorMessage, kind: .warning)
                    }

                    if trips.isEmpty && !isLoading {
                        ItineraSurface {
                            ContentUnavailableView(
                                "No archived trips",
                                systemImage: "archivebox",
                                description: Text("Trips you archive will appear here.")
                            )
                        }
                    }

                    ForEach(trips) { trip in
                        ItineraSurface {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(trip.displayTitle)
                                    .font(.system(.title3, design: .serif, weight: .bold))
                                    .foregroundStyle(theme.primaryText)
                                if let arrival = trip.arrivalDate, let departure = trip.departureDate {
                                    Label("\(arrival) → \(departure)", systemImage: "calendar")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(theme.secondaryText)
                                }

                                HStack(spacing: 10) {
                                    Button {
                                        Task { await restore(trip) }
                                    } label: {
                                        Label("Restore", systemImage: "arrow.uturn.backward")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(theme.accent)

                                    Button(role: .destructive) {
                                        deleteTarget = trip
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .disabled(workingIDs.contains(trip.jobId))
                            }
                        }
                    }
                }
                .padding(18)
            }

            if isLoading {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .navigationTitle("Archive")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .alert(
            "Delete archived trip permanently?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            presenting: deleteTarget
        ) { trip in
            Button("Delete", role: .destructive) {
                deleteTarget = nil
                Task { await delete(trip) }
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: { trip in
            Text("\(trip.displayTitle) and its synced trip data will be permanently removed. This cannot be undone.")
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            trips = try await appState.archivedTrips()
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restore(_ trip: SavedItinerary) async {
        workingIDs.insert(trip.jobId)
        defer { workingIDs.remove(trip.jobId) }
        do {
            try await appState.restoreTrip(trip)
            trips.removeAll { $0.jobId == trip.jobId }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ trip: SavedItinerary) async {
        workingIDs.insert(trip.jobId)
        defer { workingIDs.remove(trip.jobId) }
        do {
            try await appState.deleteTrip(jobID: trip.jobId)
            trips.removeAll { $0.jobId == trip.jobId }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
