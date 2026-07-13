import Foundation
@testable import Itinera

struct PrivateStorageTestContext {
    let lease: IdentityLease
    let serverOperationLease: PrivateServerOperationLease
    let identityCoordinator: IdentityCoordinator

    init(
        scopeDigest: String = String(repeating: "a", count: 64),
        epoch: UInt64 = 1,
        sessionID: UUID = UUID(
            uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        )!
    ) throws {
        let scope = try PrincipalScope(validating: scopeDigest)
        let readinessID = UUID(
            uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        )!
        lease = IdentityLease(
            scope: scope,
            epoch: epoch,
            presentationSessionID: sessionID
        )
        serverOperationLease = PrivateServerOperationLease(
            identityLease: lease,
            readinessID: readinessID
        )
        identityCoordinator = IdentityCoordinator(
            initialScope: scope,
            initialEpoch: epoch,
            initialPresentationSessionID: sessionID,
            initialServerOperationReadinessID: readinessID
        )
    }

    func completedTripCache(fileURL: URL) -> CompletedTripCache {
        CompletedTripCache(
            fileURL: fileURL,
            lease: lease,
            identityCoordinator: identityCoordinator
        )
    }

    func tripProgressStore(fileURL: URL) -> TripProgressStore {
        TripProgressStore(
            fileURL: fileURL,
            lease: lease,
            identityCoordinator: identityCoordinator
        )
    }

    func pendingJobStore(fileURL: URL) -> PendingJobStore {
        PendingJobStore(
            fileURL: fileURL,
            lease: lease,
            identityCoordinator: identityCoordinator
        )
    }

    func pendingSubmissionStore(fileURL: URL) -> PendingSubmissionStore {
        PendingSubmissionStore(
            fileURL: fileURL,
            lease: lease,
            identityCoordinator: identityCoordinator
        )
    }
}
