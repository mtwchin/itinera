import SwiftUI

struct TripEditorView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.itineraTheme) private var theme

    let jobID: String
    let tripTitle: String
    let onApply: (Itinerary, Int) -> Void

    @State private var itinerary: Itinerary
    @State private var version: Int
    @State private var selectedDay: Int
    @State private var history: [ItineraryRevisionResponse] = []
    @State private var undoStack: [(day: Int, snapshot: ItineraryDay)] = []
    @State private var lockedActivityIDs: Set<String>
    @State private var editorTarget: ActivityEditorTarget?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var weatherAdvisory: WeatherAdvisory?
    @State private var isCheckingWeather = false

    init(
        jobID: String,
        tripTitle: String,
        itinerary: Itinerary,
        version: Int,
        onApply: @escaping (Itinerary, Int) -> Void
    ) {
        self.jobID = jobID
        self.tripTitle = tripTitle
        self.onApply = onApply
        _itinerary = State(initialValue: itinerary)
        _version = State(initialValue: version)
        _selectedDay = State(initialValue: itinerary.itinerary.first?.day ?? 1)
        let stored = UserDefaults.standard.stringArray(
            forKey: Self.lockKey(jobID)
        ) ?? []
        _lockedActivityIDs = State(initialValue: Set(stored))
    }

    private var dayIndex: Int? {
        itinerary.itinerary.firstIndex { $0.day == selectedDay }
    }

    private var day: ItineraryDay? {
        dayIndex.map { itinerary.itinerary[$0] }
    }

    var body: some View {
        ZStack {
            ItineraBackground()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ItineraBrandHeader(
                        eyebrow: "Revision \(version)",
                        title: "Shape \(tripTitle)",
                        message: "Manual edits create a new revision. Locked stops are protected from quick refinements."
                    )

                    if let errorMessage {
                        ItineraStatusBanner(message: errorMessage, kind: .error)
                    }

                    dayPicker

                    if let day {
                        refinementCard(day)
                        activityEditor(day)
                    }

                    if !history.isEmpty {
                        historyCard
                    }
                }
                .padding(18)
                .padding(.bottom, 30)
            }

            if isWorking {
                ProgressView()
                    .controlSize(.large)
                    .tint(theme.route)
                    .padding(26)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
            }
        }
        .navigationTitle("Edit itinerary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await undo() }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(undoStack.isEmpty || isWorking)
            }
        }
        .task { await loadHistory() }
        .sheet(item: $editorTarget) { target in
            NavigationStack {
                ActivityEditorForm(target: target) { activity in
                    Task { await saveActivity(activity, target: target) }
                }
            }
            .environment(\.itineraTheme, theme)
        }
    }

    private var dayPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(itinerary.itinerary) { day in
                    Button("Day \(day.day)") { selectedDay = day.day }
                        .buttonStyle(.borderedProminent)
                        .tint(selectedDay == day.day ? theme.accent : theme.secondaryText.opacity(0.35))
                }
            }
        }
    }

    private func refinementCard(_ day: ItineraryDay) -> some View {
        ItineraSurface {
            VStack(alignment: .leading, spacing: 13) {
                ItineraSectionHeading(
                    number: "REFINE",
                    title: "Adjust this day",
                    message: "Quick changes never remove a locked stop."
                )

                HStack(spacing: 10) {
                    Button {
                        Task { await makeDayLighter(day) }
                    } label: {
                        Label("Make lighter", systemImage: "leaf")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(day.activities.filter { !lockedActivityIDs.contains($0.id) }.count < 2)

                    Button {
                        Task { await sortDayByTime(day) }
                    } label: {
                        Label("Sort by time", systemImage: "clock.arrow.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .tint(theme.accent)

                Button {
                    Task { await checkWeather(day) }
                } label: {
                    HStack {
                        if isCheckingWeather { ProgressView() }
                        Label("Check weather for this day", systemImage: "cloud.sun")
                    }
                }
                .buttonStyle(.bordered)
                .tint(theme.route)
                .disabled(isCheckingWeather || day.activities.isEmpty)

                if let weatherAdvisory {
                    ItineraStatusBanner(
                        message: "\(weatherAdvisory.summary), \(weatherAdvisory.temperature) · \(Int((weatherAdvisory.precipitationChance * 100).rounded()))% precipitation",
                        kind: weatherAdvisory.recommendsIndoorPlan ? .warning : .success
                    )
                    if weatherAdvisory.recommendsIndoorPlan {
                        Button {
                            Task { await makeWeatherReady(day) }
                        } label: {
                            Label("Move indoor stops earlier", systemImage: "cloud.rain")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.accent)
                    }
                }
            }
        }
    }

    private func activityEditor(_ day: ItineraryDay) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ItineraSectionHeading(
                number: "DAY \(day.day)",
                title: day.theme,
                message: "Move, replace, remove, or lock individual stops."
            )

            ForEach(Array(day.activities.enumerated()), id: \.element.id) { index, activity in
                ItineraSurface(padding: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(theme.highlightStrong, in: Circle())

                        VStack(alignment: .leading, spacing: 4) {
                            Text(activity.name)
                                .font(.headline)
                                .foregroundStyle(theme.primaryText)
                            Text("\(activity.time) · \(activity.duration)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(theme.secondaryText)
                            Text(activity.address)
                                .font(.caption)
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 0)

                        Button {
                            toggleLock(activity)
                        } label: {
                            Image(systemName: lockedActivityIDs.contains(activity.id) ? "lock.fill" : "lock.open")
                                .frame(width: 38, height: 38)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(lockedActivityIDs.contains(activity.id) ? theme.highlightStrong : theme.secondaryText)
                        .accessibilityLabel(lockedActivityIDs.contains(activity.id) ? "Unlock \(activity.name)" : "Lock \(activity.name)")

                        Menu {
                            Button {
                                editorTarget = .replace(day: day.day, index: index, activity: activity)
                            } label: {
                                Label("Edit or replace", systemImage: "pencil")
                            }
                            Button {
                                Task { await move(day: day, from: index, to: index - 1) }
                            } label: {
                                Label("Move earlier", systemImage: "arrow.up")
                            }
                            .disabled(index == 0 || lockedActivityIDs.contains(activity.id))
                            Button {
                                Task { await move(day: day, from: index, to: index + 1) }
                            } label: {
                                Label("Move later", systemImage: "arrow.down")
                            }
                            .disabled(index == day.activities.count - 1 || lockedActivityIDs.contains(activity.id))
                            Divider()
                            Button(role: .destructive) {
                                Task { await remove(day: day, index: index) }
                            } label: {
                                Label("Remove stop", systemImage: "trash")
                            }
                            .disabled(lockedActivityIDs.contains(activity.id) || day.activities.count == 1)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                                .frame(width: 38, height: 38)
                        }
                    }
                }
            }

            Button {
                editorTarget = .add(day: day.day)
            } label: {
                Label("Add a stop", systemImage: "plus")
            }
            .buttonStyle(ItineraPrimaryButtonStyle())
        }
    }

    private var historyCard: some View {
        ItineraSurface {
            VStack(alignment: .leading, spacing: 10) {
                ItineraSectionHeading(
                    number: "HISTORY",
                    title: "Revision trail",
                    message: "Every accepted change remains auditable."
                )
                ForEach(history.reversed()) { revision in
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(theme.route)
                        Text("Version \(revision.fromVersion) → \(revision.toVersion)")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(revision.operations.count) changes")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
            }
        }
    }

    private func apply(
        _ operations: [TripRevisionOperation],
        previousDay: ItineraryDay
    ) async {
        guard !operations.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let response = try await appState.reviseTrip(
                jobID: jobID,
                expectedVersion: version,
                operations: operations
            )
            undoStack.append((previousDay.day, previousDay))
            itinerary = response.result
            version = response.toVersion
            history.append(response)
            errorMessage = nil
            onApply(response.result, response.toVersion)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(day: ItineraryDay, index: Int) async {
        await apply(
            [.removeActivity(day: day.day, activityIndex: index)],
            previousDay: day
        )
    }

    private func move(day: ItineraryDay, from: Int, to: Int) async {
        guard day.activities.indices.contains(from), day.activities.indices.contains(to) else { return }
        await apply(
            [.reorderActivity(day: day.day, fromIndex: from, toIndex: to)],
            previousDay: day
        )
    }

    private func makeDayLighter(_ day: ItineraryDay) async {
        guard let index = day.activities.lastIndex(where: { !lockedActivityIDs.contains($0.id) }),
              day.activities.count > 1 else { return }
        await remove(day: day, index: index)
    }

    private func sortDayByTime(_ day: ItineraryDay) async {
        let sorted = day.activities.sorted { $0.time.localizedStandardCompare($1.time) == .orderedAscending }
        guard sorted != day.activities else { return }
        await apply(
            [.regenerateDay(day: day.day, theme: day.theme, activities: sorted)],
            previousDay: day
        )
    }

    private func checkWeather(_ day: ItineraryDay) async {
        guard let first = day.activities.first else { return }
        isCheckingWeather = true
        defer { isCheckingWeather = false }
        do {
            weatherAdvisory = try await TripWeatherService.advisory(for: first)
            errorMessage = nil
        } catch {
            errorMessage = "Live weather isn't available right now. Your itinerary was not changed."
        }
    }

    private func makeWeatherReady(_ day: ItineraryDay) async {
        let unlocked = day.activities
            .filter { !lockedActivityIDs.contains($0.id) }
            .sorted { indoorPriority($0) < indoorPriority($1) }
        var iterator = unlocked.makeIterator()
        let reordered = day.activities.map { activity in
            lockedActivityIDs.contains(activity.id) ? activity : (iterator.next() ?? activity)
        }
        guard reordered != day.activities else { return }
        await apply(
            [.regenerateDay(day: day.day, theme: day.theme, activities: reordered)],
            previousDay: day
        )
    }

    private func indoorPriority(_ activity: Activity) -> Int {
        switch activity.type.lowercased() {
        case "culture", "food", "shopping": 0
        case "nature": 2
        default: 1
        }
    }

    private func saveActivity(_ activity: Activity, target: ActivityEditorTarget) async {
        guard let day else { return }
        switch target {
        case .add:
            await apply(
                [.addActivity(day: day.day, position: nil, activity: activity)],
                previousDay: day
            )
        case .replace(_, let index, _):
            await apply(
                [.replaceActivity(day: day.day, activityIndex: index, activity: activity)],
                previousDay: day
            )
        }
        editorTarget = nil
    }

    private func undo() async {
        guard let previous = undoStack.popLast() else { return }
        guard let current = itinerary.itinerary.first(where: { $0.day == previous.day }) else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let response = try await appState.reviseTrip(
                jobID: jobID,
                expectedVersion: version,
                operations: [
                    .regenerateDay(
                        day: previous.day,
                        theme: previous.snapshot.theme,
                        activities: previous.snapshot.activities
                    )
                ]
            )
            itinerary = response.result
            version = response.toVersion
            history.append(response)
            errorMessage = nil
            onApply(response.result, response.toVersion)
            if current == previous.snapshot { undoStack.removeAll() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleLock(_ activity: Activity) {
        if lockedActivityIDs.contains(activity.id) {
            lockedActivityIDs.remove(activity.id)
        } else {
            lockedActivityIDs.insert(activity.id)
        }
        UserDefaults.standard.set(
            Array(lockedActivityIDs),
            forKey: Self.lockKey(jobID)
        )
    }

    private func loadHistory() async {
        do {
            history = try await appState.apiClient.revisionHistory(jobID)
        } catch {
            // Editing remains available even if the optional history cannot load.
        }
    }

    private static func lockKey(_ jobID: String) -> String {
        ItineraLocalDataKeys.lockedStopsPrefix + jobID
    }
}

private enum ActivityEditorTarget: Identifiable {
    case add(day: Int)
    case replace(day: Int, index: Int, activity: Activity)

    var id: String {
        switch self {
        case .add(let day): "add-\(day)"
        case .replace(let day, let index, _): "replace-\(day)-\(index)"
        }
    }

    var activity: Activity? {
        if case .replace(_, _, let activity) = self { return activity }
        return nil
    }
}

private struct ActivityEditorForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.itineraTheme) private var theme
    let target: ActivityEditorTarget
    let onSave: (Activity) -> Void

    @State private var name: String
    @State private var time: String
    @State private var duration: String
    @State private var type: String
    @State private var description: String
    @State private var selectedLocation: SelectedLocation?
    @State private var isChoosingLocation = false

    init(target: ActivityEditorTarget, onSave: @escaping (Activity) -> Void) {
        self.target = target
        self.onSave = onSave
        let activity = target.activity
        _name = State(initialValue: activity?.name ?? "")
        _time = State(initialValue: activity?.time ?? "09:00")
        _duration = State(initialValue: activity?.duration ?? "1 hr")
        _type = State(initialValue: activity?.type ?? "culture")
        _description = State(initialValue: activity?.description ?? "")
        if let activity {
            _selectedLocation = State(
                initialValue: SelectedLocation(
                    name: activity.name,
                    address: activity.address,
                    city: "",
                    country: "",
                    coordinate: LocationCoordinate(
                        latitude: activity.coordinates.lat,
                        longitude: activity.coordinates.lng
                    )
                )
            )
        } else {
            _selectedLocation = State(initialValue: nil)
        }
    }

    var body: some View {
        Form {
            Section("Place") {
                TextField("Stop name", text: $name)
                Button {
                    isChoosingLocation = true
                } label: {
                    Label(
                        selectedLocation?.homeBaseInputLabel ?? "Find place on map",
                        systemImage: "map"
                    )
                }
            }
            Section("Schedule") {
                TextField("Time (09:00)", text: $time)
                    .keyboardType(.numbersAndPunctuation)
                TextField("Duration", text: $duration)
                Picker("Type", selection: $type) {
                    Text("Culture").tag("culture")
                    Text("Food").tag("food")
                    Text("Nature").tag("nature")
                    Text("Shopping").tag("shopping")
                    Text("Other").tag("other")
                }
                TextField("Why this stop?", text: $description, axis: .vertical)
                    .lineLimit(3...6)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ItineraBackground())
        .navigationTitle(target.activity == nil ? "Add stop" : "Edit stop")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard let selectedLocation else { return }
                    let old = target.activity
                    onSave(
                        Activity(
                            activityId: old?.activityId,
                            time: time,
                            name: name,
                            type: type,
                            duration: duration,
                            description: description,
                            address: selectedLocation.homeBaseInputLabel,
                            coordinates: Coordinates(
                                lat: selectedLocation.coordinate.latitude,
                                lng: selectedLocation.coordinate.longitude
                            ),
                            placeId: old?.placeId,
                            source: old?.source,
                            retrievedAt: old?.retrievedAt,
                            verificationState: old?.verificationState,
                            openingHours: old?.openingHours,
                            phone: old?.phone,
                            websiteUrl: old?.websiteUrl,
                            reservationUrl: old?.reservationUrl,
                            estimatedCost: old?.estimatedCost,
                            accessibilityNotes: old?.accessibilityNotes
                        )
                    )
                }
                .disabled(!isValid)
            }
        }
        .tint(theme.accent)
        .sheet(isPresented: $isChoosingLocation) {
            LocationPickerSheet(
                purpose: .activity,
                initialQuery: name,
                currentSelection: selectedLocation
            ) { selection in
                selectedLocation = selection
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    name = selection.name
                }
            }
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !time.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedLocation != nil
    }
}
