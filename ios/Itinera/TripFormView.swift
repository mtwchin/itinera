import SwiftUI
import MapKit

struct TripFormView: View {
    @EnvironmentObject private var appState: AppState

    @State private var city = ""
    @State private var country = ""
    @State private var accommodationQuery = ""
    @State private var accommodation: Accommodation?
    @State private var arrival = Date()
    @State private var departure = Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date()
    @State private var groupSize = 2
    @State private var wakeUpTime = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var foodPreferences = ""
    @State private var mustDo = ""
    @State private var budget = "Medium"

    struct PendingJob: Identifiable, Hashable {
        let id: String
    }

    @State private var isResolvingAddress = false
    @State private var pendingJob: PendingJob?
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    private var formValid: Bool {
        !city.isEmpty && !country.isEmpty && accommodation != nil && departure > arrival
    }

    private var departureRange: ClosedRange<Date> {
        let calendar = Calendar.current
        let earliest = calendar.date(byAdding: .day, value: 1, to: arrival) ?? arrival
        let latest = calendar.date(byAdding: .day, value: 30, to: arrival) ?? earliest
        return earliest...latest
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Destination") {
                    TextField("City", text: $city)
                    TextField("Country", text: $country)
                }
                Section("Accommodation") {
                    TextField("Hotel or address", text: $accommodationQuery)
                        .onSubmit { resolveAccommodation() }
                    if isResolvingAddress {
                        ProgressView()
                    } else if let accommodation {
                        Label(accommodation.address, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.footnote)
                    } else if !accommodationQuery.isEmpty {
                        Button("Find address") { resolveAccommodation() }
                    }
                }
                Section("Dates") {
                    DatePicker("Arrival", selection: $arrival, displayedComponents: .date)
                        .onChange(of: arrival) { _, _ in
                            if !departureRange.contains(departure) {
                                departure = min(
                                    departureRange.upperBound,
                                    Calendar.current.date(
                                        byAdding: .day,
                                        value: 3,
                                        to: arrival
                                    ) ?? departureRange.lowerBound
                                )
                            }
                        }
                    DatePicker(
                        "Departure",
                        selection: $departure,
                        in: departureRange,
                        displayedComponents: .date
                    )
                    DatePicker("Wake-up time", selection: $wakeUpTime, displayedComponents: .hourAndMinute)
                }
                Section("Preferences") {
                    Stepper("Group size: \(groupSize)", value: $groupSize, in: 1...20)
                    Picker("Budget", selection: $budget) {
                        ForEach(["Low", "Medium", "High"], id: \.self) { Text($0) }
                    }
                    TextField("Food preferences (optional)", text: $foodPreferences)
                    TextField("Must-do activities (optional)", text: $mustDo)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red).font(.footnote)
                    }
                }
                Section {
                    Button { submit() } label: {
                        HStack {
                            if isSubmitting { ProgressView() }
                            Text(isSubmitting ? "Starting…" : "Generate Itinerary")
                        }
                        .frame(maxWidth: .infinity)
                        .bold()
                    }
                    .disabled(!formValid || isSubmitting)
                }
            }
            .navigationTitle("Plan a Trip")
            .navigationDestination(item: $pendingJob) { job in
                GenerationView(jobID: job.id)
            }
        }
    }

    private func resolveAccommodation() {
        guard !accommodationQuery.isEmpty else { return }
        isResolvingAddress = true
        accommodation = nil
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "\(accommodationQuery), \(city), \(country)"
        Task {
            defer { isResolvingAddress = false }
            guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else {
                errorMessage = "Couldn't find that address — try being more specific."
                return
            }
            errorMessage = nil
            let coord = item.placemark.coordinate
            accommodation = Accommodation(
                address: item.placemark.title ?? accommodationQuery,
                lat: coord.latitude,
                lng: coord.longitude
            )
        }
    }

    private func submit() {
        guard let accommodation else { return }
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = Calendar.current.timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH:mm"

        let payload = GenerateItineraryRequest(
            city: city,
            country: country,
            accommodation: accommodation,
            arrivalDate: dayFormatter.string(from: arrival),
            departureDate: dayFormatter.string(from: departure),
            groupSize: groupSize,
            wakeUpTime: timeFormatter.string(from: wakeUpTime),
            foodPreferences: foodPreferences.isEmpty ? nil : foodPreferences,
            mustDo: mustDo.isEmpty ? nil : mustDo,
            budget: budget
        )
        Task {
            isSubmitting = true
            errorMessage = nil
            defer { isSubmitting = false }
            do {
                let job = try await appState.submitItinerary(
                    payload,
                    title: "\(city), \(country)"
                )
                pendingJob = PendingJob(id: job.jobId)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
