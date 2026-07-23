import MapKit
import SwiftUI

struct TripFormView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settingsPreferences: SettingsPreferences
    @Environment(\.itineraTheme) private var theme
    @State private var savedDraftData = Data()
    @State private var didLoadDraft = false
    @State private var didEditDraftBeforeLoad = false

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
    @State private var pace = "Balanced"
    @State private var transportationPreferences = Set(TripTransportationOption.allCases)
    @State private var travelingWithChildren = false
    @State private var interestCategories = Set<TripInterestCategory>()
    @State private var accessibilityCategories = Set<TripAccessibilityCategory>()
    @State private var scheduleConstraints: [TripScheduleConstraint] = []
    @State private var scheduleKind: TripScheduleConstraint.Kind = .freeTime
    @State private var scheduleDate = Date()
    @State private var scheduleStartsAt = Calendar.current.date(
        bySettingHour: 9,
        minute: 0,
        second: 0,
        of: Date()
    ) ?? Date()
    @State private var scheduleEndsAt = Calendar.current.date(
        bySettingHour: 10,
        minute: 0,
        second: 0,
        of: Date()
    ) ?? Date()
    @State private var scheduleTitle = ""
    @State private var scheduleAddress = ""
    @State private var scheduleValidationMessage: String?
    @State private var preferencesExpanded = false
    @State private var activeLocationPicker: LocationPickerPurpose?
    @State private var isShowingDatePicker = false
    @State private var pendingJob: PendingJob?
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @State private var isShowingAIDataDisclosure = false

    struct PendingJob: Identifiable, Hashable {
        let id: String
    }

    private var formValid: Bool {
        destination != nil
            && homeBase != nil
            && TripDateRangeSelection.isValid(start: arrival, end: departure)
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
            .sheet(isPresented: $isShowingAIDataDisclosure) {
                NavigationStack {
                    AIDataDisclosureView(
                        disclosure: .current,
                        hasConsent: settingsPreferences.hasCurrentAIDataConsent,
                        onAccept: {
                            try await appState.grantAIConsent(
                                version: AIDataDisclosure.current.version
                            )
                            settingsPreferences.acceptCurrentAIDataConsent()
                            submit()
                        },
                        onWithdraw: {
                            try await appState.withdrawAIConsent()
                            settingsPreferences.withdrawAIDataConsent()
                        }
                    )
                }
                .environment(\.itineraTheme, theme)
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
            .onChange(of: arrival) { _, _ in
                clampScheduleDateToTrip()
                discardScheduleConstraintsOutsideTrip()
            }
            .onChange(of: departure) { _, _ in
                clampScheduleDateToTrip()
                discardScheduleConstraintsOutsideTrip()
            }
            .task {
                let storedDraft = await appState.loadTripDraftData() ?? Data()
                if !didEditDraftBeforeLoad {
                    savedDraftData = storedDraft
                    restoreDraft()
                }
                didLoadDraft = true
                if didEditDraftBeforeLoad,
                   let encoded = TripDraftCodec.encode(draftSnapshot) {
                    savedDraftData = encoded
                    await appState.saveTripDraftData(encoded)
                }
            }
            .onChange(of: draftSnapshot) { _, draft in
                guard didLoadDraft else {
                    didEditDraftBeforeLoad = true
                    return
                }
                if let encoded = TripDraftCodec.encode(draft) {
                    savedDraftData = encoded
                    Task { await appState.saveTripDraftData(encoded) }
                }
            }
        }
    }

    private var draftSnapshot: TripDraft {
        TripDraft(
            destinationQuery: destinationQuery,
            destination: destination,
            homeBaseQuery: homeBaseQuery,
            homeBase: homeBase,
            arrival: arrival,
            departure: departure,
            groupSize: groupSize,
            wakeUpTime: wakeUpTime,
            foodPreferences: foodPreferences,
            mustDo: mustDo,
            budget: budget,
            pace: pace,
            transportationPreference: transportationDraftValue,
            travelingWithChildren: travelingWithChildren,
            interests: selectedInterestValues.joined(separator: ","),
            accessibilityNeeds: selectedAccessibilityValues.joined(separator: ","),
            fixedReservations: "",
            unavailableTimes: "",
            scheduleConstraints: scheduleConstraints
        )
    }

    private func restoreDraft() {
        guard let draft = TripDraftCodec.decode(savedDraftData) else { return }
        destination = draft.destination
        destinationQuery = draft.destinationQuery
        homeBase = draft.homeBase
        homeBaseQuery = draft.homeBaseQuery
        arrival = max(draft.arrival, Calendar.current.startOfDay(for: Date()))
        departure = max(
            draft.departure,
            Calendar.current.date(byAdding: .day, value: 1, to: arrival) ?? arrival
        )
        groupSize = draft.groupSize
        wakeUpTime = draft.wakeUpTime
        foodPreferences = draft.foodPreferences
        mustDo = draft.mustDo
        budget = draft.budget
        pace = draft.pace
        transportationPreferences = TripTransportationOption.selection(
            fromStoredValue: draft.transportationPreference
        )
        travelingWithChildren = draft.travelingWithChildren
        interestCategories = TripInterestCategory.selection(
            fromStoredValue: draft.interests
        )
        accessibilityCategories = TripAccessibilityCategory.selection(
            fromStoredValue: draft.accessibilityNeeds
        )
        scheduleConstraints = draft.scheduleConstraints ?? []
        clampScheduleDateToTrip()
    }

    private var primaryActionBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(theme.border.opacity(0.55))
                .frame(height: 1)

            HStack(spacing: 0) {
                formStep("Destination", done: destination != nil)
                stepConnector(done: destination != nil)
                formStep("Home base", done: homeBase != nil)
                stepConnector(done: homeBase != nil)
                formStep("Dates", done: departure > arrival)
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)

            Button(action: requestSubmission) {
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

    private func formStep(_ label: String, done: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(done ? theme.success : theme.secondaryText.opacity(0.6))
                .scaleEffect(done ? 1.15 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: done)
            Text(label)
                .font(.caption2.weight(done ? .semibold : .regular))
                .foregroundStyle(done ? theme.primaryText : theme.secondaryText.opacity(0.7))
        }
        .animation(.easeInOut(duration: 0.2), value: done)
    }

    private func stepConnector(done: Bool) -> some View {
        Rectangle()
            .fill((done ? theme.success : theme.border).opacity(0.55))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)
            .animation(.easeInOut(duration: 0.25), value: done)
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
        if !settingsPreferences.hasCurrentAIDataConsent {
            return "Review AI data use"
        }
        return "Build my itinerary"
    }

    private func requestSubmission() {
        guard settingsPreferences.hasCurrentAIDataConsent else {
            isShowingAIDataDisclosure = true
            return
        }
        submit()
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
                                : "\(groupSize) travelers · \(pace.lowercased()) pace"
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
                            HStack(spacing: 8) {
                                ForEach(["Low", "Medium", "High"], id: \.self) { option in
                                    Button {
                                        withAnimation(.snappy) { budget = option }
                                    } label: {
                                        Text(option)
                                            .font(.subheadline.weight(budget == option ? .semibold : .regular))
                                            .foregroundStyle(budget == option ? .white : theme.primaryText)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 8)
                                            .background(
                                                budget == option ? theme.accent : theme.accent.opacity(0.09),
                                                in: Capsule()
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Budget: \(option)")
                                    .accessibilityAddTraits(budget == option ? .isSelected : [])
                                }
                            }
                            .sensoryFeedback(.selection, trigger: budget)
                        }

                        VStack(alignment: .leading, spacing: 9) {
                            Text("Pace")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(theme.secondaryText)
                            HStack(spacing: 8) {
                                ForEach(["Relaxed", "Balanced", "Full"], id: \.self) { option in
                                    Button {
                                        withAnimation(.snappy) { pace = option }
                                    } label: {
                                        Text(option)
                                            .font(.subheadline.weight(pace == option ? .semibold : .regular))
                                            .foregroundStyle(pace == option ? .white : theme.primaryText)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 8)
                                            .background(
                                                pace == option ? theme.accent : theme.accent.opacity(0.09),
                                                in: Capsule()
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Pace: \(option)")
                                    .accessibilityAddTraits(pace == option ? .isSelected : [])
                                }
                            }
                            .sensoryFeedback(.selection, trigger: pace)
                        }

                        VStack(alignment: .leading, spacing: 9) {
                            Text("Getting around")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(theme.secondaryText)

                            Text("Choose every option you're comfortable using.")
                                .font(.caption)
                                .foregroundStyle(theme.secondaryText)

                            VStack(spacing: 0) {
                                ForEach(TripTransportationOption.allCases) { option in
                                    Button {
                                        toggleTransportation(option)
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: option.systemImage)
                                                .font(.body.weight(.semibold))
                                                .foregroundStyle(theme.accent)
                                                .frame(width: 34, height: 34)
                                                .background(
                                                    theme.accent.opacity(0.1),
                                                    in: RoundedRectangle(cornerRadius: 9)
                                                )

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(option.rawValue)
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(theme.primaryText)
                                                Text(option.detail)
                                                    .font(.caption)
                                                    .foregroundStyle(theme.secondaryText)
                                                    .multilineTextAlignment(.leading)
                                            }

                                            Spacer(minLength: 8)

                                            Image(
                                                systemName: transportationPreferences.contains(option)
                                                    ? "checkmark.square.fill"
                                                    : "square"
                                            )
                                            .font(.title3)
                                            .foregroundStyle(
                                                transportationPreferences.contains(option)
                                                    ? theme.accent
                                                    : theme.secondaryText
                                            )
                                            .scaleEffect(transportationPreferences.contains(option) ? 1.1 : 1)
                                            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: transportationPreferences.contains(option))
                                        }
                                        .contentShape(Rectangle())
                                        .padding(.vertical, 11)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(
                                        transportationPreferences.contains(option)
                                            && transportationPreferences.count == 1
                                    )
                                    .accessibilityLabel(option.rawValue)
                                    .accessibilityValue(
                                        transportationPreferences.contains(option)
                                            ? "Selected"
                                            : "Not selected"
                                    )

                                    if option != TripTransportationOption.allCases.last {
                                        Divider().overlay(theme.border.opacity(0.65))
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .background(
                                theme.surfaceStrong.opacity(0.72),
                                in: RoundedRectangle(cornerRadius: 14)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(theme.border.opacity(0.7), lineWidth: 1)
                            }
                        }

                        Toggle(isOn: $travelingWithChildren) {
                            Label("Traveling with children", systemImage: "figure.and.child.holdinghands")
                                .foregroundStyle(theme.primaryText)
                        }
                        .tint(theme.accent)

                        TextField("Food preferences (optional)", text: $foodPreferences)
                            .itineraField()
                            .accessibilityLabel("Food preferences")

                        TextField("Must-do activities (optional)", text: $mustDo)
                            .itineraField()
                            .accessibilityLabel("Must-do activities")

                        interestCategorySection

                        Divider().overlay(theme.border)

                        accessibilityCategorySection

                        Divider().overlay(theme.border)

                        scheduleConstraintSection
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    HStack(spacing: 8) {
                        ItineraPill(text: "\(groupSize) people", systemImage: "person.2")
                        ItineraPill(text: budget, systemImage: "banknote")
                        ItineraPill(text: pace, systemImage: "speedometer")
                    }
                }
            }
        }
    }

    private var interestCategorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Interests")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryText)
            Text("Choose any categories you want the itinerary to emphasize.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 138), spacing: 8)],
                spacing: 8
            ) {
                ForEach(TripInterestCategory.allCases) { category in
                    categoryButton(
                        title: category.rawValue,
                        systemImage: category.systemImage,
                        isSelected: interestCategories.contains(category)
                    ) {
                        if interestCategories.contains(category) {
                            interestCategories.remove(category)
                        } else {
                            interestCategories.insert(category)
                        }
                    }
                }
            }
        }
    }

    private var accessibilityCategorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mobility & accessibility")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryText)
            Text("Select every accommodation the route should account for.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 138), spacing: 8)],
                spacing: 8
            ) {
                ForEach(TripAccessibilityCategory.allCases) { category in
                    categoryButton(
                        title: category.rawValue,
                        systemImage: category.systemImage,
                        isSelected: accessibilityCategories.contains(category)
                    ) {
                        if accessibilityCategories.contains(category) {
                            accessibilityCategories.remove(category)
                        } else {
                            accessibilityCategories.insert(category)
                        }
                    }
                }
            }
        }
    }

    private func categoryButton(
        title: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                }
            }
            .foregroundStyle(isSelected ? theme.accentContrast : theme.primaryText)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .padding(.horizontal, 11)
            .background(
                isSelected ? theme.accent : theme.surfaceStrong,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSelected ? theme.accent : theme.border.opacity(0.65),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
        .sensoryFeedback(.selection, trigger: isSelected)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private var scheduleConstraintSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Schedule")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryText)
            Text("Use the calendar to protect free time or anchor an existing reservation.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)

            HStack(spacing: 8) {
                ForEach(TripScheduleConstraint.Kind.allCases) { kind in
                    Button {
                        scheduleKind = kind
                        scheduleValidationMessage = nil
                    } label: {
                        Label(kind.title, systemImage: kind.systemImage)
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .foregroundStyle(
                                scheduleKind == kind
                                    ? theme.accentContrast
                                    : theme.primaryText
                            )
                            .background(
                                scheduleKind == kind
                                    ? theme.accent
                                    : theme.surfaceStrong,
                                in: RoundedRectangle(cornerRadius: 11)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(
                        scheduleKind == kind ? .isSelected : []
                    )
                }
            }

            DatePicker(
                "Schedule date",
                selection: $scheduleDate,
                in: scheduleDateRange,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .tint(theme.accent)

            if scheduleKind == .fixedReservation {
                TextField("Reservation or event name", text: $scheduleTitle)
                    .itineraField()
                    .accessibilityLabel("Fixed plan name")
                TextField("Address (optional)", text: $scheduleAddress)
                    .itineraField()
                    .accessibilityLabel("Fixed plan address")
            }

            HStack(spacing: 12) {
                scheduleTimePicker(title: "Starts", selection: $scheduleStartsAt)
                scheduleTimePicker(title: "Ends", selection: $scheduleEndsAt)
            }

            if let scheduleValidationMessage {
                Label(scheduleValidationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(theme.warning)
            }

            Button {
                addScheduleConstraint()
            } label: {
                Label(
                    scheduleKind == .freeTime ? "Keep this time free" : "Add fixed plan",
                    systemImage: "plus.circle.fill"
                )
            }
            .buttonStyle(ItineraPrimaryButtonStyle())

            if !scheduleConstraints.isEmpty {
                VStack(spacing: 8) {
                    ForEach(sortedScheduleConstraints) { constraint in
                        scheduleConstraintRow(constraint)
                            .revealOnAppear()
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func scheduleTimePicker(
        title: String,
        selection: Binding<Date>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryText)
            DatePicker(
                title,
                selection: selection,
                displayedComponents: .hourAndMinute
            )
            .labelsHidden()
            .tint(theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scheduleConstraintRow(
        _ constraint: TripScheduleConstraint
    ) -> some View {
        HStack(spacing: 11) {
            Image(systemName: constraint.kind.systemImage)
                .foregroundStyle(theme.accent)
                .frame(width: 34, height: 34)
                .background(theme.accent.opacity(0.1), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(constraint.kind == .freeTime ? "Keep free" : constraint.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                Text(scheduleConstraintSummary(constraint))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer(minLength: 4)

            Button(role: .destructive) {
                scheduleConstraints.removeAll { $0.id == constraint.id }
            } label: {
                Image(systemName: "trash")
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.danger)
            .accessibilityLabel("Remove \(constraint.title)")
        }
        .padding(10)
        .background(theme.surfaceStrong, in: RoundedRectangle(cornerRadius: 13))
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
        case .activity:
            break
        }
    }

    private func clearHomeBase() {
        homeBase = nil
        homeBaseQuery = ""
    }

    private var transportationDraftValue: String {
        TripTransportationOption.ordered(
            transportationPreferences.map(\.rawValue)
        ).joined(separator: ",")
    }

    private func toggleTransportation(_ option: TripTransportationOption) {
        if transportationPreferences.contains(option) {
            guard transportationPreferences.count > 1 else { return }
            transportationPreferences.remove(option)
        } else {
            transportationPreferences.insert(option)
        }
    }

    private var selectedInterestValues: [String] {
        TripInterestCategory.allCases
            .filter(interestCategories.contains)
            .map(\.rawValue)
    }

    private var selectedAccessibilityValues: [String] {
        TripAccessibilityCategory.allCases
            .filter(accessibilityCategories.contains)
            .map(\.rawValue)
    }

    private var scheduleDateRange: ClosedRange<Date> {
        let calendar = Calendar.current
        let lowerBound = calendar.startOfDay(for: arrival)
        let upperBound = max(lowerBound, calendar.startOfDay(for: departure))
        return lowerBound...upperBound
    }

    private var sortedScheduleConstraints: [TripScheduleConstraint] {
        scheduleConstraints.sorted {
            if $0.date == $1.date {
                return minutesSinceMidnight($0.startsAt) < minutesSinceMidnight($1.startsAt)
            }
            return $0.date < $1.date
        }
    }

    private func addScheduleConstraint() {
        let startMinutes = minutesSinceMidnight(scheduleStartsAt)
        let endMinutes = minutesSinceMidnight(scheduleEndsAt)
        guard endMinutes > startMinutes else {
            scheduleValidationMessage = "The end time must be later than the start time."
            return
        }

        let normalizedTitle = scheduleTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if scheduleKind == .fixedReservation && normalizedTitle.isEmpty {
            scheduleValidationMessage = "Add a name for the fixed reservation or event."
            return
        }

        scheduleConstraints.append(
            TripScheduleConstraint(
                id: UUID(),
                kind: scheduleKind,
                title: scheduleKind == .freeTime ? "Keep free" : normalizedTitle,
                date: Calendar.current.startOfDay(for: scheduleDate),
                startsAt: scheduleStartsAt,
                endsAt: scheduleEndsAt,
                address: scheduleAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        scheduleTitle = ""
        scheduleAddress = ""
        scheduleValidationMessage = nil
    }

    private func scheduleConstraintSummary(_ constraint: TripScheduleConstraint) -> String {
        let date = constraint.date.formatted(date: .abbreviated, time: .omitted)
        let start = constraint.startsAt.formatted(date: .omitted, time: .shortened)
        let end = constraint.endsAt.formatted(date: .omitted, time: .shortened)
        return "\(date) · \(start)–\(end)"
    }

    private func minutesSinceMidnight(_ date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private func clampScheduleDateToTrip() {
        scheduleDate = min(max(scheduleDate, scheduleDateRange.lowerBound), scheduleDateRange.upperBound)
    }

    private func discardScheduleConstraintsOutsideTrip() {
        let range = scheduleDateRange
        let previousCount = scheduleConstraints.count
        scheduleConstraints.removeAll { !range.contains(Calendar.current.startOfDay(for: $0.date)) }
        if scheduleConstraints.count != previousCount {
            scheduleValidationMessage = "Schedule entries outside the new trip dates were removed."
        }
    }

    private var requestTimeZone: TimeZone {
        destination?.timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
            ?? homeBase?.timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
            ?? .current
    }

    private var fixedReservationInputs: [FixedReservationInput] {
        scheduleConstraints.compactMap { constraint in
            guard constraint.kind == .fixedReservation else { return nil }
            return FixedReservationInput(
                title: constraint.title,
                startsAt: iso8601Date(
                    on: constraint.date,
                    at: constraint.startsAt
                ),
                endsAt: iso8601Date(
                    on: constraint.date,
                    at: constraint.endsAt
                ),
                address: constraint.address.isEmpty ? nil : constraint.address
            )
        }
    }

    private var unavailableTimeInputs: [UnavailableTimeInput] {
        scheduleConstraints.compactMap { constraint in
            guard constraint.kind == .freeTime else { return nil }
            return UnavailableTimeInput(
                date: tripDayString(constraint.date),
                startsAt: clockString(constraint.startsAt),
                endsAt: clockString(constraint.endsAt)
            )
        }
    }

    private func iso8601Date(on date: Date, at time: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = requestTimeZone
        let dateComponents = Calendar.current.dateComponents(
            [.year, .month, .day],
            from: date
        )
        let timeComponents = Calendar.current.dateComponents(
            [.hour, .minute],
            from: time
        )
        let combined = calendar.date(
            from: DateComponents(
                timeZone: requestTimeZone,
                year: dateComponents.year,
                month: dateComponents.month,
                day: dateComponents.day,
                hour: timeComponents.hour,
                minute: timeComponents.minute
            )
        ) ?? date
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = requestTimeZone
        return formatter.string(from: combined)
    }

    private func tripDayString(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func clockString(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(
            format: "%02d:%02d",
            components.hour ?? 0,
            components.minute ?? 0
        )
    }

    private func submit() {
        guard settingsPreferences.hasCurrentAIDataConsent else {
            isShowingAIDataDisclosure = true
            return
        }
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
            mustDo: combinedMustDo,
            budget: budget,
            pace: pace,
            transportationModes: TripTransportationOption.ordered(
                transportationPreferences.map(\.rawValue)
            ),
            travelingWithChildren: travelingWithChildren,
            interests: selectedInterestValues,
            accessibilityCategories: selectedAccessibilityValues,
            accessibilityNeeds: nil,
            fixedReservations: fixedReservationInputs,
            unavailableTimes: unavailableTimeInputs,
            timezone: destination.timeZoneIdentifier
                ?? homeBase.timeZoneIdentifier
                ?? TimeZone.current.identifier
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

    private var combinedMustDo: String? {
        let value = mustDo.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

#Preview("Atlas · Plan") {
    TripFormView()
        .environmentObject(AppState.preview())
        .environmentObject(SettingsPreferences())
        .environment(\.itineraTheme, .atlas)
        .preferredColorScheme(.light)
}
