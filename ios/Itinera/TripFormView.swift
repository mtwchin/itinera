import SwiftUI
import MapKit

struct TripFormView: View {
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

    private var formValid: Bool {
        !city.isEmpty && !country.isEmpty && accommodation != nil && departure > arrival
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
                    DatePicker("Departure", selection: $departure, in: arrival..., displayedComponents: .date)
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
                    Button("Generate Itinerary") { submit() }
                        .disabled(!formValid)
                        .frame(maxWidth: .infinity)
                        .bold()
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
        let isoDay = { (d: Date) in d.ISO8601Format(.iso8601.year().month().day()) }
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        let payload = GenerateItineraryRequest(
            city: city,
            country: country,
            accommodation: accommodation,
            arrivalDate: isoDay(arrival),
            departureDate: isoDay(departure),
            groupSize: groupSize,
            wakeUpTime: timeFormatter.string(from: wakeUpTime),
            foodPreferences: foodPreferences.isEmpty ? nil : foodPreferences,
            mustDo: mustDo.isEmpty ? nil : mustDo,
            budget: budget
        )
        Task {
            do {
                let job = try await APIClient.shared.createItinerary(payload)
                pendingJob = PendingJob(id: job.jobId)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}