import Foundation
import UIKit
import UserNotifications

struct GenerationNotificationContent: Equatable, Sendable {
    let title: String
    let body: String
    let userInfo: [String: String]

    static func tripReady(jobID: String, tripTitle: String?) -> GenerationNotificationContent {
        let cleanTitle = tripTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return GenerationNotificationContent(
            title: "Your trip is ready",
            body: cleanTitle.flatMap { $0.isEmpty ? nil : "\($0) is ready to explore." }
                ?? "Open Itinera to explore your new route.",
            userInfo: [
                "itinera_destination": "trip",
                "itinera_job_id": jobID,
            ]
        )
    }

    static func generationFailed(jobID: String) -> GenerationNotificationContent {
        GenerationNotificationContent(
            title: "Your trip needs attention",
            body: "Itinera could not finish this route. Open the app to try again.",
            userInfo: [
                "itinera_destination": "trip",
                "itinera_job_id": jobID,
            ]
        )
    }
}

@MainActor
final class GenerationNotificationManager {
    static let shared = GenerationNotificationManager()

    private static let identifierPrefix = "com.itinera.generation."
    private static let reminderPrefix = "com.itinera.reminder."
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorization() async throws -> Bool {
        let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
        if granted {
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
        return granted
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func notifyTripReady(jobID: String, title: String?) async throws {
        try await add(
            GenerationNotificationContent.tripReady(jobID: jobID, tripTitle: title),
            identifier: Self.identifier(for: jobID)
        )
    }

    func notifyGenerationFailed(jobID: String) async throws {
        try await add(
            GenerationNotificationContent.generationFailed(jobID: jobID),
            identifier: Self.identifier(for: jobID)
        )
    }

    func removeNotification(for jobID: String) {
        let identifiers = [Self.identifier(for: jobID)]
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func removeAllItineraNotifications() async {
        let pending = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter(Self.isItineraNotificationIdentifier)
        let delivered = await center.deliveredNotifications()
            .map { $0.request.identifier }
            .filter(Self.isItineraNotificationIdentifier)
        center.removePendingNotificationRequests(withIdentifiers: pending)
        center.removeDeliveredNotifications(withIdentifiers: delivered)
    }

    static func isItineraNotificationIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix(identifierPrefix)
            || identifier.hasPrefix(reminderPrefix)
    }

    func scheduleTripReminders(for trips: [SavedItinerary]) async throws {
        let existing = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.reminderPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: existing)

        var requests: [UNNotificationRequest] = []
        for trip in trips where requests.count < 48 {
            guard let itinerary = trip.result else { continue }
            var calendar = Calendar(identifier: .gregorian)
            if let identifier = itinerary.timeZoneIdentifier,
               let timeZone = TimeZone(identifier: identifier) {
                calendar.timeZone = timeZone
            }

            for day in itinerary.itinerary {
                guard requests.count < 48 else { break }
                let dateString = day.date ?? trip.arrivalDate
                guard let dayDate = TripLibraryOrganizer.localDate(
                    dateString,
                    calendar: calendar
                ) else { continue }

                for activity in day.activities.prefix(8) {
                    guard requests.count < 48,
                          let activityDate = Self.activityDate(
                            activity.time,
                            on: dayDate,
                            calendar: calendar
                          ),
                          let reminderDate = calendar.date(
                            byAdding: .minute,
                            value: -15,
                            to: activityDate
                          ),
                          reminderDate > Date() else { continue }

                    let content = UNMutableNotificationContent()
                    content.title = "Leave soon for \(activity.name)"
                    content.body = "Your next Itinera stop starts at \(activity.time)."
                    content.sound = .default
                    content.userInfo = [
                        "itinera_destination": "trip",
                        "itinera_job_id": trip.jobId,
                    ]
                    let components = calendar.dateComponents(
                        [.year, .month, .day, .hour, .minute, .timeZone],
                        from: reminderDate
                    )
                    requests.append(
                        UNNotificationRequest(
                            identifier: Self.reminderPrefix + trip.jobId + "." + activity.id,
                            content: content,
                            trigger: UNCalendarNotificationTrigger(
                                dateMatching: components,
                                repeats: false
                            )
                        )
                    )
                }
            }
        }

        for request in requests {
            try await center.add(request)
        }
    }

    private func add(
        _ notification: GenerationNotificationContent,
        identifier: String
    ) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.userInfo = notification.userInfo

        // A one-second trigger reliably presents while the app transitions to the background.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        try await center.add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        )
    }

    private static func identifier(for jobID: String) -> String {
        identifierPrefix + jobID
    }

    private static func activityDate(
        _ value: String,
        on day: Date,
        calendar: Calendar
    ) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        for format in ["HH:mm", "H:mm", "h:mm a", "h a"] {
            formatter.dateFormat = format
            if let time = formatter.date(from: value) {
                let parts = calendar.dateComponents([.hour, .minute], from: time)
                return calendar.date(
                    bySettingHour: parts.hour ?? 9,
                    minute: parts.minute ?? 0,
                    second: 0,
                    of: day
                )
            }
        }
        return nil
    }
}
