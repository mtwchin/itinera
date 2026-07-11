import SwiftUI

struct PlanView: View {
    @State private var destination: SelectedDestination?
    @State private var accommodation: String = ""
    @State private var arrivalDate: Date = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
    @State private var departureDate: Date = Calendar.current.date(byAdding: .day, value: 4, to: .now) ?? .now
    @State private var wakeUpTime: Date = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: .now) ?? .now
    @State private var budget: String = "Medium"
    @State private var groupSize: Int = 2
    @State private var foodPreferences: String = ""
    @State private var mustDo: String = ""

    @State private var showingDestinationSearch = false
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var generatedTrip: SavedTrip?

    private let maxTripDays = 14

    private var tripDays: Int {
        let start = Calendar.current.startOfDay(for: arrivalDate)
        let end = Calendar.current.startOfDay(for: departureDate)
        let days = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
        return max(days, 1)
    }

    private var validationMessage: String? {
        if destination == nil { return "Choose a destination to get started." }
        if accommodation.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Enter where you're staying so days can start and end there."
        }
        if departureDate <= arrivalDate { return "Departure must be after arrival." }
        if tripDays > maxTripDays { return "Trips can be up to \(maxTripDays) days." }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    hero

                    destinationCard
                    stayCard
                    datesCard
                    preferencesCard

                    generateButton

                    Text(validationMessage ?? "Itineraries are AI-generated — double-check hours and addresses before you go.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingDestinationSearch) {
                DestinationSearchView { selected in
                    destination = selected
                }
            }
            .fullScreenCover(item: $generatedTrip) { trip in
                NavigationStack {
                    ItineraryView(trip: trip, allowSaving: true)
                }
            }
            .overlay {
                if isGenerating {
                    GeneratingView()
                }
            }
            .alert("Couldn't generate itinerary", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Sections

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Where to next?")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
            Text("Trending spots, planned into your days.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(Theme.gradient)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Image(systemName: "airplane.departure")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.25))
                .padding(20)
        }
        .padding(.top, 8)
    }

    private var destinationCard: some View {
        FormCard(title: "Destination", systemImage: "globe.europe.africa.fill") {
            Button {
                Haptics.tap()
                showingDestinationSearch = true
            } label: {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    Text(destination?.displayName ?? "Search for a city")
                        .foregroundStyle(destination == nil ? .secondary : .primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }

    private var stayCard: some View {
        FormCard(title: "Staying at", systemImage: "bed.double.fill") {
            TextField("Hotel name or address", text: $accommodation)
                .textInputAutocapitalization(.words)
                .padding(12)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var datesCard: some View {
        FormCard(title: "Dates", systemImage: "calendar") {
            DatePicker("Arrival", selection: $arrivalDate, displayedComponents: .date)
            Divider()
            DatePicker("Departure", selection: $departureDate, in: arrivalDate..., displayedComponents: .date)
            Divider()
            LabeledContent("Length") {
                Text("\(tripDays) day\(tripDays == 1 ? "" : "s")")
                    .fontWeight(.medium)
                    .foregroundStyle(tripDays > maxTripDays ? .red : .primary)
            }
        }
    }

    private var preferencesCard: some View {
        FormCard(title: "Preferences", systemImage: "slider.horizontal.3") {
            DatePicker("Wake up time", selection: $wakeUpTime, displayedComponents: .hourAndMinute)
            Divider()
            Picker("Budget", selection: $budget) {
                Text("$").tag("Budget")
                Text("$$").tag("Medium")
                Text("$$$").tag("Luxury")
            }
            .pickerStyle(.segmented)
            Divider()
            Stepper("Travelers: \(groupSize)", value: $groupSize, in: 1...20)
            Divider()
            TextField("Food preferences (optional)", text: $foodPreferences)
            Divider()
            TextField("Must-do activities (optional)", text: $mustDo)
        }
    }

    private var generateButton: some View {
        Button {
            generate()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                Text("Generate Itinerary")
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                Theme.gradient.opacity(validationMessage == nil ? 1 : 0.4),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .disabled(validationMessage != nil || isGenerating)
        .padding(.top, 4)
    }

    // MARK: - Actions

    private func generate() {
        guard let destination, validationMessage == nil else { return }
        isGenerating = true

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH:mm"

        let request = GenerateItineraryRequest(
            city: destination.city,
            country: destination.country,
            accommodation: AccommodationRequest(
                address: accommodation.trimmingCharacters(in: .whitespaces),
                lat: 0,
                lng: 0
            ),
            arrivalDate: dayFormatter.string(from: arrivalDate),
            departureDate: dayFormatter.string(from: departureDate),
            budget: budget,
            lengthOfStay: tripDays,
            wakeUpTime: timeFormatter.string(from: wakeUpTime),
            groupSize: groupSize,
            foodPreferences: foodPreferences,
            mustDo: mustDo
        )

        Task {
            defer { isGenerating = false }
            do {
                let result = try await APIClient().generateItinerary(request)
                Haptics.success()
                generatedTrip = SavedTrip(
                    id: UUID(),
                    destination: destination.displayName,
                    startDate: arrivalDate,
                    endDate: departureDate,
                    budget: budget,
                    createdAt: .now,
                    itinerary: result.itinerary,
                    trendingPlaces: result.trendingPlaces
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Rounded card with an icon-labelled header, used by the Plan form.
struct FormCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.brandStart)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

#Preview {
    PlanView()
        .environmentObject(TripStore())
}
