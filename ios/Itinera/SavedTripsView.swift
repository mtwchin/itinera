import SwiftUI

struct SavedTripsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.itineraTheme) private var theme

    var onPlanTrip: () -> Void = {}

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
            ZStack {
                ItineraBackground()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ItineraBrandHeader(
                            eyebrow: "Your field guides",
                            title: "Every route, ready when you are.",
                            message: "Return to a trip, follow one that's still generating, or start somewhere new."
                        )

                        if let message = errorMessage ?? appState.persistenceError, hasTrips {
                            ItineraStatusBanner(message: message, kind: .warning)
                        }

                        if !hasTrips && !isLoading {
                            emptyState
                        } else {
                            if !localOnlyPendingJobs.isEmpty {
                                ItineraSectionHeading(
                                    number: "IN PROGRESS",
                                    title: "Routes being prepared",
                                    message: "These jobs are safely stored on this iPhone."
                                )

                                ForEach(localOnlyPendingJobs) { job in
                                    NavigationLink {
                                        GenerationView(jobID: job.jobID)
                                    } label: {
                                        ItineraSurface {
                                            LocalPendingTripRow(job: job)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            if !trips.isEmpty {
                                ItineraSectionHeading(
                                    number: "LIBRARY",
                                    title: "Saved trips",
                                    message: "Your completed and active travel plans."
                                )

                                ForEach(trips) { trip in
                                    destination(for: trip) {
                                        ItineraSurface {
                                            TripRow(trip: trip)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 36)
                }
                .refreshable { await load() }

                if isLoading && !hasTrips {
                    ProgressView()
                        .controlSize(.large)
                        .tint(theme.route)
                        .accessibilityLabel("Loading trips")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .task(id: appState.libraryRevision) {
                await appState.loadPendingJobs()
                await load()
            }
        }
    }

    private var emptyState: some View {
        ItineraSurface {
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(theme.route.opacity(0.12))
                        .frame(width: 82, height: 82)
                    Image(systemName: "map.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(theme.route)
                }

                VStack(spacing: 7) {
                    Text("Your atlas is still empty")
                        .font(.system(.title2, design: .serif, weight: .bold))
                        .foregroundStyle(theme.primaryText)
                    Text(errorMessage ?? appState.persistenceError ?? "Start with a city and we'll turn it into a day-by-day route.")
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.center)
                }

                Button(action: onPlanTrip) {
                    Label("Plan your first trip", systemImage: "plus")
                }
                .buttonStyle(ItineraPrimaryButtonStyle())
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func destination<Label: View>(
        for trip: SavedItinerary,
        @ViewBuilder label: () -> Label
    ) -> some View {
        if let itinerary = trip.result {
            NavigationLink {
                ItineraryView(itinerary: itinerary)
                    .navigationTitle(trip.displayTitle)
            } label: {
                label()
            }
            .buttonStyle(.plain)
        } else if trip.status == .pending || trip.status == .running {
            NavigationLink {
                GenerationView(jobID: trip.jobId)
            } label: {
                label()
            }
            .buttonStyle(.plain)
        } else {
            label()
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
    @Environment(\.itineraTheme) private var theme

    let job: PendingJobRecord

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.title2)
                .foregroundStyle(theme.route)
                .frame(width: 40, height: 40)
                .background(theme.route.opacity(0.1), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text(job.title ?? "Pending trip")
                    .font(.system(.headline, design: .serif, weight: .bold))
                    .foregroundStyle(theme.primaryText)
                Label("Generating the route", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(theme.warning)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(theme.secondaryText)
        }
        .frame(minHeight: 58)
    }
}

struct TripRow: View {
    @Environment(\.itineraTheme) private var theme

    let trip: SavedItinerary

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 4) {
                Image(systemName: statusIcon)
                    .font(.title3)
                    .foregroundStyle(statusColor)
                Rectangle()
                    .fill(statusColor.opacity(0.35))
                    .frame(width: 2, height: 35)
            }
            .frame(width: 28)

            VStack(alignment: .leading, spacing: 8) {
                Text(trip.displayTitle.isEmpty ? "Untitled trip" : trip.displayTitle)
                    .font(.system(.title3, design: .serif, weight: .bold))
                    .foregroundStyle(theme.primaryText)

                if let arrival = trip.arrivalDate, let departure = trip.departureDate {
                    Label("\(arrival)  →  \(departure)", systemImage: "calendar")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                }

                HStack(spacing: 8) {
                    ItineraPill(text: statusText, systemImage: statusIcon, highlighted: trip.status == .succeeded)
                    if trip.sourcePublicItineraryId != nil {
                        ItineraPill(text: "Popular pick", systemImage: "flame.fill")
                    }
                    if let days = trip.result?.itinerary.count {
                        ItineraPill(
                            text: "\(days) \(days == 1 ? "day" : "days")",
                            systemImage: "map"
                        )
                    }
                }

                if trip.status == .failed {
                    Text(trip.error ?? "This trip could not be generated.")
                        .font(.caption)
                        .foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
            if trip.result != nil || trip.status == .pending || trip.status == .running {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.top, 5)
            }
        }
        .frame(minHeight: 82)
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch trip.status {
        case .failed: return "Needs attention"
        case .pending, .running: return "Generating"
        case .succeeded: return "Ready"
        }
    }

    private var statusIcon: String {
        switch trip.status {
        case .failed: return "exclamationmark.triangle.fill"
        case .pending, .running: return "hourglass"
        case .succeeded: return "checkmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch trip.status {
        case .failed: return theme.danger
        case .pending, .running: return theme.warning
        case .succeeded: return theme.success
        }
    }
}
