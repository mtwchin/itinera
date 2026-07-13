import XCTest
@testable import Itinera

@MainActor
final class PrivateIdentityPresentationTests: XCTestCase {
    func testOfflineEmptyCopyDoesNotClaimTheServerLibraryIsEmpty() {
        let state = PrivateLibraryEmptyState.noOfflineTrips

        XCTAssertEqual(state.title, "No trips saved offline")
        XCTAssertTrue(state.message.contains("Connect to the internet"))
        XCTAssertTrue(state.message.contains("check this private library"))
        XCTAssertTrue(state.message.contains("server"))
        XCTAssertFalse(state.message.localizedCaseInsensitiveContains("first trip"))
        XCTAssertEqual(state.actionTitle, "Check Server Again")
    }

    func testConfirmedEmptyCopyIsDistinctFromOfflineEmptyCopy() {
        let state = PrivateLibraryEmptyState.serverConfirmedEmpty

        XCTAssertEqual(state.title, "Your atlas is still empty")
        XCTAssertEqual(state.actionTitle, "Plan your first trip")
        XCTAssertNotEqual(
            state.message,
            PrivateLibraryEmptyState.noOfflineTrips.message
        )
    }

    func testDeleteCopyNamesDataThatRemainsOutsideItinera() {
        let copy = SettingsPrivacyCopy.deleteConfirmationMessage

        XCTAssertTrue(copy.contains("Calendar events"))
        XCTAssertTrue(copy.contains("exported PDFs"))
        XCTAssertTrue(copy.contains("files or text"))
        XCTAssertTrue(copy.contains("previously shared"))
        XCTAssertTrue(SettingsPrivacyCopy.deleteRowDetail.contains("remain"))
        XCTAssertTrue(
            PrivateIdentityOutcome.accountDeleted.message.contains("remain")
        )
        XCTAssertTrue(
            SettingsPrivacyCopy.deleteRecoveryRequiredDetail.contains(
                "Restore this same server session"
            )
        )
    }

    func testAppleRecoveryCopyExplicitlyDisclaimsCloudSyncAndMerging() {
        XCTAssertTrue(
            SettingsPrivacyCopy.appleRecovery
                .localizedCaseInsensitiveContains("does not enable cloud sync")
        )
        XCTAssertTrue(SettingsPrivacyCopy.appleRecovery.contains("iCloud"))
        XCTAssertTrue(SettingsPrivacyCopy.appleRecovery.contains("never merges"))
        XCTAssertTrue(SettingsPrivacyCopy.appleConflict.contains("not merged"))
    }

    func testDeletionRecoveryIsRetryableButNeverPresentsPrivateContent() {
        let phase = PrivateIdentityPhase.cleanupRequired(
            intent: .delete,
            stage: .serverDeletionPending,
            message: "Deletion remains journaled."
        )
        let view = PrivateIdentityStatusView(phase: phase, onRetry: {})

        XCTAssertFalse(phase.presentsPrivateContent)
        XCTAssertFalse(view.isWorking)
        XCTAssertEqual(view.title, "Deletion needs your attention")
        XCTAssertEqual(view.retryTitle, "Resume Deletion")
        XCTAssertTrue(view.retryHint.contains("same Itinera account"))
    }

    func testRejectedDeletionRequiresReverificationWithoutRetryLoop() {
        let phase = PrivateIdentityPhase.cleanupBlocked(
            intent: .delete,
            stage: .serverDeletionPending,
            message: "Account re-verification is required; contact support."
        )
        let view = PrivateIdentityStatusView(phase: phase, onRetry: {})

        XCTAssertFalse(phase.presentsPrivateContent)
        XCTAssertFalse(view.isWorking)
        XCTAssertFalse(view.allowsRetry)
        XCTAssertTrue(view.needsSupport)
        XCTAssertEqual(view.supportURL, PrivateIdentitySupport.defaultURL)
        XCTAssertEqual(view.title, "Account re-verification required")
        XCTAssertTrue(view.message.contains("contact support"))
    }

    func testResumingCleanupAndSignOutExposeTruthfulWorkingCopy() {
        let resuming = PrivateIdentityStatusView(
            phase: .resumingCleanup(
                intent: .delete,
                stage: .localCleanup
            )
        )
        let signingOut = PrivateIdentityStatusView(phase: .signingOut)

        XCTAssertTrue(resuming.isWorking)
        XCTAssertFalse(resuming.phase.presentsPrivateContent)
        XCTAssertTrue(resuming.message.contains("Calendar events"))
        XCTAssertTrue(signingOut.isWorking)
        XCTAssertTrue(signingOut.message.contains("Server data is not being deleted"))
    }

    func testClearDownloadsAndReplacementSessionHaveDistinctTruthfulCopy() {
        let clearing = PrivateIdentityStatusView(phase: .clearingDownloads)
        let signOutReplacement = PrivateIdentityStatusView(
            phase: .creatingReplacementSession(intent: .signOut)
        )
        let deleteReplacement = PrivateIdentityStatusView(
            phase: .creatingReplacementSession(intent: .delete)
        )

        XCTAssertTrue(clearing.isWorking)
        XCTAssertEqual(clearing.title, "Clearing downloaded trips")
        XCTAssertTrue(clearing.message.contains("Server copies are not being deleted"))
        XCTAssertFalse(clearing.message.contains("merged"))
        XCTAssertTrue(signOutReplacement.isWorking)
        XCTAssertTrue(signOutReplacement.message.contains("Server data was not deleted"))
        XCTAssertTrue(deleteReplacement.message.contains("deleted Itinera account stays closed"))
        XCTAssertTrue(deleteReplacement.message.contains("no library is being restored or merged"))
    }

    func testSettingsBusyOperationsHaveVisibleSpecificStatusCopy() {
        XCTAssertEqual(
            SettingsBusyOperation.deletingData.title,
            "Deleting your Itinera account and app data"
        )
        XCTAssertEqual(
            SettingsBusyOperation.signingOut.title,
            "Signing out on this iPhone"
        )
        XCTAssertNotEqual(
            SettingsBusyOperation.deletingData.title,
            SettingsBusyOperation.signingOut.title
        )
    }
}
