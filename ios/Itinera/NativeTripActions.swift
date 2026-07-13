import EventKit
import Foundation
import SwiftUI

struct CalendarItineraryEvent: Equatable, Sendable {
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String
    let notes: String
}

enum CalendarExportError: LocalizedError, Equatable {
    case accessDenied
    case invalidStartDate
    case noActivities
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Calendar access is off. Allow Itinera to add events in iOS Settings."
        case .invalidStartDate:
            return "This trip does not have a valid start date."
        case .noActivities:
            return "This itinerary does not contain activities to export."
        case .saveFailed:
            return "The itinerary could not be added to Calendar."
        }
    }
}

enum ItineraryCalendarPlanner {
    static func makeEvents(
        itinerary: Itinerary,
        tripStartDate: Date,
        timeZone: TimeZone = .current,
        calendar: Calendar = .current
    ) -> [CalendarItineraryEvent] {
        var calendar = calendar
        calendar.timeZone = timeZone
        let firstDay = calendar.startOfDay(for: tripStartDate)

        return itinerary.itinerary.flatMap { day -> [CalendarItineraryEvent] in
            guard let date = calendar.date(byAdding: .day, value: max(0, day.day - 1), to: firstDay) else {
                return []
            }

            return day.activities.compactMap { activity in
                guard let start = activityDate(
                    on: date,
                    from: activity.time,
                    calendar: calendar,
                    timeZone: timeZone
                ) else { return nil }

                let duration = durationInMinutes(activity.duration) ?? 60
                let end = calendar.date(byAdding: .minute, value: duration, to: start)
                    ?? start.addingTimeInterval(TimeInterval(duration * 60))
                let notes = [activity.description, "Day \(day.day): \(day.theme)"]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")

                return CalendarItineraryEvent(
                    title: activity.name,
                    startDate: start,
                    endDate: end,
                    location: activity.address,
                    notes: notes
                )
            }
        }
    }

    static func durationInMinutes(_ value: String) -> Int? {
        let lowercased = value.lowercased()
        let number = lowercased
            .split(whereSeparator: { !$0.isNumber && $0 != "." })
            .compactMap { Double($0) }
            .first

        guard let number, number > 0 else { return nil }
        if lowercased.contains("hour") || lowercased.contains(" hr") {
            return Int((number * 60).rounded())
        }
        if lowercased.contains("min") {
            return Int(number.rounded())
        }
        return nil
    }

    private static func activityDate(
        on day: Date,
        from time: String,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> Date? {
        let formats = ["h:mm a", "h a", "HH:mm", "H:mm"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: time.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                continue
            }
            let components = calendar.dateComponents([.hour, .minute], from: parsed)
            return calendar.date(bySettingHour: components.hour ?? 9, minute: components.minute ?? 0, second: 0, of: day)
        }
        return nil
    }
}

@MainActor
final class ItineraryCalendarExporter {
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    /// Requests write-only access so Itinera never needs to read the user's calendar.
    func export(
        itinerary: Itinerary,
        tripStartDate: Date,
        calendarTitle: String? = nil
    ) async throws -> Int {
        let granted = try await requestWriteAccessIfNeeded()
        guard granted else { throw CalendarExportError.accessDenied }

        let events = ItineraryCalendarPlanner.makeEvents(
            itinerary: itinerary,
            tripStartDate: tripStartDate
        )
        guard !events.isEmpty else { throw CalendarExportError.noActivities }

        let calendar = eventStore.defaultCalendarForNewEvents
        for item in events {
            let event = EKEvent(eventStore: eventStore)
            event.calendar = calendar
            event.title = calendarTitle.map { "\(item.title) — \($0)" } ?? item.title
            event.startDate = item.startDate
            event.endDate = item.endDate
            event.location = item.location
            event.notes = item.notes
            do {
                try eventStore.save(event, span: .thisEvent, commit: false)
            } catch {
                eventStore.reset()
                throw CalendarExportError.saveFailed
            }
        }

        do {
            try eventStore.commit()
            return events.count
        } catch {
            eventStore.reset()
            throw CalendarExportError.saveFailed
        }
    }

    private func requestWriteAccessIfNeeded() async throws -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .writeOnly:
            return true
        case .notDetermined:
            return try await eventStore.requestWriteOnlyAccessToEvents()
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

struct ItinerarySharePayload: Equatable, Sendable {
    let title: String
    let text: String

    static func make(
        itinerary: Itinerary,
        tripTitle: String,
        dateRange: String? = nil
    ) -> ItinerarySharePayload {
        var lines = [tripTitle]
        if let dateRange, !dateRange.isEmpty {
            lines.append(dateRange)
        }
        lines.append("")

        for day in itinerary.itinerary {
            lines.append("Day \(day.day) — \(day.theme)")
            for activity in day.activities {
                lines.append("\(activity.time) · \(activity.name)")
                if !activity.address.isEmpty {
                    lines.append("  \(activity.address)")
                }
            }
            lines.append("")
        }

        if !itinerary.estimatedBudget.isEmpty {
            lines.append("Estimated budget: \(itinerary.estimatedBudget)")
        }
        lines.append("Planned with Itinera")

        return ItinerarySharePayload(
            title: tripTitle,
            text: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

struct ItineraryShareButton: View {
    let itinerary: Itinerary
    let tripTitle: String
    var dateRange: String?

    var body: some View {
        let payload = ItinerarySharePayload.make(
            itinerary: itinerary,
            tripTitle: tripTitle,
            dateRange: dateRange
        )
        ShareLink(
            item: payload.text,
            subject: Text(payload.title),
            message: Text("Here is my Itinera route.")
        ) {
            Label("Share itinerary", systemImage: "square.and.arrow.up")
        }
        .accessibilityHint("Opens the iOS share sheet")
    }
}
