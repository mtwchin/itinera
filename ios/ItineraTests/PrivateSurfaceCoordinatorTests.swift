import Foundation
import UserNotifications
import XCTest
@testable import Itinera

@MainActor
final class PrivateSurfaceCoordinatorTests: XCTestCase {
    func testEstablishmentAndIdempotentTeardownUsePrivacyFirstOrdering() async throws {
        let events = EventRecorder()
        let widget = WidgetStoreSpy(events: events)
        let reloader = WidgetReloaderSpy(events: events)
        let activities = LiveActivitySpy(events: events)
        let notifications = NotificationSurfaceSpy(events: events)
        let coordinator = PrivateSurfaceCoordinator(
            widgetStore: widget,
            widgetReloader: reloader,
            liveActivities: activities,
            notifications: notifications
        )
        let session = presentationSession(scopeCharacter: "a", session: 1)

        try await coordinator.establish(session: session)

        XCTAssertEqual(
            events.values,
            [
                "widget.unpublish",
                "widget.reload",
                "activity.invalidate",
                "notification.invalidate",
                "activity.endAll",
                "notification.drain",
                "notification.removeOld",
                "activity.verify",
                "notification.verify",
                "widget.establish",
                "widget.reload",
                "activity.establish",
                "notification.establish",
            ]
        )
        XCTAssertEqual(coordinator.activeSession, session)
        XCTAssertTrue(coordinator.isCurrent(session))

        try await coordinator.tearDown()
        let afterFirstTeardown = events.values
        try await coordinator.tearDown()

        XCTAssertEqual(events.values, afterFirstTeardown)
        XCTAssertNil(coordinator.activeSession)
        XCTAssertEqual(
            Array(events.values.suffix(9)),
            [
                "widget.unpublish",
                "widget.reload",
                "activity.invalidate",
                "notification.invalidate",
                "activity.endAll",
                "notification.drain",
                "notification.removeOld",
                "activity.verify",
                "notification.verify",
            ]
        )
    }

    func testWidgetPublicationFailureLeavesEverySurfaceTornDown() async {
        let events = EventRecorder()
        let widget = WidgetStoreSpy(events: events, establishSucceeds: false)
        let coordinator = PrivateSurfaceCoordinator(
            widgetStore: widget,
            widgetReloader: WidgetReloaderSpy(events: events),
            liveActivities: LiveActivitySpy(events: events),
            notifications: NotificationSurfaceSpy(events: events)
        )

        do {
            try await coordinator.establish(
                session: presentationSession(scopeCharacter: "b", session: 2)
            )
            XCTFail("Expected widget publication to fail closed")
        } catch {
            XCTAssertEqual(
                error as? PrivateSurfaceCoordinatorError,
                .widgetPublicationFailed
            )
        }

        XCTAssertNil(coordinator.activeSession)
        XCTAssertEqual(Array(events.values.suffix(3)), [
            "widget.establish",
            "widget.unpublish",
            "widget.reload",
        ])
    }

    func testWidgetUnpublishFailureStillEndsActivitiesAndRemovesNotifications() async {
        let events = EventRecorder()
        let coordinator = PrivateSurfaceCoordinator(
            widgetStore: WidgetStoreSpy(
                events: events,
                unpublishSucceeds: false
            ),
            widgetReloader: WidgetReloaderSpy(events: events),
            liveActivities: LiveActivitySpy(events: events),
            notifications: NotificationSurfaceSpy(events: events)
        )

        do {
            try await coordinator.tearDown()
            XCTFail("Expected an unverifiable widget curtain to fail closed")
        } catch {
            XCTAssertEqual(
                error as? PrivateSurfaceCoordinatorError,
                .teardownUnverified(.widget)
            )
        }

        XCTAssertNil(coordinator.activeSession)
        XCTAssertEqual(events.values, [
            "widget.unpublish",
            "widget.reload",
            "activity.invalidate",
            "notification.invalidate",
            "activity.endAll",
            "notification.drain",
            "notification.removeOld",
            "activity.verify",
            "notification.verify",
        ])
    }

    func testEveryUnverifiedSurfaceIsReportedAndBlocksEstablishment() async {
        let events = EventRecorder()
        let coordinator = PrivateSurfaceCoordinator(
            widgetStore: WidgetStoreSpy(
                events: events,
                unpublishSucceeds: false
            ),
            widgetReloader: WidgetReloaderSpy(events: events),
            liveActivities: LiveActivitySpy(
                events: events,
                reportsActiveActivities: true
            ),
            notifications: NotificationSurfaceSpy(
                events: events,
                reportsOldOrUnscopedNotifications: true
            )
        )

        do {
            try await coordinator.establish(
                session: presentationSession(scopeCharacter: "c", session: 9)
            )
            XCTFail("Unverified system surfaces must block establishment")
        } catch {
            XCTAssertEqual(
                error as? PrivateSurfaceCoordinatorError,
                .teardownUnverified([.widget, .liveActivity, .notification])
            )
        }

        XCTAssertNil(coordinator.activeSession)
        XCTAssertFalse(events.values.contains("widget.establish"))
        XCTAssertTrue(events.values.contains("activity.endAll"))
        XCTAssertTrue(events.values.contains("notification.drain"))
        XCTAssertTrue(events.values.contains("notification.removeOld"))
        XCTAssertTrue(events.values.contains("activity.verify"))
        XCTAssertTrue(events.values.contains("notification.verify"))
    }

    func testNotificationRemovalNoOpIsCaughtByIndependentVerification() async {
        let events = EventRecorder()
        let staleIdentifier = "com.itinera.generation.legacy-job"
        let staleRequest = notificationRequest(
            identifier: staleIdentifier,
            content: nil
        )
        let center = ImmediateNotificationCenter(
            pending: [staleRequest],
            delivered: [staleRequest],
            ignoresRemoval: true
        )
        let coordinator = PrivateSurfaceCoordinator(
            widgetStore: WidgetStoreSpy(events: events),
            widgetReloader: WidgetReloaderSpy(events: events),
            liveActivities: LiveActivitySpy(events: events),
            notifications: GenerationNotificationManager(center: center)
        )

        do {
            try await coordinator.tearDown()
            XCTFail("A notification-center no-op must fail closed")
        } catch {
            XCTAssertEqual(
                error as? PrivateSurfaceCoordinatorError,
                .teardownUnverified(.notification)
            )
        }

        XCTAssertEqual(center.pendingIdentifiers, [staleIdentifier])
        XCTAssertEqual(center.deliveredIdentifiers, [staleIdentifier])
    }

    func testTransitionCounterExhaustionStillErectsEveryPrivacyCurtain() async {
        let events = EventRecorder()
        let coordinator = PrivateSurfaceCoordinator(
            widgetStore: WidgetStoreSpy(events: events),
            widgetReloader: WidgetReloaderSpy(events: events),
            liveActivities: LiveActivitySpy(events: events),
            notifications: NotificationSurfaceSpy(events: events),
            initialTransitionGeneration: .max
        )

        do {
            try await coordinator.establish(
                session: presentationSession(
                    scopeCharacter: "e",
                    session: 7
                )
            )
            XCTFail("An exhausted transition counter must fail closed")
        } catch {
            XCTAssertEqual(
                error as? PrivateSurfaceCoordinatorError,
                .staleEstablishment
            )
        }

        XCTAssertNil(coordinator.activeSession)
        XCTAssertEqual(events.values, [
            "widget.unpublish",
            "widget.reload",
            "activity.invalidate",
            "notification.invalidate",
            "activity.endAll",
            "notification.drain",
            "notification.removeOld",
            "activity.verify",
            "notification.verify",
        ])
    }

    func testTearDownDuringSuspendedEstablishmentPreventsLatePublication() async throws {
        let events = EventRecorder()
        let activities = SuspendingLiveActivitySpy(events: events)
        let coordinator = PrivateSurfaceCoordinator(
            widgetStore: WidgetStoreSpy(events: events),
            widgetReloader: WidgetReloaderSpy(events: events),
            liveActivities: activities,
            notifications: NotificationSurfaceSpy(events: events)
        )
        let session = presentationSession(scopeCharacter: "f", session: 8)

        let establishment = Task { @MainActor in
            try await coordinator.establish(session: session)
        }
        await activities.waitUntilFirstEndAllIsSuspended()

        try await coordinator.tearDown()
        activities.resumeFirstEndAll()

        do {
            try await establishment.value
            XCTFail("A teardown must invalidate the suspended establishment")
        } catch {
            XCTAssertEqual(
                error as? PrivateSurfaceCoordinatorError,
                .staleEstablishment
            )
        }

        XCTAssertNil(coordinator.activeSession)
        XCTAssertFalse(events.values.contains("widget.establish"))
        XCTAssertFalse(events.values.contains("activity.establish"))
        XCTAssertFalse(events.values.contains("notification.establish"))
    }

    func testTeardownDrainsSuspendedAddBeforeRemovalAndVerification() async throws {
        let events = EventRecorder()
        let center = DeferredCommitNotificationCenter(ignoresRemoval: false)
        let drainSignal = OneShotSignal()
        let manager = GenerationNotificationManager(
            center: center,
            onInFlightDrainSuspended: { drainSignal.signal() }
        )
        let coordinator = PrivateSurfaceCoordinator(
            widgetStore: WidgetStoreSpy(events: events),
            widgetReloader: WidgetReloaderSpy(events: events),
            liveActivities: LiveActivitySpy(events: events),
            notifications: manager
        )
        let session = presentationSession(scopeCharacter: "a", session: 10)
        manager.establishActiveSession(session)

        let add = Task { @MainActor in
            try await manager.notifyTripReady(
                jobID: "delayed-a",
                title: "Delayed A",
                expectedSession: session
            )
        }
        await center.waitUntilAddIsSuspended()

        let teardown = Task { @MainActor in
            try await coordinator.tearDown()
        }
        await drainSignal.wait()

        // The deferred add is not visible yet. Reaching the drain without any
        // query proves teardown has not skipped ahead to verification.
        XCTAssertEqual(center.pendingQueryCount, 0)
        center.resumeAdd()

        do {
            try await add.value
            XCTFail("The pre-invalidation add must become stale")
        } catch {
            XCTAssertEqual(error as? PrivateSurfaceScopeError, .staleScope)
        }
        try await teardown.value

        XCTAssertTrue(center.pendingIdentifiers.isEmpty)
        XCTAssertGreaterThanOrEqual(center.pendingQueryCount, 2)
    }

    func testSuspendedAddWithNoOpRemovalFailsTeardownClosed() async {
        let events = EventRecorder()
        let center = DeferredCommitNotificationCenter(ignoresRemoval: true)
        let drainSignal = OneShotSignal()
        let manager = GenerationNotificationManager(
            center: center,
            onInFlightDrainSuspended: { drainSignal.signal() }
        )
        let coordinator = PrivateSurfaceCoordinator(
            widgetStore: WidgetStoreSpy(events: events),
            widgetReloader: WidgetReloaderSpy(events: events),
            liveActivities: LiveActivitySpy(events: events),
            notifications: manager
        )
        let session = presentationSession(scopeCharacter: "b", session: 11)
        manager.establishActiveSession(session)

        let add = Task { @MainActor in
            try await manager.notifyTripReady(
                jobID: "delayed-no-op",
                title: nil,
                expectedSession: session
            )
        }
        await center.waitUntilAddIsSuspended()

        let teardown = Task { @MainActor in
            try await coordinator.tearDown()
        }
        await drainSignal.wait()
        XCTAssertEqual(center.pendingQueryCount, 0)
        center.resumeAdd()

        do {
            try await add.value
            XCTFail("The pre-invalidation add must become stale")
        } catch {
            XCTAssertEqual(error as? PrivateSurfaceScopeError, .staleScope)
        }
        do {
            try await teardown.value
            XCTFail("A no-op system removal must fail the privacy curtain")
        } catch {
            XCTAssertEqual(
                error as? PrivateSurfaceCoordinatorError,
                .teardownUnverified(.notification)
            )
        }

        XCTAssertFalse(center.pendingIdentifiers.isEmpty)
        XCTAssertGreaterThanOrEqual(center.pendingQueryCount, 2)
    }

    func testDelayedA1NotificationAddIsRemovedAfterA3Establishment() async {
        let center = SuspendedNotificationCenter()
        let manager = GenerationNotificationManager(center: center)
        let firstA = presentationSession(scopeCharacter: "c", session: 3)
        let laterA = presentationSession(scopeCharacter: "c", session: 4)
        manager.establishActiveSession(firstA)

        let task = Task { @MainActor in
            try await manager.notifyTripReady(
                jobID: "job-a1",
                title: "Old A trip",
                expectedSession: firstA
            )
        }
        await center.waitUntilAddIsSuspended()
        manager.establishActiveSession(laterA)
        center.resumeAdd()

        do {
            try await task.value
            XCTFail("Expected delayed A1 notification to be rejected")
        } catch {
            XCTAssertEqual(error as? PrivateSurfaceScopeError, .staleScope)
        }

        let expectedIdentifier = GenerationNotificationManager.identifier(
            for: "job-a1",
            session: firstA
        )
        XCTAssertTrue(center.removedPending.contains(expectedIdentifier))
        XCTAssertTrue(center.removedDelivered.contains(expectedIdentifier))
    }

    func testNotificationCleanupRemovesPendingAndDeliveredOldAndUnscopedRequests() async {
        let oldSession = presentationSession(scopeCharacter: "d", session: 5)
        let currentSession = presentationSession(scopeCharacter: "e", session: 6)
        let oldID = GenerationNotificationManager.identifier(
            for: "job-old",
            session: oldSession
        )
        let currentID = GenerationNotificationManager.identifier(
            for: "job-current",
            session: currentSession
        )
        let legacyID = "com.itinera.generation.job-legacy"
        let unrelatedID = "com.example.unrelated"
        let oldRequest = notificationRequest(
            identifier: oldID,
            content: .tripReady(
                jobID: "job-old",
                tripTitle: nil,
                session: oldSession
            )
        )
        let currentRequest = notificationRequest(
            identifier: currentID,
            content: .tripReady(
                jobID: "job-current",
                tripTitle: nil,
                session: currentSession
            )
        )
        let legacyRequest = notificationRequest(identifier: legacyID, content: nil)
        let unrelatedRequest = notificationRequest(identifier: unrelatedID, content: nil)
        let center = ImmediateNotificationCenter(
            pending: [oldRequest, currentRequest, legacyRequest, unrelatedRequest],
            delivered: [oldRequest, currentRequest, legacyRequest, unrelatedRequest]
        )
        let manager = GenerationNotificationManager(center: center)
        manager.establishActiveSession(currentSession)

        await manager.removeOldAndUnscopedNotifications()
        let hasUnremovedPrivateNotifications =
            await manager.hasOldOrUnscopedNotifications()

        XCTAssertEqual(Set(center.removedPending), Set([oldID, legacyID]))
        XCTAssertEqual(Set(center.removedDelivered), Set([oldID, legacyID]))
        XCTAssertFalse(center.removedPending.contains(currentID))
        XCTAssertFalse(center.removedDelivered.contains(currentID))
        XCTAssertFalse(center.removedPending.contains(unrelatedID))
        XCTAssertFalse(hasUnremovedPrivateNotifications)
    }

    private func presentationSession(
        scopeCharacter: Character,
        session: Int
    ) -> PrivatePresentationSession {
        let scope = try! PrincipalScope(
            validating: String(repeating: scopeCharacter, count: PrincipalScope.digestLength)
        )
        let id = UUID(
            uuidString: String(format: "00000000-0000-0000-0000-%012d", session)
        )!
        return PrivatePresentationSession(scope: scope, id: id)
    }

    private func notificationRequest(
        identifier: String,
        content descriptor: GenerationNotificationContent?
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        if let descriptor {
            content.title = descriptor.title
            content.body = descriptor.body
            content.userInfo = descriptor.userInfo
        }
        return UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
    }
}

@MainActor
private final class EventRecorder {
    var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}

@MainActor
private final class OneShotSignal {
    private var isSignaled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

@MainActor
private final class WidgetStoreSpy: TripWidgetSurfacePersisting {
    private let events: EventRecorder
    private let establishSucceeds: Bool
    private let unpublishSucceeds: Bool

    init(
        events: EventRecorder,
        establishSucceeds: Bool = true,
        unpublishSucceeds: Bool = true
    ) {
        self.events = events
        self.establishSucceeds = establishSucceeds
        self.unpublishSucceeds = unpublishSucceeds
    }

    func establish(session: PrivatePresentationSession) -> Bool {
        events.record("widget.establish")
        return establishSucceeds
    }

    func unpublish() -> Bool {
        events.record("widget.unpublish")
        return unpublishSucceeds
    }
}

@MainActor
private final class WidgetReloaderSpy: TripWidgetTimelineReloading {
    private let events: EventRecorder

    init(events: EventRecorder) {
        self.events = events
    }

    func reloadNextStopTimeline() {
        events.record("widget.reload")
    }
}

@MainActor
private final class LiveActivitySpy: TripLiveActivitySurfaceManaging {
    private let events: EventRecorder
    var reportsActiveActivities: Bool

    init(
        events: EventRecorder,
        reportsActiveActivities: Bool = false
    ) {
        self.events = events
        self.reportsActiveActivities = reportsActiveActivities
    }

    var hasActiveActivities: Bool {
        events.record("activity.verify")
        return reportsActiveActivities
    }

    func establishActiveSession(_ session: PrivatePresentationSession) {
        events.record("activity.establish")
    }

    func invalidateActiveSession() {
        events.record("activity.invalidate")
    }

    func endAll() async {
        events.record("activity.endAll")
    }
}

@MainActor
private final class SuspendingLiveActivitySpy: TripLiveActivitySurfaceManaging {
    private let events: EventRecorder
    private var endAllCount = 0
    private var firstEndAllContinuation: CheckedContinuation<Void, Never>?

    init(events: EventRecorder) {
        self.events = events
    }

    var hasActiveActivities: Bool {
        events.record("activity.verify")
        return false
    }

    func establishActiveSession(_ session: PrivatePresentationSession) {
        events.record("activity.establish")
    }

    func invalidateActiveSession() {
        events.record("activity.invalidate")
    }

    func endAll() async {
        endAllCount += 1
        events.record("activity.endAll")
        guard endAllCount == 1 else { return }
        await withCheckedContinuation { continuation in
            firstEndAllContinuation = continuation
        }
    }

    func waitUntilFirstEndAllIsSuspended() async {
        while firstEndAllContinuation == nil {
            await Task.yield()
        }
    }

    func resumeFirstEndAll() {
        firstEndAllContinuation?.resume()
        firstEndAllContinuation = nil
    }
}

@MainActor
private final class NotificationSurfaceSpy: GenerationNotificationSurfaceManaging {
    private let events: EventRecorder
    var reportsOldOrUnscopedNotifications: Bool
    private var generation: UInt64 = 0

    init(
        events: EventRecorder,
        reportsOldOrUnscopedNotifications: Bool = false
    ) {
        self.events = events
        self.reportsOldOrUnscopedNotifications = reportsOldOrUnscopedNotifications
    }

    func establishActiveSession(_ session: PrivatePresentationSession) {
        events.record("notification.establish")
    }

    func invalidateActiveSession() -> NotificationSurfaceInvalidation {
        events.record("notification.invalidate")
        let invalidation = NotificationSurfaceInvalidation(
            throughGeneration: generation
        )
        if generation < .max {
            generation += 1
        }
        return invalidation
    }

    func drainInFlightAdds(
        capturedBefore invalidation: NotificationSurfaceInvalidation
    ) async {
        events.record("notification.drain")
    }

    func removeOldAndUnscopedNotifications() async {
        events.record("notification.removeOld")
    }

    func hasOldOrUnscopedNotifications() async -> Bool {
        events.record("notification.verify")
        return reportsOldOrUnscopedNotifications
    }
}

@MainActor
private final class DeferredCommitNotificationCenter: UserNotificationCenterServing {
    private let ignoresRemoval: Bool
    private var addContinuation: CheckedContinuation<Void, any Error>?
    private var pending: [UNNotificationRequest] = []
    private(set) var pendingQueryCount = 0

    var pendingIdentifiers: [String] {
        pending.map(\.identifier)
    }

    init(ignoresRemoval: Bool) {
        self.ignoresRemoval = ignoresRemoval
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        true
    }

    func notificationSettings() async -> UNNotificationSettings {
        fatalError("Not used by this test")
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { continuation in
            addContinuation = continuation
        }
        pending.append(request)
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        pendingQueryCount += 1
        return pending
    }

    func deliveredNotificationRequests() async -> [UNNotificationRequest] {
        []
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        guard !ignoresRemoval else { return }
        pending.removeAll { identifiers.contains($0.identifier) }
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}

    func waitUntilAddIsSuspended() async {
        while addContinuation == nil {
            await Task.yield()
        }
    }

    func resumeAdd() {
        addContinuation?.resume()
        addContinuation = nil
    }
}

@MainActor
private final class SuspendedNotificationCenter: UserNotificationCenterServing {
    private var addContinuation: CheckedContinuation<Void, any Error>?
    private(set) var added: [UNNotificationRequest] = []
    private(set) var removedPending: [String] = []
    private(set) var removedDelivered: [String] = []

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        true
    }

    func notificationSettings() async -> UNNotificationSettings {
        fatalError("Not used by this test")
    }

    func add(_ request: UNNotificationRequest) async throws {
        added.append(request)
        try await withCheckedThrowingContinuation { continuation in
            addContinuation = continuation
        }
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        added
    }

    func deliveredNotificationRequests() async -> [UNNotificationRequest] {
        []
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedPending.append(contentsOf: identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDelivered.append(contentsOf: identifiers)
    }

    func waitUntilAddIsSuspended() async {
        while addContinuation == nil {
            await Task.yield()
        }
    }

    func resumeAdd() {
        addContinuation?.resume()
        addContinuation = nil
    }
}

@MainActor
private final class ImmediateNotificationCenter: UserNotificationCenterServing {
    private var pending: [UNNotificationRequest]
    private var delivered: [UNNotificationRequest]
    private let ignoresRemoval: Bool
    private(set) var removedPending: [String] = []
    private(set) var removedDelivered: [String] = []

    var pendingIdentifiers: [String] {
        pending.map(\.identifier)
    }

    var deliveredIdentifiers: [String] {
        delivered.map(\.identifier)
    }

    init(
        pending: [UNNotificationRequest],
        delivered: [UNNotificationRequest],
        ignoresRemoval: Bool = false
    ) {
        self.pending = pending
        self.delivered = delivered
        self.ignoresRemoval = ignoresRemoval
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        true
    }

    func notificationSettings() async -> UNNotificationSettings {
        fatalError("Not used by this test")
    }

    func add(_ request: UNNotificationRequest) async throws {
        pending.append(request)
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        pending
    }

    func deliveredNotificationRequests() async -> [UNNotificationRequest] {
        delivered
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedPending.append(contentsOf: identifiers)
        guard !ignoresRemoval else { return }
        pending.removeAll { identifiers.contains($0.identifier) }
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDelivered.append(contentsOf: identifiers)
        guard !ignoresRemoval else { return }
        delivered.removeAll { identifiers.contains($0.identifier) }
    }
}
