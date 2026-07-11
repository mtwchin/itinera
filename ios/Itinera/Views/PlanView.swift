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
            Form {
                Section("Where are you going?") {
                    Button {
                        showingDestinationSearch = true
                    } label: {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            Text(destination?.displayName ?? "Search for a city")
                                .foregroundStyle(destination == nil ? .secondary : .primary)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }

                Section("Where are you staying?") {
                    TextField("Hotel name or address", text: $accommodation)
                        .textInputAutocapitalization(.words)
                }

                Section("Trip dates") {
                    DatePicker("Arrival", selection: $arrivalDate, displayedComponents: .date)
                    DatePicker("Departure", selection: $departureDate, in: arrivalDate..., displayedComponents: .date)
                    LabeledContent("Length", value: "\(tripDays) day\(tripDays == 1 ? "" : "s")")
                }

                Section("Preferences") {
                    DatePicker("Wake up time", selection: $wakeUpTime, displayedComponents: .hourAndMinute)
                    Picker("Budget", selection: $budget) {
                        Text("Budget $").tag("Budget")
                        Text("Medium $$").tag("Medium")
                        Text("Luxury $$$").tag("Luxury")
                    }
                    Stepper("Travelers: \(groupSize)", value: $groupSize, in: 1...20)
                    TextField("Food preferences (optional)", text: $foodPreferences)
                    TextField("Must-do activities (optional)", text: $mustDo)
                }

                Section {
                    Button {
                        generate()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Generate Itinerary")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(validationMessage != nil || isGenerating)
                } footer: {
                    Text(validationMessage ?? "Itineraries are AI-generated — double-check opening hours and addresses before you go.")
                }
            }
            .navigationTitle("Itinera")
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
                let itinerary = try await APIClient().generateItinerary(request)
                generatedTrip = SavedTrip(
                    id: UUID(),
                    destination: destination.displayName,
                    startDate: arrivalDate,
                    endDate: departureDate,
                    budget: budget,
                    createdAt: .now,
                    itinerary: itinerary
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    PlanView()
        .environmentObject(TripStore())
}
