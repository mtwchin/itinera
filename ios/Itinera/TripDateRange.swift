import Foundation
import SwiftUI

struct TripDateRangeSelection: Equatable, Sendable {
    static let maximumTripNights = 7

    enum Phase: Equatable, Sendable {
        case empty
        case choosingEnd
        case complete
    }

    enum Result: Equatable, Sendable {
        case selectedStart
        case completed
        case rejectedPast
        case rejectedTooLong
    }

    private(set) var start: Date?
    private(set) var end: Date?

    init(start: Date? = nil, end: Date? = nil, calendar: Calendar = .current) {
        self.start = start.map(calendar.startOfDay(for:))
        self.end = end.map(calendar.startOfDay(for:))
        if let start = self.start, let end = self.end,
           !Self.isValid(start: start, end: end, calendar: calendar) {
            self.end = nil
        }
    }

    var phase: Phase {
        guard start != nil else { return .empty }
        return end == nil ? .choosingEnd : .complete
    }

    mutating func select(
        _ date: Date,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> Result {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: today)
        guard day >= today else { return .rejectedPast }

        guard phase == .choosingEnd, let start else {
            self.start = day
            end = nil
            return .selectedStart
        }

        guard day > start else {
            self.start = day
            end = nil
            return .selectedStart
        }

        guard let latest = calendar.date(
            byAdding: .day,
            value: Self.maximumTripNights,
            to: start
        ),
              day <= latest else {
            return .rejectedTooLong
        }

        end = day
        return .completed
    }

    func selectedDateComponents(calendar: Calendar = .current) -> Set<DateComponents> {
        guard let start else { return [] }
        let final = end ?? start
        var cursor = start
        var result = Set<DateComponents>()

        while cursor <= final {
            let values = calendar.dateComponents([.year, .month, .day], from: cursor)
            result.insert(DateComponents(year: values.year, month: values.month, day: values.day))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    static func isValid(start: Date, end: Date, calendar: Calendar = .current) -> Bool {
        let normalizedStart = calendar.startOfDay(for: start)
        let normalizedEnd = calendar.startOfDay(for: end)
        let nights = calendar.dateComponents(
            [.day], from: normalizedStart, to: normalizedEnd
        ).day ?? 0
        return nights >= 1 && nights <= maximumTripNights
    }
}

@MainActor
struct TripDateRangePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.itineraTheme) private var theme
    @Binding private var start: Date
    @Binding private var end: Date

    @State private var draft: TripDateRangeSelection
    @State private var selectedDates = Set<DateComponents>()
    @State private var programmaticSelection: Set<DateComponents>?
    @State private var message: String?

    init(start: Binding<Date>, end: Binding<Date>) {
        _start = start
        _end = end
        let initialDraft = TripDateRangeSelection(start: start.wrappedValue, end: end.wrappedValue)
        _draft = State(initialValue: initialDraft)
        _selectedDates = State(initialValue: initialDraft.selectedDateComponents())
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(instructionTitle)
                        .font(.headline)
                        .foregroundStyle(theme.primaryText)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: draft.phase)
                    Text(rangeDescription)
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryText)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: draft.phase)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                MultiDatePicker(
                    "Trip dates",
                    selection: $selectedDates,
                    in: Calendar.current.startOfDay(for: Date())...
                )
                .labelsHidden()
                .tint(theme.accent)
                .onChange(of: selectedDates) { oldValue, newValue in
                    handleSelectionChange(from: oldValue, to: newValue)
                }

                if let message {
                    ItineraStatusBanner(message: message, kind: .error)
                }

                Button("Use these dates") {
                    guard let draftStart = draft.start, let draftEnd = draft.end else { return }
                    start = draftStart
                    end = draftEnd
                    dismiss()
                }
                .buttonStyle(ItineraPrimaryButtonStyle())
                .disabled(draft.phase != .complete)
                .opacity(draft.phase == .complete ? 1 : 0.48)
                .animation(.easeInOut(duration: 0.25), value: draft.phase == .complete)

                Spacer(minLength: 0)
            }
            .padding(18)
            .background(ItineraBackground())
            .navigationTitle("Trip dates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var instructionTitle: String {
        switch draft.phase {
        case .empty: "Tap your arrival date"
        case .choosingEnd: "Now tap your departure date"
        case .complete: "Dates ready — tap again to start over"
        }
    }

    private var rangeDescription: String {
        guard let start = draft.start else {
            return "Choose today or later. Beta trips can be up to 7 days."
        }
        guard let end = draft.end else {
            return "Arrive \(start.formatted(date: .abbreviated, time: .omitted))"
        }
        let nights = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
        return "\(start.formatted(date: .abbreviated, time: .omitted)) → \(end.formatted(date: .abbreviated, time: .omitted)) · \(nights) nights"
    }

    private func handleSelectionChange(
        from oldValue: Set<DateComponents>,
        to newValue: Set<DateComponents>
    ) {
        if let programmaticSelection, newValue == programmaticSelection {
            self.programmaticSelection = nil
            return
        }

        let changed = newValue.subtracting(oldValue).first
            ?? oldValue.subtracting(newValue).first
        guard let changed, let date = Calendar.current.date(from: changed) else { return }

        switch draft.select(date) {
        case .selectedStart:
            message = nil
        case .completed:
            message = nil
        case .rejectedPast:
            message = "Choose today or a future date."
        case .rejectedTooLong:
            message = "Beta trips can be no longer than 7 days. Choose an earlier departure."
        }

        let normalized = draft.selectedDateComponents()
        if selectedDates != normalized {
            programmaticSelection = normalized
            selectedDates = normalized
        }
    }
}
