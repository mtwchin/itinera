import SwiftUI

struct SavedTripsView: View {
    @EnvironmentObject private var appState: AppState

    @State private var trips: [SavedItinerary] = []
    @State private var errorMessage: String?
    @State private var isLoading = false

    private var localOnlyPendingJobs: [PendingJobRecord] {
        let remoteIDs = Set(trips.map(\.jobId))
        return appState.pendingJobs.filter { !remoteIDs.contains($0.jobID) }
    }

    private var hasTrips: Bool {
        !trips.isEmpty || !localOnlyPendingJobs.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if !hasTrips && !isLoading {
                    ContentUnavailableView(
                        "No trips yet",
                        systemImage: "suitcase",
                        description: Text(
                            errorMessage
                                ?? appState.persistenceError
                                ?? "Generate your first itinerary from the New Trip tab."
                        )
                    )
                } else {
                    List {
                        if !localOnlyPendingJobs.isEmpty {
                            Section("Pending on this device") {
                                ForEach(localOnlyPendingJobs) { job in
                                    NavigationLink {
                                        GenerationView(jobID: job.jobID)
                                    } label: {
                                        LocalPendingTripRow(job: job)
                                    }
                                }
                            }
                        }

                        Section("Trips") {
                            ForEach(trips) { trip in
                                if let itinerary = trip.result {
                                    NavigationLink {
                                        ItineraryView(itinerary: itinerary)
                                            .navigationTitle(trip.title)
                                    } label: {
                                        TripRow(trip: trip)
                                    }
                                } else if trip.status == .pending || trip.status == .running {
                                    NavigationLink {
                                        GenerationView(jobID: trip.jobId)
                                    } label: {
                                        TripRow(trip: trip)
                                    }
                                } else {
                                    TripRow(trip: trip)
                                }
                            }
                        }
                    }
                    .refreshable { await load() }
                }
            }
            .navigationTitle("My Trips")
            .task {
                await appState.loadPendingJobs()
                await load()
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        await appState.resumePendingSubmissions()
        do {
            trips = try await appState.apiClient.savedItineraries()
            await appState.reconcilePending(with: trips)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct LocalPendingTripRow: View {
    let job: PendingJobRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(job.title ?? "Pending trip")
                .font(.headline)
            Label("Generating…", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.orange)
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
