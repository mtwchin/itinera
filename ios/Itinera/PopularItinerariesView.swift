import SwiftUI

struct PopularItinerariesView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.itineraTheme) private var theme

    @State private var itineraries: [PopularItinerarySummary] = []
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var isLoading = false

    private var filteredItineraries: [PopularItinerarySummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return itineraries }
        return itineraries.filter { itinerary in
            [itinerary.title, itinerary.summary, itinerary.city, itinerary.country]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var groups: [PopularItineraryGroup] {
        Dictionary(grouping: filteredItineraries, by: \.locationKey)
            .map { locationKey, items in
                PopularItineraryGroup(
                    id: locationKey,
                    location: items.first?.locationName ?? locationKey,
                    // The API already ranks each location by saves with a
                    // deterministic editorial cold-start tie-breaker.
                    itineraries: items
                )
            }
            .sorted {
                $0.location.localizedCaseInsensitiveCompare($1.location) == .orderedAscending
            }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ItineraBackground()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ItineraBrandHeader(
                            eyebrow: "Community field guides",
                            title: "Follow a route travelers love.",
                            message: "Browse the most-saved itineraries by location, then add one to your trips."
                        )

                        if let errorMessage, !itineraries.isEmpty {
                            ItineraStatusBanner(message: errorMessage, kind: .warning)
                        }

                        if !isLoading && itineraries.isEmpty {
                            emptyState
                        } else if !isLoading && groups.isEmpty {
                            noSearchResults
                        } else {
                            ForEach(groups) { group in
                                VStack(alignment: .leading, spacing: 12) {
                                    ItineraSectionHeading(
                                        number: "POPULAR",
                                        title: group.location,
                                        message: "Ranked by saves from Itinera travelers."
                                    )

                                    ForEach(group.itineraries) { itinerary in
                                        NavigationLink {
                                            PopularItineraryDetailView(
                                                summary: itinerary,
                                                onSaved: markSaved
                                            )
                                        } label: {
                                            ItineraSurface {
                                                PopularItineraryCard(itinerary: itinerary)
                                            }
                                        }
                                        .buttonStyle(.plain)
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

                if isLoading && itineraries.isEmpty {
                    ProgressView()
                        .controlSize(.large)
                        .tint(theme.route)
                        .accessibilityLabel("Loading popular itineraries")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search locations or routes"
            )
            .task { await load() }
        }
    }

    private var emptyState: some View {
        ItineraSurface {
            VStack(spacing: 16) {
                Image(systemName: errorMessage == nil ? "globe.americas.fill" : "wifi.exclamationmark")
                    .font(.system(size: 38))
                    .foregroundStyle(theme.route)

                Text(errorMessage == nil ? "Popular routes are on their way" : "Popular routes couldn't be loaded")
                    .font(.system(.title3, design: .serif, weight: .bold))
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.center)

                Text(errorMessage ?? "Check back soon for traveler favorites from each destination.")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)

                if errorMessage != nil {
                    Button("Try again") {
                        Task { await load() }
                    }
                    .buttonStyle(ItineraPrimaryButtonStyle())
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var noSearchResults: some View {
        ItineraSurface {
            ContentUnavailableView.search(text: searchText)
                .foregroundStyle(theme.primaryText)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            itineraries = try await appState.apiClient.popularItineraries()
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func markSaved(_ itineraryID: String, created: Bool) {
        guard let index = itineraries.firstIndex(where: { $0.id == itineraryID }),
              !itineraries[index].isSaved else { return }
        itineraries[index].isSaved = true
        if created {
            itineraries[index].saveCount += 1
        }
    }
}

private struct PopularItineraryGroup: Identifiable {
    let id: String
    let location: String
    let itineraries: [PopularItinerarySummary]
}

private struct PopularItineraryCard: View {
    @Environment(\.itineraTheme) private var theme

    let itinerary: PopularItinerarySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.title2)
                    .foregroundStyle(theme.route)
                    .frame(width: 42, height: 42)
                    .background(theme.route.opacity(0.11), in: Circle())

                VStack(alignment: .leading, spacing: 5) {
                    Text(itinerary.title)
                        .font(.system(.title3, design: .serif, weight: .bold))
                        .foregroundStyle(theme.primaryText)
                        .multilineTextAlignment(.leading)
                    Text(itinerary.summary)
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                }

                Spacer(minLength: 0)
                Image(systemName: itinerary.isSaved ? "bookmark.fill" : "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(itinerary.isSaved ? theme.highlightStrong : theme.secondaryText)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 8) {
                ItineraPill(text: daysLabel, systemImage: "calendar")
                ItineraPill(text: savesLabel, systemImage: "bookmark")
                if itinerary.isSaved {
                    ItineraPill(text: "Saved", systemImage: "checkmark", highlighted: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(itinerary.title), \(daysLabel), \(savesLabel)\(itinerary.isSaved ? ", saved" : "")"
        )
        .accessibilityHint("Shows itinerary details")
    }

    private var savesLabel: String {
        "\(itinerary.saveCount) \(itinerary.saveCount == 1 ? "save" : "saves")"
    }

    private var daysLabel: String {
        "\(itinerary.durationDays) \(itinerary.durationDays == 1 ? "day" : "days")"
    }
}

private struct PopularItineraryDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.itineraTheme) private var theme

    let summary: PopularItinerarySummary
    let onSaved: (String, Bool) -> Void

    @State private var detail: PopularItineraryDetail?
    @State private var isSaved: Bool
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        summary: PopularItinerarySummary,
        onSaved: @escaping (String, Bool) -> Void
    ) {
        self.summary = summary
        self.onSaved = onSaved
        _isSaved = State(initialValue: summary.isSaved)
    }

    var body: some View {
        ZStack {
            ItineraBackground()

            if let detail {
                ItineraryView(itinerary: detail.result)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        saveBar
                    }
            } else if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(theme.route)
                    .accessibilityLabel("Loading itinerary")
            } else {
                loadFailure
            }
        }
        .navigationTitle(summary.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var saveBar: some View {
        VStack(spacing: 8) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                Task { await save() }
            } label: {
                HStack(spacing: 9) {
                    if isSaving {
                        ProgressView()
                            .tint(theme.accentContrast)
                    } else {
                        Image(systemName: isSaved ? "checkmark.circle.fill" : "bookmark.fill")
                    }
                    Text(isSaved ? "Saved to Trips" : "Add to Trips")
                }
            }
            .buttonStyle(ItineraPrimaryButtonStyle())
            .disabled(isSaved || isSaving)
            .opacity(isSaved ? 0.72 : 1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var loadFailure: some View {
        VStack(spacing: 18) {
            ItineraStatusBanner(
                message: errorMessage ?? "This itinerary couldn't be loaded.",
                kind: .error
            )
            Button("Try again") {
                Task { await load() }
            }
            .buttonStyle(ItineraPrimaryButtonStyle())
        }
        .padding(18)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await appState.apiClient.popularItinerary(summary.id)
            detail = loaded
            isSaved = loaded.isSaved
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        guard !isSaving, !isSaved else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let response = try await appState.apiClient.savePopularItinerary(summary.id)
            isSaved = true
            errorMessage = nil
            onSaved(summary.id, response.created)
            appState.markLibraryChanged()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
