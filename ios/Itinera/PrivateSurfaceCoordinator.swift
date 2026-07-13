import Foundation
import WidgetKit

struct PrivateSurfaceTeardownFailures: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let widget = Self(rawValue: 1 << 0)
    static let liveActivity = Self(rawValue: 1 << 1)
    static let notification = Self(rawValue: 1 << 2)
}

enum PrivateSurfaceCoordinatorError: LocalizedError, Equatable, Sendable {
    case widgetPublicationFailed
    case widgetUnpublishFailed
    case teardownUnverified(PrivateSurfaceTeardownFailures)
    case staleEstablishment

    var errorDescription: String? {
        switch self {
        case .widgetPublicationFailed:
            return "Itinera could not safely prepare private trip surfaces."
        case .widgetUnpublishFailed:
            return "Itinera could not verify that private widget content was removed."
        case .teardownUnverified:
            return "Itinera could not verify that all private system content was removed."
        case .staleEstablishment:
            return "A newer private-library transition replaced this one."
        }
    }
}

@MainActor
protocol PrivateSurfaceCoordinating: AnyObject {
    var activeSession: PrivatePresentationSession? { get }

    func establish(session: PrivatePresentationSession) async throws
    func tearDown() async throws
    func isCurrent(_ session: PrivatePresentationSession) -> Bool
}

@MainActor
protocol TripWidgetSurfacePersisting {
    func establish(session: PrivatePresentationSession) -> Bool
    func unpublish() -> Bool
}

@MainActor
protocol TripWidgetTimelineReloading {
    func reloadNextStopTimeline()
}

@MainActor
struct AppGroupTripWidgetSurfaceStore: TripWidgetSurfacePersisting {
    func establish(session: PrivatePresentationSession) -> Bool {
        TripWidgetSnapshotStore.establishActiveSession(session)
    }

    func unpublish() -> Bool {
        TripWidgetSnapshotStore.unpublish()
    }
}

@MainActor
struct SystemTripWidgetTimelineReloader: TripWidgetTimelineReloading {
    func reloadNextStopTimeline() {
        WidgetCenter.shared.reloadTimelines(ofKind: ItineraWidgetKind.nextStop)
    }
}

/// Owns all OS-visible private trip surfaces. AppState erects its in-app
/// privacy curtain first, then awaits `tearDown()` before establishing a new
/// presentation session.
@MainActor
final class PrivateSurfaceCoordinator: PrivateSurfaceCoordinating {
    private let widgetStore: any TripWidgetSurfacePersisting
    private let widgetReloader: any TripWidgetTimelineReloading
    private let liveActivities: any TripLiveActivitySurfaceManaging
    private let notifications: any GenerationNotificationSurfaceManaging

    private(set) var activeSession: PrivatePresentationSession?
    private var isTornDown = false
    private var isTearDownVerified = false
    private var transitionGeneration: UInt64 = 0

    init(
        widgetStore: any TripWidgetSurfacePersisting,
        widgetReloader: any TripWidgetTimelineReloading,
        liveActivities: any TripLiveActivitySurfaceManaging,
        notifications: any GenerationNotificationSurfaceManaging,
        initialTransitionGeneration: UInt64 = 0
    ) {
        self.widgetStore = widgetStore
        self.widgetReloader = widgetReloader
        self.liveActivities = liveActivities
        self.notifications = notifications
        transitionGeneration = initialTransitionGeneration
    }

    static func live() -> PrivateSurfaceCoordinator {
        PrivateSurfaceCoordinator(
            widgetStore: AppGroupTripWidgetSurfaceStore(),
            widgetReloader: SystemTripWidgetTimelineReloader(),
            liveActivities: TripLiveActivityManager.shared,
            notifications: GenerationNotificationManager.shared
        )
    }

    func establish(session: PrivatePresentationSession) async throws {
        let generation: UInt64
        do {
            generation = try beginTransition()
        } catch {
            // Even the practically unreachable counter-exhaustion path must
            // leave no previously published system surface visible.
            try await performTearDown(for: transitionGeneration)
            throw error
        }
        if !isTornDown || !isTearDownVerified {
            try await performTearDown(for: generation)
        }
        guard generation == transitionGeneration else {
            throw PrivateSurfaceCoordinatorError.staleEstablishment
        }

        guard widgetStore.establish(session: session) else {
            let didUnpublish = widgetStore.unpublish()
            widgetReloader.reloadNextStopTimeline()
            isTearDownVerified = didUnpublish
            if !didUnpublish {
                throw PrivateSurfaceCoordinatorError.widgetUnpublishFailed
            }
            throw PrivateSurfaceCoordinatorError.widgetPublicationFailed
        }
        widgetReloader.reloadNextStopTimeline()
        liveActivities.establishActiveSession(session)
        notifications.establishActiveSession(session)
        activeSession = session
        isTornDown = false
        isTearDownVerified = false
    }

    func tearDown() async throws {
        let generation: UInt64
        var transitionError: PrivateSurfaceCoordinatorError?
        do {
            generation = try beginTransition()
        } catch let error as PrivateSurfaceCoordinatorError {
            generation = transitionGeneration
            transitionError = error
        }

        if !isTornDown || !isTearDownVerified {
            try await performTearDown(for: generation)
        }
        if let transitionError {
            throw transitionError
        }
    }

    func isCurrent(_ session: PrivatePresentationSession) -> Bool {
        !isTornDown && activeSession == session
    }

    private func performTearDown(for generation: UInt64) async throws {
        activeSession = nil
        isTornDown = true
        isTearDownVerified = false

        // TripWidgetSnapshotStore removes the active marker first. Reloading
        // immediately makes the privacy curtain visible to WidgetKit.
        let didUnpublishWidget = widgetStore.unpublish()
        widgetReloader.reloadNextStopTimeline()

        // Invalidation is synchronous on the main actor and happens before any
        // await, so delayed updates cannot become current during cleanup.
        liveActivities.invalidateActiveSession()
        let notificationInvalidation = notifications.invalidateActiveSession()
        await liveActivities.endAll()
        await notifications.drainInFlightAdds(
            capturedBefore: notificationInvalidation
        )
        await notifications.removeOldAndUnscopedNotifications()

        var failures: PrivateSurfaceTeardownFailures = []
        if !didUnpublishWidget {
            failures.insert(.widget)
        }
        if liveActivities.hasActiveActivities {
            failures.insert(.liveActivity)
        }
        if await notifications.hasOldOrUnscopedNotifications() {
            failures.insert(.notification)
        }
        guard failures.isEmpty else {
            throw PrivateSurfaceCoordinatorError.teardownUnverified(failures)
        }
        guard generation == transitionGeneration else {
            throw PrivateSurfaceCoordinatorError.staleEstablishment
        }
        isTearDownVerified = true
    }

    private func beginTransition() throws -> UInt64 {
        guard transitionGeneration < .max else {
            activeSession = nil
            isTornDown = true
            isTearDownVerified = false
            throw PrivateSurfaceCoordinatorError.staleEstablishment
        }
        transitionGeneration += 1
        return transitionGeneration
    }
}
