import MapKit
import SwiftUI

struct TripFormView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.itineraTheme) private var theme

    @State private var destinationQuery = ""
    @State private var destination: SelectedLocation?
    @State private var homeBaseQuery = ""
    @State private var homeBase: SelectedLocation?
    @State private var arrival = Date()
    @State private var departure = Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date()
    @State private var groupSize = 2
    @State private var wakeUpTime = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var foodPreferences = ""
    @State private var mustDo = ""
    @State private var budget = "Medium"
    @State private var preferencesExpanded = false
    @State private var activeLocationPicker: LocationPickerPurpose?
    @State private var isShowingDatePicker = false
    @State private var pendingJob: PendingJob?
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    struct PendingJob: Identifiable, Hashable {
        let id: String
    }

    private var formValid: Bool {
        destination != nil
            && homeBase != nil
            && departure > arrival
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ItineraBackground()

                ScrollView {
                    LazyVStack(spacing: 18) {
                        ItineraBrandHeader(
                            eyebrow: "Itinera · Field Guide 01",
                            title: "Chart a trip worth remembering.",
                            message: "Start with where you'll wake up. We'll shape the days around the places that matter."
                        )
                        .padding(.horizontal, 4)
                        .padding(.bottom, 4)

                        destinationSection
                        accommodationSection
                        datesSection
                        preferencesSection

                        if let errorMessage {
                            ItineraStatusBanner(message: errorMessage, kind: .error)
                        }

                        Label("Location search and map selection are provided by Apple Maps.", systemImage: "apple.logo")
                            .font(.caption2)
                            .foregroundStyle(theme.secondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 2)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                primaryActionBar
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationDestination(item: $pendingJob) { job in
                GenerationView(jobID: job.id)
            }
            .sheet(item: $activeLocationPicker) { purpose in
                LocationPickerSheet(
                    purpose: purpose,
                    initialQuery: purpose == .destination ? destinationQuery : homeBaseQuery,
                    currentSelection: purpose == .destination ? destination : homeBase,
                    searchBias: purpose == .homeBase ? destination : nil
                ) { selection in
                    apply(selection, for: purpose)
                }
            }
            .sheet(isPresented: $isShowingDatePicker) {
                TripDateRangePickerSheet(start: $arrival, end: $departure)
            }
            .onChange(of: destinationQuery) { _, newValue in
                if let destination, newValue != destination.destinationInputLabel {
                    self.destination = nil
                    clearHomeBase()
                }
            }
            .onChange(of: homeBaseQuery) { _, newValue in
                if let homeBase, newValue != homeBase.homeBaseInputLabel {
                    self.homeBase = nil
                }
            }
        }
    }

    private var primaryActionBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(theme.border.opacity(0.55))
                .frame(height: 1)

            Button(action: submit) {
                HStack(spacing: 10) {
                    if isSubmitting {
                        ProgressView()
                            .tint(theme.accentContrast)
                    } else {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                    Text(primaryActionTitle)
                }
            }
            .buttonStyle(ItineraPrimaryButtonStyle())
            .disabled(!formValid || isSubmitting)
            .opacity(formValid && !isSubmitting ? 1 : 0.48)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
    }

    private var primaryActionTitle: String {
        if isSubmitting {
            return "Starting your route…"
        }
        if destination == nil {
            return "Add a destination to continue"
        }
        if homeBase == nil {
            return "Confirm your home base"
        }
        return "Build my itinerary"
    }

    private var destinationSection: some View {
        ItineraSurface {
            VStack(alignment: .leading, spacing: 14) {
                ItineraSectionHeading(
                    number: "01",
                    title: "Destination",
                    message: "Search once, then confirm the city on the map."
                )

                locationInput(
                    placeholder: "City or region",
                    text: $destinationQuery,
                    purpose: .destination
                )

                if let destination {
                    ItineraStatusBanner(
                        message: "Destination set: \(destination.destinationInputLabel)",
                        kind: .success
                    )
                } else if !destinationQuery.isEmpty {
                    ItineraStatusBanner(
                        message: "Open the map and confirm a matching destination.",
                        kind: .warning
                    )
                }
            }
        }
    }

    private var accommodationSection: some View {
        ItineraSurface {
            VStack(alignment: .leading, spacing: 14) {
                ItineraSectionHeading(
                    number: "02",
                    title: "Home base",
                    message: "Search for a hotel, neighborhood, or address near your destination."
                )

                locationInput(
                    placeholder: "Hotel, neighborhood, or address",
                    text: $homeBaseQuery,
                    purpose: .homeBase
                )
                .disabled(destination == nil)
                .opacity(destination == nil ? 0.5 : 1)

                if destination == nil {
                    Text("Choose a destination first so the search stays nearby.")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                } else if let homeBase {
                    ItineraStatusBanner(message: homeBase.homeBaseInputLabel, kind: .success)
                } else if !homeBaseQuery.isEmpty {
                    ItineraStatusBanner(
                        message: "Open the map and confirm your home base.",
                        kind: .warning
                    )
                }
            }
        }
    }

    private var datesSection: some View {
        ItineraSurface {
            VStack(alignment: .leading, spacing: 14) {
                ItineraSectionHeading(
                    number: "03",
                    title: "Trip rhythm",
                    message: "Set the dates and the pace of your mornings."
                )

                Button {
                    isShowingDatePicker = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "calendar.badge.clock")
                            .frame(width: 24)
                            .foregroundStyle(theme.highlight)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Trip dates")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(theme.secondaryText)
                            Text(dateRangeLabel)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(theme.primaryText)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: 52)
                .accessibilityLabel("Trip dates, \(dateRangeLabel)")
                .accessibilityHint("Choose arrival first and departure second")

                Divider().overlay(theme.border)

                dateRow(title: "Start the day", systemImage: "alarm.fill") {
                    DatePicker("Wake-up time", selection: $wakeUpTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
            }
        }
    }

    private var preferencesSection: some View {
        ItineraSurface {
            VStack(alignment: .leading, spacing: 16) {
                Button {
                    withAnimation(.snappy) {
                        preferencesExpanded.toggle()
                    }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        ItineraSectionHeading(
                            number: "04",
                            title: "Travel style",
                            message: preferencesExpanded
                                ? "A few signals help make the route feel like yours."
                                : "\(groupSize) travelers · \(budget) budget"
                        )
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(theme.secondaryText)
                            .rotationEffect(.degrees(preferencesExpanded ? 180 : 0))
                            .frame(width: 32, height: 32)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(preferencesExpanded ? "Collapse travel style" : "Expand travel style")

                if preferencesExpanded {
                    VStack(alignment: .leading, spacing: 16) {
                        Stepper(value: $groupSize, in: 1...20) {
                            HStack {
                                Image(systemName: "person.2.fill")
                                    .foregroundStyle(theme.route)
                                Text("Travelers")
                                    .foregroundStyle(theme.primaryText)
                                Spacer()
                                Text("\(groupSize)")
                                    .font(.body.monospacedDigit().weight(.bold))
                                    .foregroundStyle(theme.primaryText)
                            }
                        }

                        Divider().overlay(theme.border)

                        VStack(alignment: .leading, spacing: 9) {
                            Text("Budget")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(theme.secondaryText)
                            Picker("Budget", selection: $budget) {
                                Text("Low").tag("Low")
                                Text("Medium").tag("Medium")
                                Text("High").tag("High")
                            }
                            .pickerStyle(.segmented)
                        }

                        TextField("Food preferences (optional)", text: $foodPreferences)
                            .itineraField()
                            .accessibilityLabel("Food preferences")

                        TextField("Must-do activities (optional)", text: $mustDo)
                            .itineraField()
                            .accessibilityLabel("Must-do activities")
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    HStack(spacing: 8) {
                        ItineraPill(text: "\(groupSize) people", systemImage: "person.2")
                        ItineraPill(text: budget, systemImage: "banknote")
                    }
                }
            }
        }
    }

    private func dateRow<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder control: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 24)
                .foregroundStyle(theme.highlight)
            Text(title)
                .foregroundStyle(theme.primaryText)
            Spacer(minLength: 10)
            control()
                .tint(theme.accent)
        }
        .frame(minHeight: 44)
    }

    private var dateRangeLabel: String {
        let nights = Calendar.current.dateComponents([.day], from: arrival, to: departure).day ?? 0
        return "\(arrival.formatted(date: .abbreviated, time: .omitted)) → \(departure.formatted(date: .abbreviated, time: .omitted)) · \(nights) nights"
    }

    private func locationInput(
        placeholder: String,
        text: Binding<String>,
        purpose: LocationPickerPurpose
    ) -> some View {
        HStack(spacing: 10) {
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.words)
                .submitLabel(.search)
                .onSubmit { activeLocationPicker = purpose }
                .itineraField()
                .accessibilityLabel(purpose == .destination ? "Destination" : "Home base")

            Button {
                activeLocationPicker = purpose
            } label: {
                Image(systemName: "map.fill")
                    .font(.headline)
                    .foregroundStyle(theme.accentContrast)
                    .frame(width: 50, height: 50)
                    .background(theme.accent, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(purpose == .destination ? "Choose destination on map" : "Choose home base on map")
        }
    }

    private func apply(_ selection: SelectedLocation, for purpose: LocationPickerPurpose) {
        switch purpose {
        case .destination:
            let changed = destination != selection
            destination = selection
            destinationQuery = selection.destinationInputLabel
            if changed {
                clearHomeBase()
            }
        case .homeBase:
            homeBase = selection
            homeBaseQuery = selection.homeBaseInputLabel
        }
    }

    private func clearHomeBase() {
        homeBase = nil
        homeBaseQuery = ""
    }

    private func submit() {
        guard let destination, let homeBase else { return }
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = Calendar.current.timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH:mm"

        let payload = GenerateItineraryRequest(
            city: destination.city,
            country: destination.country,
            accommodation: homeBase.accommodation,
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
                    title: destination.destinationInputLabel
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

#Preview("Atlas · Plan") {
    TripFormView()
        .environmentObject(AppState.live())
        .environment(\.itineraTheme, .atlas)
        .preferredColorScheme(.light)
}
