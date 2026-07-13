import Foundation
import UserNotifications

enum GenerationNotificationMetadata {
    static let destinationKey = "itinera_destination"
    static let jobIDKey = "itinera_job_id"
    static let principalScopeKey = "itinera_principal_scope"
    static let presentationSessionKey = "itinera_presentation_session"

    static func userInfo(
        jobID: String,
        session: PrivatePresentationSession
    ) -> [String: String] {
        [
            destinationKey: "trip",
            jobIDKey: jobID,
            principalScopeKey: session.scope.digest,
            presentationSessionKey: session.id.uuidString.lowercased(),
        ]
    }

    static func presentationSession(
        from userInfo: [AnyHashable: Any]
    ) -> PrivatePresentationSession? {
        guard
            userInfo[destinationKey] as? String == "trip",
            let jobID = userInfo[jobIDKey] as? String,
            !jobID.isEmpty,
            let digest = userInfo[principalScopeKey] as? String,
            let sessionValue = userInfo[presentationSessionKey] as? String,
            let scope = try? PrincipalScope(validating: digest),
            let id = UUID(uuidString: sessionValue)
        else {
            return nil
        }
        return PrivatePresentationSession(scope: scope, id: id)
    }

    static func belongs(
        _ userInfo: [AnyHashable: Any],
        to expectedSession: PrivatePresentationSession
    ) -> Bool {
        presentationSession(from: userInfo) == expectedSession
    }
}

struct GenerationNotificationContent: Equatable, Sendable {
    let title: String
    let body: String
    let userInfo: [String: String]

    static func tripReady(
        jobID: String,
        tripTitle: String?,
        session: PrivatePresentationSession
    ) -> GenerationNotificationContent {
        let cleanTitle = tripTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return GenerationNotificationContent(
            title: "Your trip is ready",
            body: cleanTitle.flatMap { $0.isEmpty ? nil : "\($0) is ready to explore." }
                ?? "Open Itinera to explore your new route.",
            userInfo: GenerationNotificationMetadata.userInfo(
                jobID: jobID,
                session: session
            )
        )
    }

    static func generationFailed(
        jobID: String,
        session: PrivatePresentationSession
    ) -> GenerationNotificationContent {
        GenerationNotificationContent(
            title: "Your trip needs attention",
            body: "Itinera could not finish this route. Open the app to try again.",
            userInfo: GenerationNotificationMetadata.userInfo(
                jobID: jobID,
                session: session
            )
        )
    }

    static func tripReminder(
        jobID: String,
        activityName: String,
        activityTime: String,
        session: PrivatePresentationSession
    ) -> GenerationNotificationContent {
        GenerationNotificationContent(
            title: "Leave soon for \(activityName)",
            body: "Your next Itinera stop starts at \(activityTime).",
            userInfo: GenerationNotificationMetadata.userInfo(
                jobID: jobID,
                session: session
            )
        )
    }
}

@MainActor
protocol UserNotificationCenterServing: AnyObject {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func notificationSettings() async -> UNNotificationSettings
    func add(_ request: UNNotificationRequest) async throws
    func pendingNotificationRequests() async -> [UNNotificationRequest]
    func deliveredNotificationRequests() async -> [UNNotificationRequest]
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: UserNotificationCenterServing {
    func deliveredNotificationRequests() async -> [UNNotificationRequest] {
        await deliveredNotifications().map(\.request)
    }
}

struct NotificationSurfaceInvalidation: Equatable, Sendable {
    let throughGeneration: UInt64
}

@MainActor
protocol GenerationNotificationSurfaceManaging: AnyObject {
    func establishActiveSession(_ session: PrivatePresentationSession)
    @discardableResult
    func invalidateActiveSession() -> NotificationSurfaceInvalidation
    func drainInFlightAdds(
        capturedBefore invalidation: NotificationSurfaceInvalidation
    ) async
    func removeOldAndUnscopedNotifications() async
    func hasOldOrUnscopedNotifications() async -> Bool
}

@MainActor
final class GenerationNotificationManager: GenerationNotificationSurfaceManaging {
    static let shared = GenerationNotificationManager()

    private struct SessionLease: Equatable {
        let session: PrivatePresentationSession
        let generation: UInt64
    }

    private struct AddDrainWaiter {
        let throughGeneration: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    nonisolated private static let identifierPrefix = "com.itinera.generation."
    nonisolated private static let reminderPrefix = "com.itinera.reminder."
    nonisolated private static let scopedVersionComponent = "v2"

    private let center: any UserNotificationCenterServing
    private let now: @Sendable () -> Date
    private let onInFlightDrainSuspended: @MainActor () -> Void
    private var activeSession: PrivatePresentationSession?
    private var generation: UInt64 = 0
    private var inFlightAddCounts: [UInt64: Int] = [:]
    private var addDrainWaiters: [AddDrainWaiter] = []

    init(
        center: any UserNotificationCenterServing = UNUserNotificationCenter.current(),
        now: @escaping @Sendable () -> Date = { Date() },
        onInFlightDrainSuspended: @escaping @MainActor () -> Void = {}
    ) {
        self.center = center
        self.now = now
        self.onInFlightDrainSuspended = onInFlightDrainSuspended
    }

    func establishActiveSession(_ session: PrivatePresentationSession) {
        guard activeSession != session else { return }
        advanceGeneration()
        activeSession = generation == .max ? nil : session
    }

    @discardableResult
    func invalidateActiveSession() -> NotificationSurfaceInvalidation {
        let invalidation = NotificationSurfaceInvalidation(
            throughGeneration: generation
        )
        advanceGeneration()
        activeSession = nil
        return invalidation
    }

    /// Waits for every notification-center add that captured a lease before
    /// invalidation. Adds from a subsequently established session have a newer
    /// generation and cannot extend this privacy barrier.
    func drainInFlightAdds(
        capturedBefore invalidation: NotificationSurfaceInvalidation
    ) async {
        guard hasInFlightAdd(through: invalidation.throughGeneration) else {
            return
        }
        await withCheckedContinuation { continuation in
            addDrainWaiters.append(
                AddDrainWaiter(
                    throughGeneration: invalidation.throughGeneration,
                    continuation: continuation
                )
            )
            onInFlightDrainSuspended()
        }
    }

    func isCurrent(_ session: PrivatePresentationSession) -> Bool {
        activeSession == session
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func notifyTripReady(
        jobID: String,
        title: String?,
        expectedSession: PrivatePresentationSession
    ) async throws {
        let lease = try captureLease(expectedSession: expectedSession)
        try await add(
            GenerationNotificationContent.tripReady(
                jobID: jobID,
                tripTitle: title,
                session: expectedSession
            ),
            identifier: Self.identifier(for: jobID, session: expectedSession),
            lease: lease
        )
    }

    func notifyGenerationFailed(
        jobID: String,
        expectedSession: PrivatePresentationSession
    ) async throws {
        let lease = try captureLease(expectedSession: expectedSession)
        try await add(
            GenerationNotificationContent.generationFailed(
                jobID: jobID,
                session: expectedSession
            ),
            identifier: Self.identifier(for: jobID, session: expectedSession),
            lease: lease
        )
    }

    func removeNotification(
        for jobID: String,
        expectedSession: PrivatePresentationSession
    ) {
        let identifiers = [Self.identifier(for: jobID, session: expectedSession)]
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// Removes all Itinera notifications except those owned by the session that
    /// is active after the asynchronous queries finish. Legacy identifiers are
    /// unscoped and are therefore always removed.
    func removeOldAndUnscopedNotifications() async {
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotificationRequests()
        let sessionToKeep = activeSession
        let pendingIDs = pending.filter {
            Self.shouldRemove(
                identifier: $0.identifier,
                userInfo: $0.content.userInfo,
                keeping: sessionToKeep
            )
        }.map(\.identifier)
        let deliveredIDs = delivered.filter {
            Self.shouldRemove(
                identifier: $0.identifier,
                userInfo: $0.content.userInfo,
                keeping: sessionToKeep
            )
        }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
        center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
    }

    /// Verifies the notification-center state independently after removal.
    /// When there is no active presentation session, every Itinera request is
    /// private content that must be absent before another library can publish.
    func hasOldOrUnscopedNotifications() async -> Bool {
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotificationRequests()
        let sessionToKeep = activeSession
        return pending.contains {
            Self.shouldRemove(
                identifier: $0.identifier,
                userInfo: $0.content.userInfo,
                keeping: sessionToKeep
            )
        } || delivered.contains {
            Self.shouldRemove(
                identifier: $0.identifier,
                userInfo: $0.content.userInfo,
                keeping: sessionToKeep
            )
        }
    }

    func removeAllItineraNotifications() async {
        let pending = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter(Self.isItineraNotificationIdentifier)
        let delivered = await center.deliveredNotificationRequests()
            .map(\.identifier)
            .filter(Self.isItineraNotificationIdentifier)
        center.removePendingNotificationRequests(withIdentifiers: pending)
        center.removeDeliveredNotifications(withIdentifiers: delivered)
    }

    nonisolated static func isItineraNotificationIdentifier(
        _ identifier: String
    ) -> Bool {
        identifier.hasPrefix(identifierPrefix)
            || identifier.hasPrefix(reminderPrefix)
    }

    nonisolated static func presentationSession(
        from identifier: String
    ) -> PrivatePresentationSession? {
        let prefix: String
        if identifier.hasPrefix(identifierPrefix) {
            prefix = identifierPrefix
        } else if identifier.hasPrefix(reminderPrefix) {
            prefix = reminderPrefix
        } else {
            return nil
        }

        let suffix = identifier.dropFirst(prefix.count)
        let components = suffix.split(separator: ".", omittingEmptySubsequences: false)
        guard
            components.count >= 4,
            components[0] == Substring(scopedVersionComponent),
            let scope = try? PrincipalScope(validating: String(components[1])),
            let id = UUID(uuidString: String(components[2]))
        else {
            return nil
        }
        return PrivatePresentationSession(scope: scope, id: id)
    }

    nonisolated static func presentationSession(
        from identifier: String,
        userInfo: [AnyHashable: Any]
    ) -> PrivatePresentationSession? {
        guard
            let identifierSession = presentationSession(from: identifier),
            let metadataSession = GenerationNotificationMetadata
                .presentationSession(from: userInfo),
            identifierSession == metadataSession,
            let jobID = userInfo[GenerationNotificationMetadata.jobIDKey] as? String
        else {
            return nil
        }
        let isGenerationIdentifier = identifier == Self.identifier(
            for: jobID,
            session: identifierSession
        )
        let reminderJobPrefix = scopedIdentifierPrefix(
            base: reminderPrefix,
            session: identifierSession
        ) + jobID + "."
        let isReminderIdentifier = identifier.hasPrefix(reminderJobPrefix)
            && identifier.count > reminderJobPrefix.count
        guard isGenerationIdentifier || isReminderIdentifier else {
            return nil
        }
        return identifierSession
    }

    nonisolated static func identifier(
        for jobID: String,
        session: PrivatePresentationSession
    ) -> String {
        scopedIdentifierPrefix(
            base: identifierPrefix,
            session: session
        ) + jobID
    }

    nonisolated static func reminderIdentifier(
        jobID: String,
        activityID: String,
        session: PrivatePresentationSession
    ) -> String {
        scopedIdentifierPrefix(
            base: reminderPrefix,
            session: session
        ) + jobID + "." + activityID
    }

    func scheduleTripReminders(
        for trips: [SavedItinerary],
        expectedSession: PrivatePresentationSession
    ) async throws {
        let lease = try captureLease(expectedSession: expectedSession)
        let existing = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter {
                $0.hasPrefix(Self.reminderPrefix)
                    && Self.presentationSession(from: $0) == expectedSession
            }
        try validate(lease)
        center.removePendingNotificationRequests(withIdentifiers: existing)

        let requests = Self.reminderRequests(
            for: trips,
            session: expectedSession,
            now: now()
        )
        var addedIdentifiers: [String] = []
        do {
            for request in requests {
                try await addRequest(request, lease: lease)
                addedIdentifiers.append(request.identifier)
            }
        } catch {
            removeRequests(withIdentifiers: addedIdentifiers)
            throw error
        }
    }

    private func add(
        _ notification: GenerationNotificationContent,
        identifier: String,
        lease: SessionLease
    ) async throws {
        try validate(lease)
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.userInfo = notification.userInfo

        // A one-second trigger reliably presents while the app transitions to the background.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        try await addRequest(
            UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: trigger
            ),
            lease: lease
        )
    }

    private static func reminderRequests(
        for trips: [SavedItinerary],
        session: PrivatePresentationSession,
        now: Date
    ) -> [UNNotificationRequest] {
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
                          let activityDate = activityDate(
                            activity.time,
                            on: dayDate,
                            calendar: calendar
                          ),
                          let reminderDate = calendar.date(
                            byAdding: .minute,
                            value: -15,
                            to: activityDate
                          ),
                          reminderDate > now else { continue }

                    let descriptor = GenerationNotificationContent.tripReminder(
                        jobID: trip.jobId,
                        activityName: activity.name,
                        activityTime: activity.time,
                        session: session
                    )
                    let content = UNMutableNotificationContent()
                    content.title = descriptor.title
                    content.body = descriptor.body
                    content.sound = .default
                    content.userInfo = descriptor.userInfo
                    let components = calendar.dateComponents(
                        [.year, .month, .day, .hour, .minute, .timeZone],
                        from: reminderDate
                    )
                    requests.append(
                        UNNotificationRequest(
                            identifier: reminderIdentifier(
                                jobID: trip.jobId,
                                activityID: activity.id,
                                session: session
                            ),
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
        return requests
    }

    nonisolated private static func scopedIdentifierPrefix(
        base: String,
        session: PrivatePresentationSession
    ) -> String {
        base
            + scopedVersionComponent + "."
            + session.scope.digest + "."
            + session.id.uuidString.lowercased() + "."
    }

    private static func shouldRemove(
        identifier: String,
        userInfo: [AnyHashable: Any],
        keeping session: PrivatePresentationSession?
    ) -> Bool {
        guard isItineraNotificationIdentifier(identifier) else { return false }
        guard let session else { return true }
        return presentationSession(from: identifier, userInfo: userInfo) != session
    }

    private func captureLease(
        expectedSession: PrivatePresentationSession
    ) throws -> SessionLease {
        guard activeSession == expectedSession else {
            throw activeSession == nil
                ? PrivateSurfaceScopeError.activeScopeRequired
                : PrivateSurfaceScopeError.staleScope
        }
        return SessionLease(session: expectedSession, generation: generation)
    }

    private func validate(_ lease: SessionLease) throws {
        guard isCurrent(lease) else {
            throw PrivateSurfaceScopeError.staleScope
        }
    }

    private func isCurrent(_ lease: SessionLease) -> Bool {
        activeSession == lease.session && generation == lease.generation
    }

    private func addRequest(
        _ request: UNNotificationRequest,
        lease: SessionLease
    ) async throws {
        try validate(lease)
        try beginInFlightAdd(generation: lease.generation)
        defer { finishInFlightAdd(generation: lease.generation) }

        try await center.add(request)
        guard isCurrent(lease) else {
            // This best-effort removal is not trusted as the privacy barrier.
            // The coordinator waits for this operation to drain, removes again,
            // and independently re-queries the notification center.
            removeRequests(withIdentifiers: [request.identifier])
            throw PrivateSurfaceScopeError.staleScope
        }
    }

    private func beginInFlightAdd(generation: UInt64) throws {
        let count = inFlightAddCounts[generation, default: 0]
        guard count < .max else {
            throw PrivateSurfaceScopeError.staleScope
        }
        inFlightAddCounts[generation] = count + 1
    }

    private func finishInFlightAdd(generation: UInt64) {
        guard let count = inFlightAddCounts[generation] else { return }
        if count > 1 {
            inFlightAddCounts[generation] = count - 1
        } else {
            inFlightAddCounts.removeValue(forKey: generation)
        }

        var waiting: [AddDrainWaiter] = []
        var ready: [AddDrainWaiter] = []
        for waiter in addDrainWaiters {
            if hasInFlightAdd(through: waiter.throughGeneration) {
                waiting.append(waiter)
            } else {
                ready.append(waiter)
            }
        }
        addDrainWaiters = waiting
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    private func hasInFlightAdd(through generation: UInt64) -> Bool {
        inFlightAddCounts.contains { entry in
            entry.key <= generation && entry.value > 0
        }
    }

    private func removeRequests(withIdentifiers identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private func advanceGeneration() {
        guard generation < .max else {
            activeSession = nil
            return
        }
        generation += 1
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
