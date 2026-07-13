import Foundation
import XCTest
@testable import Itinera

@MainActor
final class TripWidgetSnapshotTests: XCTestCase {
    func testV2SnapshotRoundTripsOnlyAfterSessionEstablishment() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = try makeSession(scopeCharacter: "a", session: 1)
        let snapshot = makeSnapshot(session: session)

        XCTAssertFalse(
            TripWidgetSnapshotStore.save(
                snapshot,
                expectedSession: session,
                defaults: defaults
            )
        )
        XCTAssertTrue(
            TripWidgetSnapshotStore.establishActiveSession(
                session,
                defaults: defaults
            )
        )
        XCTAssertTrue(
            TripWidgetSnapshotStore.save(
                snapshot,
                expectedSession: session,
                defaults: defaults
            )
        )
        XCTAssertEqual(TripWidgetSnapshotStore.load(defaults: defaults), snapshot)
        XCTAssertEqual(TripWidgetSnapshotStore.activeSession(defaults: defaults), session)
    }

    func testPublicationAndUnpublishMutationOrderingIsPrivacyFirst() throws {
        let suiteName = "TripWidgetSnapshotOrderingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(RecordingUserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = try makeSession(scopeCharacter: "f", session: 8)

        defaults.operations = []
        XCTAssertTrue(TripWidgetSnapshotStore.establishActiveSession(session, defaults: defaults))
        XCTAssertEqual(defaults.operations, [
            "remove:\(TripWidgetSnapshotStore.activeSessionKey)",
            "remove:\(TripWidgetSnapshotStore.legacySnapshotKey)",
            "set:\(TripWidgetSnapshotStore.snapshotEnvelopeKey)",
            "set:\(TripWidgetSnapshotStore.activeSessionKey)",
        ])

        defaults.operations = []
        XCTAssertTrue(
            TripWidgetSnapshotStore.save(
                makeSnapshot(session: session),
                expectedSession: session,
                defaults: defaults
            )
        )
        XCTAssertEqual(defaults.operations, [
            "remove:\(TripWidgetSnapshotStore.legacySnapshotKey)",
            "set:\(TripWidgetSnapshotStore.snapshotEnvelopeKey)",
            "set:\(TripWidgetSnapshotStore.activeSessionKey)",
        ])

        defaults.operations = []
        XCTAssertTrue(TripWidgetSnapshotStore.unpublish(defaults: defaults))
        XCTAssertEqual(defaults.operations.first, "remove:\(TripWidgetSnapshotStore.activeSessionKey)")
    }

    func testLoadRejectsEnvelopeWhoseMarkerBelongsToAnotherSession() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = try makeSession(scopeCharacter: "a", session: 1)
        let second = try makeSession(scopeCharacter: "b", session: 2)
        let snapshot = makeSnapshot(session: first)

        XCTAssertTrue(TripWidgetSnapshotStore.establishActiveSession(first, defaults: defaults))
        XCTAssertTrue(
            TripWidgetSnapshotStore.save(
                snapshot,
                expectedSession: first,
                defaults: defaults
            )
        )
        let firstEnvelope = try XCTUnwrap(
            defaults.data(forKey: TripWidgetSnapshotStore.snapshotEnvelopeKey)
        )
        XCTAssertTrue(TripWidgetSnapshotStore.establishActiveSession(second, defaults: defaults))

        // Simulate a delayed payload write that cannot update the active marker.
        defaults.set(firstEnvelope, forKey: TripWidgetSnapshotStore.snapshotEnvelopeKey)
        XCTAssertNil(TripWidgetSnapshotStore.load(defaults: defaults))
    }

    func testDelayedA1SaveCannotPublishIntoLaterA3Session() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstA = try makeSession(scopeCharacter: "a", session: 1)
        let secondB = try makeSession(scopeCharacter: "b", session: 2)
        let laterA = try makeSession(scopeCharacter: "a", session: 3)
        let delayedSnapshot = makeSnapshot(session: firstA)

        XCTAssertTrue(TripWidgetSnapshotStore.establishActiveSession(firstA, defaults: defaults))
        XCTAssertTrue(TripWidgetSnapshotStore.establishActiveSession(secondB, defaults: defaults))
        XCTAssertTrue(TripWidgetSnapshotStore.establishActiveSession(laterA, defaults: defaults))

        XCTAssertFalse(
            TripWidgetSnapshotStore.save(
                delayedSnapshot,
                expectedSession: firstA,
                defaults: defaults
            )
        )
        XCTAssertNil(TripWidgetSnapshotStore.load(defaults: defaults))

        let currentSnapshot = makeSnapshot(session: laterA, tripID: "trip-a3")
        XCTAssertTrue(
            TripWidgetSnapshotStore.save(
                currentSnapshot,
                expectedSession: laterA,
                defaults: defaults
            )
        )
        XCTAssertEqual(TripWidgetSnapshotStore.load(defaults: defaults), currentSnapshot)
    }

    func testUnpublishClearsMarkerEnvelopeAndLegacyV1Payload() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = try makeSession(scopeCharacter: "c", session: 4)
        defaults.set(Data("legacy".utf8), forKey: TripWidgetSnapshotStore.legacySnapshotKey)
        XCTAssertTrue(TripWidgetSnapshotStore.establishActiveSession(session, defaults: defaults))

        XCTAssertTrue(TripWidgetSnapshotStore.unpublish(defaults: defaults))

        XCTAssertNil(defaults.object(forKey: TripWidgetSnapshotStore.activeSessionKey))
        XCTAssertNil(defaults.object(forKey: TripWidgetSnapshotStore.snapshotEnvelopeKey))
        XCTAssertNil(defaults.object(forKey: TripWidgetSnapshotStore.legacySnapshotKey))
        XCTAssertNil(TripWidgetSnapshotStore.load(defaults: defaults))
    }

    func testUnpublishReportsFailureWhenDefaultsRetainsPrivatePayloads() throws {
        let suiteName = "TripWidgetSnapshotRemovalFailureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(RecordingUserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = try makeSession(scopeCharacter: "c", session: 9)
        XCTAssertTrue(TripWidgetSnapshotStore.establishActiveSession(session, defaults: defaults))
        defaults.refusesRemoval = true

        XCTAssertFalse(TripWidgetSnapshotStore.unpublish(defaults: defaults))
        XCTAssertNotNil(defaults.object(forKey: TripWidgetSnapshotStore.activeSessionKey))
        defaults.refusesRemoval = false
    }

    func testV1PayloadIsIgnoredAndRemovedOnLoad() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("unscoped-private-data".utf8), forKey: TripWidgetSnapshotStore.legacySnapshotKey)

        XCTAssertNil(TripWidgetSnapshotStore.load(defaults: defaults))
        XCTAssertNil(defaults.object(forKey: TripWidgetSnapshotStore.legacySnapshotKey))
    }

    func testUnsupportedSnapshotSchemaAndWrongExpectedSessionAreRejected() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = try makeSession(scopeCharacter: "d", session: 5)
        let other = try makeSession(scopeCharacter: "d", session: 6)
        XCTAssertTrue(TripWidgetSnapshotStore.establishActiveSession(session, defaults: defaults))

        let unsupported = makeSnapshot(
            schemaVersion: TripWidgetSnapshot.currentSchemaVersion + 1,
            session: session
        )
        XCTAssertFalse(
            TripWidgetSnapshotStore.save(
                unsupported,
                expectedSession: session,
                defaults: defaults
            )
        )
        XCTAssertFalse(
            TripWidgetSnapshotStore.save(
                makeSnapshot(session: session),
                expectedSession: other,
                defaults: defaults
            )
        )
    }

    func testSnapshotProgressRemainsClamped() throws {
        let session = try makeSession(scopeCharacter: "d", session: 10)

        XCTAssertEqual(makeSnapshot(session: session, progress: 3).progress, 1)
        XCTAssertEqual(makeSnapshot(session: session, progress: -1).progress, 0)
    }

    func testScopedTripURLCarriesOnlyScopeAndSession() throws {
        let session = try makeSession(scopeCharacter: "e", session: 7)
        let url = try XCTUnwrap(
            ScopedTripURL.make(
                presentationSession: session
            )
        )

        XCTAssertEqual(ScopedTripURL.presentationSession(from: url), session)
        XCTAssertEqual(url.path, "")
        XCTAssertTrue(url.absoluteString.contains(session.scope.digest))
        XCTAssertTrue(url.absoluteString.contains(session.id.uuidString.lowercased()))
        XCTAssertFalse(url.absoluteString.contains("trip with spaces"))
        XCTAssertNil(ScopedTripURL.presentationSession(from: URL(string: "itinera://trip/old")!))
        let payloadURL = try XCTUnwrap(
            URL(string: url.absoluteString.replacingOccurrences(
                of: "itinera://trip?",
                with: "itinera://trip/private-server-trip-id?"
            ))
        )
        XCTAssertNil(ScopedTripURL.presentationSession(from: payloadURL))
    }

    func testScopedTripURLFromA1IsStaleAfterBAndLaterA3Establishments() throws {
        let firstA = try makeSession(scopeCharacter: "a", session: 11)
        let secondB = try makeSession(scopeCharacter: "b", session: 12)
        let laterA = try makeSession(scopeCharacter: "a", session: 13)
        let staleURL = try XCTUnwrap(
            ScopedTripURL.make(
                presentationSession: firstA
            )
        )
        let parsedStaleSession = try XCTUnwrap(
            ScopedTripURL.presentationSession(from: staleURL)
        )

        XCTAssertEqual(parsedStaleSession, firstA)
        XCTAssertNotEqual(parsedStaleSession, secondB)
        XCTAssertNotEqual(
            parsedStaleSession,
            laterA,
            "Returning to the same principal must not revive an older deep link."
        )

        let currentURL = try XCTUnwrap(
            ScopedTripURL.make(
                presentationSession: laterA
            )
        )
        XCTAssertEqual(
            ScopedTripURL.presentationSession(from: currentURL),
            laterA
        )
    }

    private func makeSnapshot(
        schemaVersion: Int = TripWidgetSnapshot.currentSchemaVersion,
        session: PrivatePresentationSession,
        tripID: String = "trip-1",
        progress: Double = 0.5
    ) -> TripWidgetSnapshot {
        let leaveBy = Date(timeIntervalSince1970: 1_800_000_000)
        return TripWidgetSnapshot(
            schemaVersion: schemaVersion,
            presentationSession: session,
            tripID: tripID,
            tripTitle: "Lisbon",
            dayNumber: 2,
            stopNumber: 3,
            totalStops: 6,
            currentStop: "Alfama",
            nextStop: "Belém Tower",
            leaveBy: leaveBy,
            progress: progress,
            updatedAt: leaveBy.addingTimeInterval(-60)
        )
    }

    private func makeSession(
        scopeCharacter: Character,
        session: Int
    ) throws -> PrivatePresentationSession {
        let scope = try PrincipalScope(
            validating: String(repeating: scopeCharacter, count: PrincipalScope.digestLength)
        )
        let id = try XCTUnwrap(
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", session))
        )
        return PrivatePresentationSession(scope: scope, id: id)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "TripWidgetSnapshotTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }
}

private final class RecordingUserDefaults: UserDefaults {
    var operations: [String] = []
    var refusesRemoval = false
    private var isRemovingObject = false

    override func set(_ value: Any?, forKey defaultName: String) {
        if !isRemovingObject {
            operations.append("set:\(defaultName)")
        }
        super.set(value, forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        operations.append("remove:\(defaultName)")
        if !refusesRemoval {
            isRemovingObject = true
            defer { isRemovingObject = false }
            super.removeObject(forKey: defaultName)
        }
    }
}
