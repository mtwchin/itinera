import SwiftUI

struct SavedTripsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.itineraTheme) private var theme

    var onPlanTrip: () -> Void = {}

    @State private var trips: [SavedItinerary] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var isShowingOfflineCopy = false
    @State private var searchText = ""
    @State private var renameTarget: SavedItinerary?
    @State private var renameText = ""
    @State private var archiveTarget: SavedItinerary?
    @State private var deleteTarget: SavedItinerary?
    @State private var mutatingTripIDs: Set<String> = []
    @State private var mutationError: String?

    private var localOnlyPendingJobs: [PendingJobRecord] {
        let remoteIDs = Set(trips.map(\.jobId))
        return appState.pendingJobs.filter {
            !remoteIDs.contains($0.jobID)
                && (searchText.isEmpty
                    || ($0.title ?? "Pending trip")
                        .localizedCaseInsensitiveContains(searchText))
        }
    }

    private var hasTrips: Bool {
        !trips.isEmpty || !localOnlyPendingJobs.isEmpty
    }

    private var libraryGroups: [(
        group: TripLibraryGroup,
        trips: [SavedItinerary]
    )] {
        TripLibraryOrganizer.groups(
            for: trips,
            searchText: searchText
        )
    }

    private var activeTrip: SavedItinerary? {
        trips.first {
            TripLibraryOrganizer.group(for: $0) == .active
                && $0.result != nil
        }
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

                        if let message = mutationError ?? statusMessage, hasTrips {
                            ItineraStatusBanner(message: message, kind: .warning)
                        }

                        if !hasTrips && !isLoading {
                            emptyState
                        } else {
                            if searchText.isEmpty, let activeTrip {
                                todayCard(for: activeTrip)
                            }

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

                            if !trips.isEmpty && libraryGroups.isEmpty {
                                ItineraSectionHeading(
                                    number: "NO MATCHES",
                                    title: "No trips found",
                                    message: "Try another destination, stop, or date."
                                )
                            }

                            ForEach(libraryGroups, id: \.group) { section in
                                ItineraSectionHeading(
                                    number: section.group.eyebrow,
                                    title: section.group.title,
                                    message: sectionMessage(for: section.group)
                                )

                                ForEach(section.trips) { trip in
                                    libraryRow(for: trip)
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        ArchivedTripsView()
                    } label: {
                        Label("Archived trips", systemImage: "archivebox")
                    }
                }
            }
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search trips and stops"
            )
            .task(id: appState.libraryRevision) {
                await appState.loadPendingJobs()
                await load()
            }
            .alert(
                "Rename trip",
                isPresented: Binding(
                    get: { renameTarget != nil },
                    set: { if !$0 { renameTarget = nil } }
                )
            ) {
                TextField("Trip name", text: $renameText)
                Button("Cancel", role: .cancel) {
                    renameTarget = nil
                }
                Button("Save") {
                    guard let trip = renameTarget else { return }
                    let title = renameText.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    renameTarget = nil
                    Task { await rename(trip, title: title) }
                }
                .disabled(
                    renameText.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                )
            } message: {
                Text("The new name will sync to your trip library.")
            }
            .confirmationDialog(
                "Archive trip?",
                isPresented: Binding(
                    get: { archiveTarget != nil },
                    set: { if !$0 { archiveTarget = nil } }
                ),
                titleVisibility: .visible,
                presenting: archiveTarget
            ) { trip in
                Button("Archive \(trip.displayTitle)") {
                    archiveTarget = nil
                    Task { await archive(trip) }
                }
                Button("Cancel", role: .cancel) {
                    archiveTarget = nil
                }
            } message: { _ in
                Text("This removes the trip from your active library without deleting its server record.")
            }
            .alert(
                "Delete trip permanently?",
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
    }

    private func beginRename(_ trip: SavedItinerary) {
        renameText = trip.displayTitle
        renameTarget = trip
    }

    private func libraryRow(for trip: SavedItinerary) -> some View {
        destination(for: trip) {
            ItineraSurface {
                TripRow(trip: trip)
            }
        }
        .contextMenu {
            Button {
                beginRename(trip)
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                Task { await duplicate(trip) }
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }

            Button {
                archiveTarget = trip
            } label: {
                Label("Archive", systemImage: "archivebox")
            }

            Divider()

            Button(role: .destructive) {
                deleteTarget = trip
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityAction(named: "Rename trip") {
            beginRename(trip)
        }
        .accessibilityAction(named: "Archive trip") {
            archiveTarget = trip
        }
        .accessibilityAction(named: "Delete trip") {
            deleteTarget = trip
        }
        .opacity(mutatingTripIDs.contains(trip.jobId) ? 0.55 : 1)
        .allowsHitTesting(!mutatingTripIDs.contains(trip.jobId))
    }

    private func rename(_ trip: SavedItinerary, title: String) async {
        guard !title.isEmpty, title.count <= 160 else {
            mutationError = "Trip names must contain 1 to 160 characters."
            return
        }
        mutatingTripIDs.insert(trip.jobId)
        defer { mutatingTripIDs.remove(trip.jobId) }
        do {
            let response = try await appState.renameTrip(
                jobID: trip.jobId,
                title: title
            )
            if let index = trips.firstIndex(where: { $0.jobId == trip.jobId }) {
                trips[index].title = response.title ?? title
            }
            mutationError = nil
        } catch is CancellationError {
            return
        } catch {
            mutationError = error.localizedDescription
        }
    }

    private func archive(_ trip: SavedItinerary) async {
        mutatingTripIDs.insert(trip.jobId)
        defer { mutatingTripIDs.remove(trip.jobId) }
        do {
            try await appState.archiveTrip(jobID: trip.jobId)
            trips.removeAll { $0.jobId == trip.jobId }
            mutationError = nil
        } catch is CancellationError {
            return
        } catch {
            mutationError = error.localizedDescription
        }
    }

    private func duplicate(_ trip: SavedItinerary) async {
        mutatingTripIDs.insert(trip.jobId)
        defer { mutatingTripIDs.remove(trip.jobId) }
        do {
            let copy = try await appState.duplicateTrip(jobID: trip.jobId)
            trips.insert(copy, at: 0)
            mutationError = nil
        } catch is CancellationError {
            return
        } catch {
            mutationError = error.localizedDescription
        }
    }

    private func delete(_ trip: SavedItinerary) async {
        mutatingTripIDs.insert(trip.jobId)
        defer { mutatingTripIDs.remove(trip.jobId) }
        do {
            try await appState.deleteTrip(jobID: trip.jobId)
            trips.removeAll { $0.jobId == trip.jobId }
            mutationError = nil
        } catch is CancellationError {
            return
        } catch {
            mutationError = error.localizedDescription
        }
    }

    private var statusMessage: String? {
        if isShowingOfflineCopy {
            if let refreshedAt = appState.tripCacheRefreshedAt {
                return "You're viewing the offline copy saved \(refreshedAt.formatted(.relative(presentation: .named))). Pull to refresh when you're connected."
            }
            return "You're viewing an offline copy. Pull to refresh when you're connected."
        }
        return errorMessage ?? appState.offlineCacheError ?? appState.persistenceError
    }

    private func sectionMessage(for group: TripLibraryGroup) -> String? {
        switch group {
        case .active:
            return "Open Today for your current stop, directions, and progress."
        case .upcoming:
            return "Routes ready before you leave."
        case .generating:
            return "These routes are still being prepared."
        case .saved:
            return "Guides without fixed travel dates."
        case .past:
            return "Previous routes, kept for reference."
        case .needsAttention:
            return "These trips could not be completed."
        }
    }

    private func todayCard(for trip: SavedItinerary) -> some View {
        NavigationLink {
            TodayTripView(
                trip: trip,
                progressStore: appState.tripProgressStore
            )
        } label: {
            ItineraSurface {
                HStack(spacing: 15) {
                    Image(systemName: "location.fill.viewfinder")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(theme.accentContrast)
                        .frame(width: 52, height: 52)
                        .background(theme.accent, in: Circle())

                    VStack(alignment: .leading, spacing: 5) {
                        Text("TODAY")
                            .font(.caption.weight(.bold))
                            .tracking(1.5)
                            .foregroundStyle(theme.highlightStrong)
                        Text("Continue \(trip.displayTitle)")
                            .font(.system(.title3, design: .serif, weight: .bold))
                            .foregroundStyle(theme.primaryText)
                        Text("Next stop, directions, and day progress")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                    }

                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens today's trip guide")
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
                ItineraryView(
                    itinerary: itinerary,
                    tripID: trip.jobId,
                    tripTitle: trip.displayTitle,
                    tripStartDate: trip.arrivalDate,
                    tripEndDate: trip.departureDate,
                    tripVersion: trip.version
                )
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
        await appState.loadCachedTrips()
        if trips.isEmpty, !appState.cachedTrips.isEmpty {
            trips = appState.cachedTrips
            isShowingOfflineCopy = true
        }
        await appState.resumePendingSubmissions()
        do {
            trips = try await appState.refreshTripLibrary()
            await appState.reconcilePending(with: trips)
            errorMessage = nil
            isShowingOfflineCopy = false
        } catch is CancellationError {
            return
        } catch {
            if !appState.cachedTrips.isEmpty {
                trips = appState.cachedTrips
                isShowingOfflineCopy = true
                errorMessage = nil
            } else {
                errorMessage = error.localizedDescription
                isShowingOfflineCopy = false
            }
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
