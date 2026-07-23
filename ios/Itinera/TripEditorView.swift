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
    @State private var didEditLocks = false
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
        initialDay: Int? = nil,
        onApply: @escaping (Itinerary, Int) -> Void
    ) {
        self.jobID = jobID
        self.tripTitle = tripTitle
        self.onApply = onApply
        _itinerary = State(initialValue: itinerary)
        _version = State(initialValue: version)
        let resolvedInitialDay = initialDay.flatMap { requestedDay in
            itinerary.itinerary.contains { $0.day == requestedDay }
                ? requestedDay
                : nil
        }
        _selectedDay = State(
            initialValue: resolvedInitialDay
                ?? itinerary.itinerary.first?.day
                ?? 1
        )
        _lockedActivityIDs = State(initialValue: [])
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
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isWorking)
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
        .task {
            let storedLocks = await appState.loadLockedActivityIDs(jobID: jobID)
            if !didEditLocks {
                lockedActivityIDs = storedLocks
            }
            await loadHistory()
        }
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
            HStack(spacing: 10) {
                ForEach(itinerary.itinerary) { day in
                    Button {
                        withAnimation(.snappy) { selectedDay = day.day }
                    } label: {
                        Text("Day \(day.day)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(
                                selectedDay == day.day
                                    ? theme.accentContrast
                                    : theme.primaryText
                            )
                            .padding(.horizontal, 16)
                            .frame(minHeight: 44)
                            .background(
                                selectedDay == day.day ? theme.accent : theme.surface,
                                in: Capsule()
                            )
                            .overlay {
                                if selectedDay != day.day {
                                    Capsule().stroke(theme.border, lineWidth: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedDay == day.day ? .isSelected : [])
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selectedDay)
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
                        message: "\(weatherAdvisory.summary) · \(weatherAdvisory.temperature) · \(Int((weatherAdvisory.precipitationChance * 100).rounded()))% rain",
                        kind: weatherAdvisory.recommendsIndoorPlan ? .warning : .success
                    )
                    if weatherAdvisory.recommendsIndoorPlan {
                        Button {
                            Task { await makeWeatherReady(day) }
                        } label: {
                            Label("Move indoor stops earlier", systemImage: "cloud.rain")
                        }
                        .buttonStyle(ItineraPrimaryButtonStyle())
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
                            Label {
                                Text("\(activity.time) · \(activity.duration)")
                                    .monospacedDigit()
                            } icon: {
                                Image(systemName: "clock")
                            }
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                            Text(activity.address)
                                .font(.caption)
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 0)

                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                toggleLock(activity)
                            }
                        } label: {
                            Image(systemName: lockedActivityIDs.contains(activity.id) ? "lock.fill" : "lock.open")
                                .scaleEffect(lockedActivityIDs.contains(activity.id) ? 1.15 : 1)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(lockedActivityIDs.contains(activity.id) ? theme.highlightStrong : theme.secondaryText)
                        .sensoryFeedback(.selection, trigger: lockedActivityIDs.contains(activity.id))
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
                                .frame(width: 44, height: 44)
                        }
                    }
                }
                .revealOnAppear()
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
                    message: "Every accepted change is auditable."
                )
                VStack(spacing: 0) {
                    ForEach(Array(history.reversed().enumerated()), id: \.element.id) { idx, revision in
                        VStack(alignment: .leading, spacing: 0) {
                            if idx > 0 {
                                Divider().padding(.vertical, 8)
                            }
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: idx == 0 ? "checkmark.seal.fill" : "clock.arrow.circlepath")
                                    .foregroundStyle(idx == 0 ? theme.success : theme.route)
                                    .frame(width: 28, height: 28)
                                    .background(
                                        (idx == 0 ? theme.success : theme.route).opacity(0.10),
                                        in: Circle()
                                    )

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text("v\(revision.toVersion)")
                                            .font(.subheadline.weight(.bold))
                                            .foregroundStyle(theme.primaryText)
                                        if idx == 0 {
                                            Text("CURRENT")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(theme.success)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(theme.success.opacity(0.12), in: Capsule())
                                        }
                                    }
                                    Text(revisionSummary(revision.operations))
                                        .font(.caption)
                                        .foregroundStyle(theme.secondaryText)
                                }

                                Spacer(minLength: 0)

                                Text(formatRevisionDate(revision.createdAt))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(theme.secondaryText)
                            }
                        }
                    }
                }
            }
        }
    }

    private func revisionSummary(_ operations: [[String: JSONValue]]) -> String {
        var counts: [String: Int] = [:]
        for op in operations {
            if case .string(let type) = op["type"] {
                counts[type, default: 0] += 1
            }
        }
        let parts: [String] = counts.sorted { $0.value > $1.value }.compactMap { type, count in
            switch type {
            case "add_activity":    return count == 1 ? "Added 1 stop" : "Added \(count) stops"
            case "remove_activity": return count == 1 ? "Removed 1 stop" : "Removed \(count) stops"
            case "reorder_activity": return "Reordered stops"
            case "replace_activity": return count == 1 ? "Replaced 1 stop" : "Replaced \(count) stops"
            case "regenerate_day":  return "Regenerated day"
            default: return nil
            }
        }
        return parts.isEmpty
            ? "\(operations.count) \(operations.count == 1 ? "change" : "changes")"
            : parts.joined(separator: " · ")
    }

    private func formatRevisionDate(_ createdAt: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: createdAt) ?? ISO8601DateFormatter().date(from: createdAt)
        guard let date else { return "" }
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        fmt.dateStyle = .none
        return fmt.string(from: date)
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
        didEditLocks = true
        if lockedActivityIDs.contains(activity.id) {
            lockedActivityIDs.remove(activity.id)
        } else {
            lockedActivityIDs.insert(activity.id)
        }
        let ids = lockedActivityIDs
        Task { await appState.saveLockedActivityIDs(ids, jobID: jobID) }
    }

    private func loadHistory() async {
        do {
            history = try await appState.apiClient.revisionHistory(jobID)
        } catch {
            // Editing remains available even if the optional history cannot load.
        }
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
        ZStack {
            ItineraBackground()

            ScrollView {
                VStack(spacing: 18) {
                    ItineraSurface {
                        VStack(alignment: .leading, spacing: 14) {
                            ItineraSectionHeading(number: "01", title: "Place", message: nil)

                            TextField("Stop name", text: $name)
                                .itineraField()
                                .accessibilityLabel("Stop name")

                            Button {
                                isChoosingLocation = true
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "map")
                                        .foregroundStyle(theme.accent)
                                    Text(selectedLocation?.homeBaseInputLabel ?? "Find place on map")
                                        .foregroundStyle(selectedLocation == nil ? theme.secondaryText : theme.primaryText)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(theme.secondaryText)
                                }
                                .contentShape(Rectangle())
                                .frame(minHeight: 50)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(selectedLocation == nil ? "Find place on map" : "Location: \(selectedLocation!.homeBaseInputLabel)")
                        }
                    }

                    ItineraSurface {
                        VStack(alignment: .leading, spacing: 14) {
                            ItineraSectionHeading(number: "02", title: "Schedule", message: nil)

                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Time")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(theme.secondaryText)
                                    TextField("09:00", text: $time)
                                        .keyboardType(.numbersAndPunctuation)
                                        .itineraField()
                                }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Duration")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(theme.secondaryText)
                                    TextField("1 hr", text: $duration)
                                        .itineraField()
                                }
                            }

                            VStack(alignment: .leading, spacing: 9) {
                                Text("Stop type")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(theme.secondaryText)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(Self.activityTypes, id: \.0) { typeValue, typeLabel in
                                            Button {
                                                withAnimation(.snappy) { type = typeValue }
                                            } label: {
                                                Text(typeLabel)
                                                    .font(.subheadline.weight(type == typeValue ? .semibold : .regular))
                                                    .foregroundStyle(type == typeValue ? .white : theme.primaryText)
                                                    .padding(.horizontal, 14)
                                                    .padding(.vertical, 8)
                                                    .background(
                                                        type == typeValue ? theme.accent : theme.accent.opacity(0.09),
                                                        in: Capsule()
                                                    )
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel("Type: \(typeLabel)")
                                            .accessibilityAddTraits(type == typeValue ? .isSelected : [])
                                        }
                                    }
                                    .padding(.horizontal, 1)
                                }
                                .sensoryFeedback(.selection, trigger: type)
                            }

                            VStack(alignment: .leading, spacing: 5) {
                                Text("Why this stop?")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(theme.secondaryText)
                                TextField("A description of this stop", text: $description, axis: .vertical)
                                    .lineLimit(3...6)
                                    .itineraField()
                            }
                        }
                    }
                }
                .padding(18)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle(target.activity == nil ? "Add stop" : "Edit stop")
        .navigationBarTitleDisplayMode(.inline)
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

    private static let activityTypes: [(String, String)] = [
        ("culture", "Culture"),
        ("food", "Food"),
        ("nature", "Nature"),
        ("shopping", "Shopping"),
        ("other", "Other")
    ]

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !time.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedLocation != nil
    }
}
