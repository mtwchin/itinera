import Foundation

enum ItineraWidgetKind {
    static let nextStop = "ItineraNextStop"
}

struct TripWidgetSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let presentationSession: PrivatePresentationSession
    let tripID: String
    let tripTitle: String
    let dayNumber: Int
    let stopNumber: Int
    let totalStops: Int
    let currentStop: String?
    let nextStop: String
    let leaveBy: Date?
    let progress: Double
    let updatedAt: Date

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        presentationSession: PrivatePresentationSession,
        tripID: String,
        tripTitle: String,
        dayNumber: Int,
        stopNumber: Int,
        totalStops: Int,
        currentStop: String?,
        nextStop: String,
        leaveBy: Date?,
        progress: Double,
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.presentationSession = presentationSession
        self.tripID = tripID
        self.tripTitle = tripTitle
        self.dayNumber = dayNumber
        self.stopNumber = stopNumber
        self.totalStops = totalStops
        self.currentStop = currentStop
        self.nextStop = nextStop
        self.leaveBy = leaveBy
        self.progress = min(max(progress, 0), 1)
        self.updatedAt = updatedAt
    }
}

/// A scoped envelope is written before its active marker. These two defaults
/// writes are intentionally ordered, but are not transactional or atomic.
private struct TripWidgetSnapshotEnvelope: Codable {
    let schemaVersion: Int
    let presentationSession: PrivatePresentationSession
    let snapshot: TripWidgetSnapshot?

    init(
        presentationSession: PrivatePresentationSession,
        snapshot: TripWidgetSnapshot?
    ) {
        schemaVersion = TripWidgetSnapshot.currentSchemaVersion
        self.presentationSession = presentationSession
        self.snapshot = snapshot
    }
}

private struct TripWidgetActiveMarker: Codable {
    let schemaVersion: Int
    let presentationSession: PrivatePresentationSession

    init(presentationSession: PrivatePresentationSession) {
        schemaVersion = TripWidgetSnapshot.currentSchemaVersion
        self.presentationSession = presentationSession
    }
}

enum TripWidgetSnapshotStore {
    static let appGroupIdentifier = "group.com.itinera.shared"

    // Internal visibility allows deterministic contract tests without making
    // persistence details part of the app's public surface.
    static let activeSessionKey = "trip-widget-active-presentation-v2"
    static let snapshotEnvelopeKey = "trip-widget-snapshot-v2"
    static let legacySnapshotKey = "trip-widget-snapshot-v1"

    static func activeSession(
        defaults: UserDefaults? = nil
    ) -> PrivatePresentationSession? {
        guard
            let defaults = resolvedDefaults(defaults),
            let data = defaults.data(forKey: activeSessionKey),
            let marker = try? JSONDecoder().decode(
                TripWidgetActiveMarker.self,
                from: data
            ),
            marker.schemaVersion == TripWidgetSnapshot.currentSchemaVersion
        else {
            return nil
        }
        return marker.presentationSession
    }

    static func load(defaults: UserDefaults? = nil) -> TripWidgetSnapshot? {
        guard let defaults = resolvedDefaults(defaults) else { return nil }
        discardLegacySnapshot(defaults: defaults)

        guard
            let marker = activeSession(defaults: defaults),
            let data = defaults.data(forKey: snapshotEnvelopeKey),
            let envelope = try? JSONDecoder().decode(
                TripWidgetSnapshotEnvelope.self,
                from: data
            ),
            envelope.schemaVersion == TripWidgetSnapshot.currentSchemaVersion,
            envelope.presentationSession == marker,
            let snapshot = envelope.snapshot,
            snapshot.schemaVersion == TripWidgetSnapshot.currentSchemaVersion,
            snapshot.presentationSession == marker
        else {
            return nil
        }
        return snapshot
    }

    /// Establishes a principal with an intentionally empty snapshot. The empty
    /// scoped envelope is persisted first and the active marker is published
    /// last so a widget can never pair old content with a new principal.
    @discardableResult
    @MainActor
    static func establishActiveSession(
        _ session: PrivatePresentationSession,
        defaults: UserDefaults? = nil
    ) -> Bool {
        guard
            let defaults = resolvedDefaults(defaults),
            let envelopeData = encodedEnvelope(for: session, snapshot: nil),
            let markerData = encodedMarker(for: session)
        else {
            return false
        }

        // Unpublish first even when replacing a malformed or stale marker.
        defaults.removeObject(forKey: activeSessionKey)
        discardLegacySnapshot(defaults: defaults)
        defaults.set(envelopeData, forKey: snapshotEnvelopeKey)
        defaults.set(markerData, forKey: activeSessionKey)
        return activeSession(defaults: defaults) == session
            && envelope(defaults: defaults)?.presentationSession == session
            && envelope(defaults: defaults)?.snapshot == nil
            && defaults.object(forKey: legacySnapshotKey) == nil
    }

    /// Publishes only when the producer's expected presentation session, the
    /// existing marker, and the snapshot match. A delayed producer from an
    /// earlier lifetime cannot reactivate itself after an identity transition.
    @discardableResult
    @MainActor
    static func save(
        _ snapshot: TripWidgetSnapshot,
        expectedSession: PrivatePresentationSession,
        defaults: UserDefaults? = nil
    ) -> Bool {
        guard
            snapshot.schemaVersion == TripWidgetSnapshot.currentSchemaVersion,
            snapshot.presentationSession == expectedSession,
            let defaults = resolvedDefaults(defaults),
            activeSession(defaults: defaults) == expectedSession,
            let envelopeData = encodedEnvelope(
                for: expectedSession,
                snapshot: snapshot
            ),
            let markerData = encodedMarker(for: expectedSession)
        else {
            return false
        }

        discardLegacySnapshot(defaults: defaults)
        defaults.set(envelopeData, forKey: snapshotEnvelopeKey)

        // Recheck the marker before publishing it last. This is a second
        // fail-closed guard, not a claim that UserDefaults writes are atomic.
        guard activeSession(defaults: defaults) == expectedSession else {
            removeEnvelopeIfOwned(by: expectedSession, defaults: defaults)
            return false
        }
        defaults.set(markerData, forKey: activeSessionKey)
        return activeSession(defaults: defaults) == expectedSession
            && envelope(defaults: defaults)?.presentationSession == expectedSession
            && envelope(defaults: defaults)?.snapshot == snapshot
    }

    /// Clears trip content for the still-active principal without opening a
    /// window in which an old producer could reclaim an unscoped marker.
    @discardableResult
    @MainActor
    static func clearSnapshot(
        expectedSession: PrivatePresentationSession,
        defaults: UserDefaults? = nil
    ) -> Bool {
        guard
            let defaults = resolvedDefaults(defaults),
            activeSession(defaults: defaults) == expectedSession,
            let envelopeData = encodedEnvelope(for: expectedSession, snapshot: nil),
            let markerData = encodedMarker(for: expectedSession)
        else {
            return false
        }

        discardLegacySnapshot(defaults: defaults)
        defaults.set(envelopeData, forKey: snapshotEnvelopeKey)
        guard activeSession(defaults: defaults) == expectedSession else {
            removeEnvelopeIfOwned(by: expectedSession, defaults: defaults)
            return false
        }
        defaults.set(markerData, forKey: activeSessionKey)
        return activeSession(defaults: defaults) == expectedSession
            && envelope(defaults: defaults)?.presentationSession == expectedSession
            && envelope(defaults: defaults)?.snapshot == nil
    }

    /// Removes the visibility marker first, then removes all payloads. Repeated
    /// calls are safe and also erase the unsupported global v1 snapshot.
    @discardableResult
    @MainActor
    static func unpublish(defaults: UserDefaults? = nil) -> Bool {
        guard let defaults = resolvedDefaults(defaults) else { return false }
        defaults.removeObject(forKey: activeSessionKey)
        defaults.removeObject(forKey: snapshotEnvelopeKey)
        discardLegacySnapshot(defaults: defaults)
        return defaults.object(forKey: activeSessionKey) == nil
            && defaults.object(forKey: snapshotEnvelopeKey) == nil
            && defaults.object(forKey: legacySnapshotKey) == nil
    }

    private static func resolvedDefaults(_ defaults: UserDefaults?) -> UserDefaults? {
        defaults ?? UserDefaults(suiteName: appGroupIdentifier)
    }

    private static func encodedEnvelope(
        for session: PrivatePresentationSession,
        snapshot: TripWidgetSnapshot?
    ) -> Data? {
        try? JSONEncoder().encode(
            TripWidgetSnapshotEnvelope(
                presentationSession: session,
                snapshot: snapshot
            )
        )
    }

    private static func envelope(
        defaults: UserDefaults
    ) -> TripWidgetSnapshotEnvelope? {
        guard let data = defaults.data(forKey: snapshotEnvelopeKey) else {
            return nil
        }
        return try? JSONDecoder().decode(
            TripWidgetSnapshotEnvelope.self,
            from: data
        )
    }

    private static func removeEnvelopeIfOwned(
        by session: PrivatePresentationSession,
        defaults: UserDefaults
    ) {
        guard
            let data = defaults.data(forKey: snapshotEnvelopeKey),
            let envelope = try? JSONDecoder().decode(
                TripWidgetSnapshotEnvelope.self,
                from: data
            ),
            envelope.presentationSession == session
        else {
            return
        }
        defaults.removeObject(forKey: snapshotEnvelopeKey)
    }

    private static func discardLegacySnapshot(defaults: UserDefaults) {
        defaults.removeObject(forKey: legacySnapshotKey)
    }

    private static func encodedMarker(
        for session: PrivatePresentationSession
    ) -> Data? {
        try? JSONEncoder().encode(
            TripWidgetActiveMarker(presentationSession: session)
        )
    }
}

enum ScopedTripURL {
    static let principalScopeQueryName = "principal_scope"
    static let presentationSessionQueryName = "presentation_session"

    static func make(
        presentationSession: PrivatePresentationSession
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "itinera"
        components.host = "trip"
        components.queryItems = [
            URLQueryItem(
                name: principalScopeQueryName,
                value: presentationSession.scope.digest
            ),
            URLQueryItem(
                name: presentationSessionQueryName,
                value: presentationSession.id.uuidString.lowercased()
            )
        ]
        return components.url
    }

    static func presentationSession(
        from url: URL
    ) -> PrivatePresentationSession? {
        let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )
        guard
            url.scheme == "itinera",
            url.host == "trip",
            url.path.isEmpty,
            let queryItems = components?.queryItems,
            queryItems.count == 2,
            Set(queryItems.map(\.name)) == [
                principalScopeQueryName,
                presentationSessionQueryName,
            ],
            let digest = queryItems
                .first(where: { $0.name == principalScopeQueryName })?.value,
            let sessionValue = queryItems
                .first(where: { $0.name == presentationSessionQueryName })?.value,
            let scope = try? PrincipalScope(validating: digest),
            let id = UUID(uuidString: sessionValue)
        else {
            return nil
        }
        return PrivatePresentationSession(scope: scope, id: id)
    }
}
