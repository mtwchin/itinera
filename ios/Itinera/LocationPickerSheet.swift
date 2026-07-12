import CoreLocation
import MapKit
import SwiftUI

enum LocationPickerPurpose: String, Identifiable, Sendable {
    case destination
    case homeBase

    var id: String { rawValue }

    var title: String {
        switch self {
        case .destination: "Choose a destination"
        case .homeBase: "Choose your home base"
        }
    }

    var prompt: String {
        switch self {
        case .destination: "City or region"
        case .homeBase: "Hotel, neighborhood, or address"
        }
    }
}

enum LocationSearchStatus: Equatable, Sendable {
    case idle
    case searching(query: String)

    var isSearching: Bool {
        if case .searching = self { return true }
        return false
    }

    mutating func begin(query: String) {
        self = .searching(query: query)
    }

    mutating func supersede() {
        self = .idle
    }

    mutating func finish(query: String) {
        guard self == .searching(query: query) else { return }
        self = .idle
    }
}

enum LocationReverseGeocodeStatus: Equatable, Sendable {
    case idle
    case resolving(LocationCoordinate)

    var isResolving: Bool {
        if case .resolving = self { return true }
        return false
    }

    mutating func begin(coordinate: LocationCoordinate) {
        self = .resolving(coordinate)
    }

    mutating func supersede() {
        self = .idle
    }

    mutating func finish(coordinate: LocationCoordinate) {
        guard self == .resolving(coordinate) else { return }
        self = .idle
    }
}

@MainActor
struct LocationPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.itineraTheme) private var theme

    let purpose: LocationPickerPurpose
    let searchBias: SelectedLocation?
    let onConfirm: (SelectedLocation) -> Void

    @State private var query: String
    @State private var results: [SelectedLocation] = []
    @State private var candidate: SelectedLocation?
    @State private var cameraPosition: MapCameraPosition
    @State private var searchStatus = LocationSearchStatus.idle
    @State private var reverseGeocodeStatus = LocationReverseGeocodeStatus.idle
    @State private var message: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var geocodeTask: Task<Void, Never>?

    init(
        purpose: LocationPickerPurpose,
        initialQuery: String,
        currentSelection: SelectedLocation?,
        searchBias: SelectedLocation? = nil,
        onConfirm: @escaping (SelectedLocation) -> Void
    ) {
        self.purpose = purpose
        self.searchBias = searchBias
        self.onConfirm = onConfirm
        _query = State(initialValue: initialQuery)
        _candidate = State(initialValue: currentSelection)

        if let focus = currentSelection ?? searchBias {
            _cameraPosition = State(
                initialValue: .region(
                    MKCoordinateRegion(
                        center: focus.coordinate.clCoordinate,
                        latitudinalMeters: purpose == .destination ? 180_000 : 25_000,
                        longitudinalMeters: purpose == .destination ? 180_000 : 25_000
                    )
                )
            )
        } else {
            _cameraPosition = State(initialValue: .automatic)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar

                MapReader { proxy in
                    Map(position: $cameraPosition) {
                        ForEach(results, id: \.self) { result in
                            Marker(result.name, coordinate: result.coordinate.clCoordinate)
                                .tint(candidate == result ? theme.highlight : theme.route)
                        }

                        if let candidate, !results.contains(candidate) {
                            Marker(candidate.name, coordinate: candidate.coordinate.clCoordinate)
                                .tint(theme.highlight)
                        }
                    }
                    .mapStyle(.standard(elevation: .realistic))
                    .overlay(alignment: .top) {
                        if reverseGeocodeStatus.isResolving {
                            Label("Checking that location…", systemImage: "mappin.and.ellipse")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(.regularMaterial, in: Capsule())
                                .padding(.top, 10)
                        }
                    }
                    .simultaneousGesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                guard let coordinate = proxy.convert(value.location, from: .local) else {
                                    return
                                }
                                reverseGeocode(coordinate)
                            }
                    )
                    .accessibilityLabel("Location map")
                    .accessibilityHint("Tap the map to check a location, then confirm it below.")
                }
                .frame(minHeight: 260)

                selectionPanel
            }
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle(purpose.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onDisappear {
                searchTask?.cancel()
                geocodeTask?.cancel()
                searchStatus.supersede()
                reverseGeocodeStatus.supersede()
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            TextField(purpose.prompt, text: $query)
                .textInputAutocapitalization(.words)
                .submitLabel(.search)
                .onSubmit(startSearch)
                .itineraField()
                .onChange(of: query) { _, newValue in
                    if let candidate, newValue != inputLabel(for: candidate) {
                        self.candidate = nil
                    }
                    searchTask?.cancel()
                    geocodeTask?.cancel()
                    searchStatus.supersede()
                    reverseGeocodeStatus.supersede()
                    results = []
                    message = nil
                }

            Button(action: startSearch) {
                if searchStatus.isSearching {
                    ProgressView()
                        .tint(theme.accentContrast)
                } else {
                    Image(systemName: "magnifyingglass")
                }
            }
            .font(.headline)
            .foregroundStyle(theme.accentContrast)
            .frame(width: 50, height: 50)
            .background(theme.accent, in: RoundedRectangle(cornerRadius: 14))
            .buttonStyle(.plain)
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searchStatus.isSearching)
            .accessibilityLabel("Search map")
        }
        .padding(16)
    }

    private var selectionPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let message {
                    ItineraStatusBanner(message: message, kind: .error)
                }

                if !results.isEmpty {
                    Text("SEARCH RESULTS")
                        .font(.caption2.weight(.bold))
                        .tracking(1.4)
                        .foregroundStyle(theme.secondaryText)

                    ForEach(results, id: \.self) { result in
                        Button {
                            chooseSearchResult(result)
                        } label: {
                            resultRow(result)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let candidate {
                    Divider().overlay(theme.border)

                    VStack(alignment: .leading, spacing: 4) {
                        Label("Selected", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(theme.route)
                        Text(inputLabel(for: candidate))
                            .font(.headline)
                            .foregroundStyle(theme.primaryText)
                        if candidate.address != inputLabel(for: candidate) {
                            Text(candidate.address)
                                .font(.footnote)
                                .foregroundStyle(theme.secondaryText)
                        }
                    }

                    Button("Use this location") {
                        onConfirm(candidate)
                        dismiss()
                    }
                    .buttonStyle(ItineraPrimaryButtonStyle())
                    .accessibilityHint("Confirms the selected map location")
                } else if results.isEmpty && message == nil {
                    Label(
                        "Search by name, or tap the map. A location is saved only after you confirm it.",
                        systemImage: "hand.tap"
                    )
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(16)
        }
        .frame(maxHeight: 310)
        .background(theme.surface)
    }

    private func resultRow(_ result: SelectedLocation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: candidate == result ? "checkmark.circle.fill" : "mappin.circle")
                .font(.title3)
                .foregroundStyle(candidate == result ? theme.route : theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(result.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                Text(result.address)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 5)
    }

    private func startSearch() {
        let submittedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submittedQuery.isEmpty else { return }

        searchTask?.cancel()
        geocodeTask?.cancel()
        reverseGeocodeStatus.supersede()
        candidate = nil
        searchStatus.begin(query: submittedQuery)
        message = nil
        searchTask = Task {
            await performSearch(submittedQuery)
        }
    }

    private func performSearch(_ submittedQuery: String) async {
        defer {
            searchStatus.finish(query: submittedQuery)
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchQuery(submittedQuery)
        request.resultTypes = purpose == .destination ? [.address] : [.address, .pointOfInterest]
        if let searchBias {
            request.region = MKCoordinateRegion(
                center: searchBias.coordinate.clCoordinate,
                latitudinalMeters: 75_000,
                longitudinalMeters: 75_000
            )
        }

        do {
            let response = try await MKLocalSearch(request: request).start()
            guard !Task.isCancelled,
                  query.trimmingCharacters(in: .whitespacesAndNewlines) == submittedQuery else {
                return
            }

            results = response.mapItems
                .prefix(8)
                .compactMap(makeLocation)
            if results.isEmpty {
                message = "No matches found. Try adding a region, country, or street name."
            } else {
                cameraPosition = .region(
                    MKCoordinateRegion(
                        center: results[0].coordinate.clCoordinate,
                        latitudinalMeters: purpose == .destination ? 180_000 : 12_000,
                        longitudinalMeters: purpose == .destination ? 180_000 : 12_000
                    )
                )
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            message = "Map search is unavailable right now. Check your connection and try again."
        }
    }

    private func reverseGeocode(_ coordinate: CLLocationCoordinate2D) {
        let requestCoordinate = LocationCoordinate(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        searchTask?.cancel()
        geocodeTask?.cancel()
        searchStatus.supersede()
        candidate = nil
        reverseGeocodeStatus.begin(coordinate: requestCoordinate)
        message = nil

        geocodeTask = Task {
            defer { reverseGeocodeStatus.finish(coordinate: requestCoordinate) }
            do {
                let placemark = try await CLGeocoder()
                    .reverseGeocodeLocation(
                        CLLocation(
                            latitude: requestCoordinate.latitude,
                            longitude: requestCoordinate.longitude
                        )
                    )
                    .first
                guard !Task.isCancelled, let placemark else { return }

                let location = makeLocation(
                    from: placemark,
                    coordinate: requestCoordinate.clCoordinate
                )
                guard isValid(location) else {
                    message = purpose == .destination
                        ? "Choose a map point that resolves to a city and country."
                        : "Choose a map point that resolves to an address."
                    return
                }
                choose(location)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                message = "We couldn't identify that map point. Try a nearby road or search by name."
            }
        }
    }

    private func chooseSearchResult(_ location: SelectedLocation) {
        geocodeTask?.cancel()
        reverseGeocodeStatus.supersede()
        choose(location)
    }

    private func choose(_ location: SelectedLocation) {
        guard isValid(location) else {
            message = purpose == .destination
                ? "That result doesn't include both a city and country. Try another match."
                : "That result doesn't include a usable address. Try another match."
            return
        }
        message = nil
        candidate = location
        cameraPosition = .region(
            MKCoordinateRegion(
                center: location.coordinate.clCoordinate,
                latitudinalMeters: purpose == .destination ? 80_000 : 4_000,
                longitudinalMeters: purpose == .destination ? 80_000 : 4_000
            )
        )
    }

    private func searchQuery(_ submittedQuery: String) -> String {
        guard purpose == .homeBase, let searchBias else { return submittedQuery }
        return "\(submittedQuery), \(searchBias.destinationInputLabel)"
    }

    private func inputLabel(for location: SelectedLocation) -> String {
        switch purpose {
        case .destination: location.destinationInputLabel
        case .homeBase: location.homeBaseInputLabel
        }
    }

    private func isValid(_ location: SelectedLocation) -> Bool {
        switch purpose {
        case .destination:
            !location.city.isEmpty && !location.country.isEmpty
        case .homeBase:
            !location.homeBaseInputLabel.isEmpty
        }
    }

    private func makeLocation(_ item: MKMapItem) -> SelectedLocation? {
        let placemark = item.placemark
        let name = item.name ?? placemark.locality ?? placemark.title ?? "Selected location"
        let address = placemark.title ?? name
        let city = placemark.locality
            ?? placemark.subAdministrativeArea
            ?? placemark.administrativeArea
            ?? (purpose == .destination ? name : "")
        let country = placemark.country ?? placemark.isoCountryCode ?? ""
        let coordinate = placemark.coordinate
        let location = SelectedLocation(
            name: name,
            address: address,
            city: city,
            country: country,
            coordinate: LocationCoordinate(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        )
        return isValid(location) ? location : nil
    }

    private func makeLocation(
        from placemark: CLPlacemark,
        coordinate: CLLocationCoordinate2D
    ) -> SelectedLocation {
        let city = placemark.locality
            ?? placemark.subAdministrativeArea
            ?? placemark.administrativeArea
            ?? ""
        let country = placemark.country ?? placemark.isoCountryCode ?? ""
        let name = purpose == .destination
            ? (city.isEmpty ? "Selected location" : city)
            : (placemark.name ?? city)
        let address = [
            placemark.name,
            placemark.locality,
            placemark.administrativeArea,
            placemark.country
        ]
        .compactMap { $0 }
        .reduce(into: [String]()) { parts, part in
            if !parts.contains(part) { parts.append(part) }
        }
        .joined(separator: ", ")

        return SelectedLocation(
            name: name,
            address: address,
            city: city,
            country: country,
            coordinate: LocationCoordinate(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        )
    }
}
