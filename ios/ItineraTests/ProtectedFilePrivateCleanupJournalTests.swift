import Foundation
import XCTest
@testable import Itinera

final class ProtectedFilePrivateCleanupJournalTests: XCTestCase {
    func testDurableRoundTripPreservesOperationAndAdvancedStage()
        async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "private-cleanup-v1.json")
        let operationID = UUID(
            uuidString: "11111111-2222-4333-8444-555555555555"
        )!
        let initialPlan = PrivateCleanupPlan(
            operationID: operationID,
            intent: .delete,
            stage: .serverDeletionPending,
            scope: try scope(character: "a")
        )

        let firstJournal = ProtectedFilePrivateCleanupJournal(
            fileURL: fileURL
        )
        try await firstJournal.save(initialPlan)

        let reloadedJournal = ProtectedFilePrivateCleanupJournal(
            fileURL: fileURL
        )
        let reloadedInitial = try await reloadedJournal.load()
        XCTAssertEqual(reloadedInitial, initialPlan)
        XCTAssertEqual(reloadedInitial?.operationID, operationID)
        XCTAssertEqual(reloadedInitial?.stage, .serverDeletionPending)

        let advancedPlan = initialPlan.advancing(to: .localCleanup)
        try await reloadedJournal.save(advancedPlan)

        let relaunchedJournal = ProtectedFilePrivateCleanupJournal(
            fileURL: fileURL
        )
        let reloadedAdvanced = try await relaunchedJournal.load()
        XCTAssertEqual(reloadedAdvanced, advancedPlan)
        XCTAssertEqual(reloadedAdvanced?.operationID, operationID)
        XCTAssertEqual(reloadedAdvanced?.intent, .delete)
        XCTAssertEqual(reloadedAdvanced?.stage, .localCleanup)
        XCTAssertEqual(reloadedAdvanced?.scope, initialPlan.scope)
    }

    func testCorruptJournalFailsClosedWithoutDeletingEvidence() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let fileURL = root.appending(path: "private-cleanup-v1.json")
        let corruptData = Data("not a cleanup journal".utf8)
        try corruptData.write(to: fileURL, options: [.atomic])
        let journal = ProtectedFilePrivateCleanupJournal(fileURL: fileURL)

        await assertJournalUnavailable {
            _ = try await journal.load()
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try Data(contentsOf: fileURL), corruptData)
    }

    func testUnsupportedEnvelopeFailsClosedWithoutDeletingEvidence()
        async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let fileURL = root.appending(path: "private-cleanup-v1.json")
        let unsupportedData = try unsupportedEnvelopeData(
            scope: try scope(character: "b")
        )
        try unsupportedData.write(to: fileURL, options: [.atomic])
        let journal = ProtectedFilePrivateCleanupJournal(fileURL: fileURL)

        await assertJournalUnavailable {
            _ = try await journal.load()
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try Data(contentsOf: fileURL), unsupportedData)
    }

    func testUnsupportedPlanCannotReplaceDurableSupportedPlan()
        async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "private-cleanup-v1.json")
        let journal = ProtectedFilePrivateCleanupJournal(fileURL: fileURL)
        let supportedPlan = PrivateCleanupPlan(
            operationID: UUID(
                uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
            )!,
            intent: .signOut,
            stage: .localCleanup,
            scope: try scope(character: "c")
        )
        try await journal.save(supportedPlan)
        let durableData = try Data(contentsOf: fileURL)
        let unsupportedPlan = PrivateCleanupPlan(
            schemaVersion:
                ProtectedFilePrivateCleanupJournal.currentSchemaVersion + 1,
            operationID: supportedPlan.operationID,
            intent: supportedPlan.intent,
            stage: supportedPlan.stage,
            scope: supportedPlan.scope
        )

        await assertJournalUnavailable {
            try await journal.save(unsupportedPlan)
        }

        XCTAssertEqual(try Data(contentsOf: fileURL), durableData)
        let reloadedSupportedPlan = try await journal.load()
        XCTAssertEqual(reloadedSupportedPlan, supportedPlan)
    }

    func testSaveUsesProtectedBackupExcludedAtomicReplacement()
        async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "private-cleanup-v1.json")
        let journal = ProtectedFilePrivateCleanupJournal(fileURL: fileURL)
        let firstPlan = PrivateCleanupPlan(
            intent: .signOut,
            stage: .localCleanup,
            scope: try scope(character: "d")
        )
        let replacementPlan = PrivateCleanupPlan(
            operationID: firstPlan.operationID,
            intent: .signOut,
            stage: .localCleanup,
            scope: try scope(character: "e")
        )

        try await journal.save(firstPlan)
        try await journal.save(replacementPlan)

        let reloadedReplacementPlan = try await journal.load()
        XCTAssertEqual(reloadedReplacementPlan, replacementPlan)
        let directoryEntries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(directoryEntries.map(\.lastPathComponent), [
            fileURL.lastPathComponent
        ])
        let fileValues = try fileURL.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        )
        let directoryValues = try root.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        )
        XCTAssertEqual(fileValues.isExcludedFromBackup, true)
        XCTAssertEqual(directoryValues.isExcludedFromBackup, true)

        #if os(iOS) && !targetEnvironment(simulator)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )
        XCTAssertEqual(
            attributes[.protectionKey] as? FileProtectionType,
            .completeUntilFirstUserAuthentication
        )
        #endif
    }

    func testWriteFailureLeavesBlockingPathAndCreatesNoJournal()
        async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let blockingURL = root.appending(path: "not-a-directory")
        let blockingData = Data("retain me".utf8)
        try blockingData.write(to: blockingURL, options: [.atomic])
        let fileURL = blockingURL.appending(path: "private-cleanup-v1.json")
        let journal = ProtectedFilePrivateCleanupJournal(fileURL: fileURL)
        let plan = PrivateCleanupPlan(
            intent: .signOut,
            stage: .localCleanup,
            scope: try scope(character: "f")
        )

        do {
            try await journal.save(plan)
            XCTFail("A journal cannot be written through a regular file.")
        } catch {
            // The precise Cocoa error varies by simulator/runtime. The durable
            // privacy contract is that no partial journal replaces the blocker.
        }

        XCTAssertEqual(try Data(contentsOf: blockingURL), blockingData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    private func assertJournalUnavailable(
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail(
                "Expected cleanupJournalUnavailable.",
                file: file,
                line: line
            )
        } catch let error as LocalDataCleanupError {
            guard case .cleanupJournalUnavailable = error else {
                XCTFail(
                    "Unexpected cleanup error: \(error)",
                    file: file,
                    line: line
                )
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func unsupportedEnvelopeData(
        scope: PrincipalScope
    ) throws -> Data {
        let plan = PrivateCleanupPlan(
            operationID: UUID(
                uuidString: "99999999-8888-4777-8666-555555555555"
            )!,
            intent: .delete,
            stage: .serverDeletionPending,
            scope: scope
        )
        let encodedPlan = try JSONEncoder().encode(plan)
        let planObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedPlan)
                as? [String: Any]
        )
        return try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion":
                    ProtectedFilePrivateCleanupJournal.currentSchemaVersion
                        + 1,
                "plan": planObject
            ],
            options: [.sortedKeys]
        )
    }

    private func scope(character: Character) throws -> PrincipalScope {
        try PrincipalScope(
            validating: String(repeating: character, count: 64)
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "ProtectedFilePrivateCleanupJournalTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }
}
