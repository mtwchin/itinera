import CryptoKit
import Foundation
import SwiftUI

enum PrincipalIdentityError: LocalizedError, Equatable, Sendable {
    case invalidServerIdentifier

    var errorDescription: String? {
        switch self {
        case .invalidServerIdentifier:
            return "The server returned an invalid private-library identity."
        }
    }
}

/// The server-issued identifier stays inside the credential/session boundary.
/// All local and system-surface ownership uses only `scope`.
struct PrincipalIdentity: Equatable, Sendable {
    private static let digestDomain = "itinera-principal-scope-v1\0"

    let serverUserID: String
    let scope: PrincipalScope

    init(serverUserID: String) throws {
        guard let uuid = UUID(uuidString: serverUserID) else {
            throw PrincipalIdentityError.invalidServerIdentifier
        }
        let canonicalID = uuid.uuidString.lowercased()
        let digest = SHA256.hash(
            data: Data((Self.digestDomain + canonicalID).utf8)
        ).map { String(format: "%02x", $0) }.joined()
        self.serverUserID = canonicalID
        scope = try PrincipalScope(validating: digest)
    }
}

struct IdentityLease: Equatable, Sendable {
    let scope: PrincipalScope
    let epoch: UInt64
    let presentationSessionID: UUID

    var presentationSession: PrivatePresentationSession {
        PrivatePresentationSession(
            scope: scope,
            id: presentationSessionID
        )
    }
}

/// A short-lived capability proving that ordinary server work is currently
/// permitted for one exact identity presentation. Recovery pauses replace the
/// readiness identifier even when the same principal remains established, so
/// a suspended queue write cannot commit after server trust is lost.
struct PrivateServerOperationLease: Equatable, Sendable {
    let identityLease: IdentityLease
    let readinessID: UUID
}

/// Capability for one explicit recovery attempt. Entering recovery retires
/// the paused request generation's boundary authority immediately; only this
/// exact attempt may resume ordinary server operations.
struct PrivateServerRecoveryLease: Equatable, Sendable {
    let identityLease: IdentityLease
    let pausedReadinessID: UUID
    let recoveryID: UUID
}

/// The exact result of replacing the local actors for one established
/// principal. Server readiness is captured in the same coordinator turn that
/// invalidates the old lease, so a recovery pause cannot be lost between a
/// validation and the transition.
struct IdentityReestablishmentTransition: Equatable, Sendable {
    let epoch: UInt64
    let requiresServerRecovery: Bool
}

/// Immutable capability handed to one keyed private view tree. Callers must
/// capture this value before starting work; AppState rejects it after any
/// transition, including A → B → A.
struct PrivateAppSession: Equatable, Sendable {
    let lease: IdentityLease

    var presentationSession: PrivatePresentationSession {
        lease.presentationSession
    }
}

enum PrivateIdentityOutcome: Equatable, Sendable {
    case serverSessionRestored(isOffline: Bool)
    case downloadsCleared
    case downloadsPartiallyCleared
    case signedOut
    case accountDeleted
    case appleAccountLinked
    case appleLibrarySwitched

    var message: String {
        switch self {
        case .serverSessionRestored(let isOffline):
            return isOffline
                ? "This server session is restored. The latest trip refresh could not finish, so Itinera is still showing this iPhone's offline copy."
                : "This private library's server session and trip list are available again."
        case .downloadsCleared:
            return "Downloaded trips and progress were removed from this iPhone. Server copies were not deleted."
        case .downloadsPartiallyCleared:
            return "Some downloaded trip data could not be removed. This private library remains open; try clearing downloads again."
        case .signedOut:
            return "Signed out on this iPhone and opened a separate guest library. The previous server account was not deleted."
        case .accountDeleted:
            return "The Itinera server account and this account's private app data on this iPhone were deleted. Calendar events, exported PDFs, files or text, and prior shares remain and must be removed separately."
        case .appleAccountLinked:
            return "This private library is linked to Apple for future sign-in. This iPhone's offline app data stays on this iPhone and was not cloud-synced."
        case .appleLibrarySwitched:
            return "The existing Apple library is open. The previous library was not deleted; libraries stayed separate and no device data was cloud-synced or merged."
        }
    }
}

private struct PrivateAppSessionEnvironmentKey: EnvironmentKey {
    static let defaultValue: PrivateAppSession? = nil
}

extension EnvironmentValues {
    var privateAppSession: PrivateAppSession? {
        get { self[PrivateAppSessionEnvironmentKey.self] }
        set { self[PrivateAppSessionEnvironmentKey.self] = newValue }
    }
}

struct IdentityScopedValue<Value: Sendable>: Sendable {
    let value: Value
    let lease: IdentityLease
}

enum IdentityCoordinatorError: LocalizedError, Equatable, Sendable {
    case identityNotEstablished
    case serverOperationsPaused
    case staleIdentity
    case epochExhausted

    var errorDescription: String? {
        switch self {
        case .identityNotEstablished:
            return "Itinera is still opening your private library."
        case .serverOperationsPaused:
            return "This private library is available offline while its server session is restored."
        case .staleIdentity:
            return "This work belongs to a private library that is no longer active."
        case .epochExhausted:
            return "Itinera could not safely advance the private-library session."
        }
    }
}

/// The single monotonic barrier shared by authentication, stores, UI
/// publication, and external surfaces.
actor IdentityCoordinator {
    private enum ServerOperationState: Equatable {
        case ready(UUID)
        case paused(UUID)
        case recovering(readinessID: UUID, recoveryID: UUID)

        var readinessID: UUID {
            switch self {
            case .ready(let readinessID), .paused(let readinessID),
                 .recovering(let readinessID, _):
                return readinessID
            }
        }
    }

    private var epoch: UInt64
    private var establishedScope: PrincipalScope?
    private var presentationSessionID: UUID?
    private var serverOperationState: ServerOperationState?
    private var isPermanentlyInvalidated = false

    init(
        initialScope: PrincipalScope? = nil,
        initialEpoch: UInt64 = 0,
        initialPresentationSessionID: UUID? = nil,
        initialServerOperationReadinessID: UUID? = nil
    ) {
        epoch = initialEpoch
        establishedScope = initialScope
        presentationSessionID = initialScope == nil
            ? nil
            : initialPresentationSessionID ?? UUID()
        serverOperationState = initialScope.map { _ in
            .ready(initialServerOperationReadinessID ?? UUID())
        }
    }

    func beginTransition() throws -> UInt64 {
        guard !isPermanentlyInvalidated,
              epoch < UInt64.max else {
            throw IdentityCoordinatorError.epochExhausted
        }
        epoch += 1
        establishedScope = nil
        presentationSessionID = nil
        serverOperationState = nil
        return epoch
    }

    /// Invalidates one exact presentation while carrying its server-readiness
    /// disposition into a same-principal replacement. `requiringServerRecovery`
    /// covers an APIClient recovery latch that linearized immediately before
    /// authentication cancellation; the coordinator's own state covers a
    /// pause that linearized before this actor turn.
    func beginReestablishment(
        ifCurrent lease: IdentityLease,
        requiringServerRecovery: Bool
    ) throws -> IdentityReestablishmentTransition {
        try validate(lease)
        let coordinatorRequiresRecovery: Bool
        switch serverOperationState {
        case .ready:
            coordinatorRequiresRecovery = false
        case .paused, .recovering:
            coordinatorRequiresRecovery = true
        case nil:
            throw IdentityCoordinatorError.staleIdentity
        }
        let transitionEpoch = try beginTransition()
        return IdentityReestablishmentTransition(
            epoch: transitionEpoch,
            requiresServerRecovery: requiringServerRecovery
                || coordinatorRequiresRecovery
        )
    }

    /// Permanently removes the current lease when the monotonic counter can no
    /// longer advance. This fail-closed terminal path prevents retained store
    /// actors from committing under the last established epoch.
    func invalidateCurrent() {
        isPermanentlyInvalidated = true
        establishedScope = nil
        presentationSessionID = nil
        serverOperationState = nil
    }

    func establish(
        _ scope: PrincipalScope,
        presentationSessionID: UUID,
        at transitionEpoch: UInt64,
        requiresServerRecovery: Bool = false
    ) throws -> IdentityLease {
        guard !isPermanentlyInvalidated,
              transitionEpoch == epoch else {
            throw IdentityCoordinatorError.staleIdentity
        }
        establishedScope = scope
        self.presentationSessionID = presentationSessionID
        let readinessID = UUID()
        serverOperationState = requiresServerRecovery
            ? .paused(readinessID)
            : .ready(readinessID)
        return IdentityLease(
            scope: scope,
            epoch: epoch,
            presentationSessionID: presentationSessionID
        )
    }

    func currentLease() throws -> IdentityLease {
        guard !isPermanentlyInvalidated,
              let establishedScope,
              let presentationSessionID else {
            throw IdentityCoordinatorError.identityNotEstablished
        }
        return IdentityLease(
            scope: establishedScope,
            epoch: epoch,
            presentationSessionID: presentationSessionID
        )
    }

    func validate(_ lease: IdentityLease) throws {
        guard !isPermanentlyInvalidated,
              lease.epoch == epoch,
              lease.scope == establishedScope,
              lease.presentationSessionID == presentationSessionID else {
            throw IdentityCoordinatorError.staleIdentity
        }
    }

    /// Captures the exact server-readiness generation for an ordinary private
    /// operation. Local offline reads and identity-only writes do not require
    /// this additional capability.
    func captureServerOperationLease(
        ifCurrent identityLease: IdentityLease
    ) throws -> PrivateServerOperationLease {
        try validate(identityLease)
        guard case .ready(let readinessID) = serverOperationState else {
            throw IdentityCoordinatorError.serverOperationsPaused
        }
        return PrivateServerOperationLease(
            identityLease: identityLease,
            readinessID: readinessID
        )
    }

    /// Invalidates every captured ordinary-server capability while preserving
    /// the established principal for safe offline use. Retaining the paused
    /// generation lets a second exact boundary failure raise the privacy
    /// curtain while ensuring an older generation cannot pause a recovered
    /// session.
    func pauseServerOperations(
        ifCurrent lease: PrivateServerOperationLease
    ) throws {
        try validateBoundary(lease)
        serverOperationState = .paused(lease.readinessID)
    }

    /// Retires every paused-generation response before explicit recovery
    /// touches Keychain or the network.
    func beginServerRecovery(
        ifCurrent lease: IdentityLease
    ) throws -> PrivateServerRecoveryLease {
        try validate(lease)
        guard case .paused(let readinessID) = serverOperationState else {
            throw IdentityCoordinatorError.staleIdentity
        }
        let recoveryID = UUID()
        serverOperationState = .recovering(
            readinessID: readinessID,
            recoveryID: recoveryID
        )
        return PrivateServerRecoveryLease(
            identityLease: lease,
            pausedReadinessID: readinessID,
            recoveryID: recoveryID
        )
    }

    /// A failed/cancelled recovery returns to the same paused generation so a
    /// later user retry can obtain a fresh recovery capability.
    func finishServerRecoveryFailure(
        ifCurrent lease: PrivateServerRecoveryLease
    ) throws {
        try validateRecovery(lease)
        serverOperationState = .paused(lease.pausedReadinessID)
    }

    func validateServerRecoveryRequired(
        ifCurrent lease: IdentityLease
    ) throws {
        try validate(lease)
        guard case .paused = serverOperationState else {
            throw IdentityCoordinatorError.staleIdentity
        }
    }

    /// Creates a fresh generation only after same-principal server recovery is
    /// explicitly verified by the lifecycle owner.
    func resumeServerOperations(
        ifCurrent lease: PrivateServerRecoveryLease
    ) throws -> PrivateServerOperationLease {
        try validateRecovery(lease)
        let readinessID = UUID()
        serverOperationState = .ready(readinessID)
        return PrivateServerOperationLease(
            identityLease: lease.identityLease,
            readinessID: readinessID
        )
    }

    private func validateRecovery(
        _ lease: PrivateServerRecoveryLease
    ) throws {
        try validate(lease.identityLease)
        guard case .recovering(let readinessID, let recoveryID) =
                serverOperationState,
              readinessID == lease.pausedReadinessID,
              recoveryID == lease.recoveryID else {
            throw IdentityCoordinatorError.staleIdentity
        }
    }

    func validate(_ serverOperationLease: PrivateServerOperationLease) throws {
        try validate(serverOperationLease.identityLease)
        guard case .ready(let readinessID) = serverOperationState,
              serverOperationLease.readinessID == readinessID else {
            throw IdentityCoordinatorError.staleIdentity
        }
    }

    /// Accepts a response from the exact generation that is either still
    /// ready or was paused by a sibling failure. This is only for classifying
    /// recovery/integrity boundaries; ordinary commits require `validate`.
    func validateBoundary(
        _ serverOperationLease: PrivateServerOperationLease
    ) throws {
        try validate(serverOperationLease.identityLease)
        guard serverOperationState == .ready(
            serverOperationLease.readinessID
        ) || serverOperationState == .paused(
            serverOperationLease.readinessID
        ) else {
            throw IdentityCoordinatorError.staleIdentity
        }
    }

    /// Linearizes a synchronous private-state commit against identity
    /// transitions. The operation must contain the actual file/defaults
    /// replacement; staging and encoding can happen before entering.
    func commit<Value: Sendable>(
        ifCurrent lease: IdentityLease,
        _ operation: () throws -> Value
    ) throws -> Value {
        try validate(lease)
        return try operation()
    }

    /// Linearizes a pending-job/submission mutation against both identity
    /// transitions and recovery pauses.
    func commit<Value: Sendable>(
        ifServerOperationCurrent lease: PrivateServerOperationLease,
        _ operation: () throws -> Value
    ) throws -> Value {
        try validate(lease)
        return try operation()
    }

    /// Authorizes destructive transition cleanup after `beginTransition` has
    /// invalidated the previous lease and before another lease is established.
    func commit<Value: Sendable>(
        ifTransition transitionEpoch: UInt64,
        _ operation: () throws -> Value
    ) throws -> Value {
        try validateTransition(epoch: transitionEpoch)
        return try operation()
    }

    func validateTransition(epoch transitionEpoch: UInt64) throws {
        guard !isPermanentlyInvalidated,
              transitionEpoch == epoch,
              establishedScope == nil,
              presentationSessionID == nil,
              serverOperationState == nil else {
            throw IdentityCoordinatorError.staleIdentity
        }
    }

    func isCurrent(_ lease: IdentityLease) -> Bool {
        !isPermanentlyInvalidated
            && lease.epoch == epoch
            && lease.scope == establishedScope
            && lease.presentationSessionID == presentationSessionID
    }

    func isCurrentTransition(epoch transitionEpoch: UInt64) -> Bool {
        !isPermanentlyInvalidated
            && transitionEpoch == epoch
            && establishedScope == nil
            && presentationSessionID == nil
            && serverOperationState == nil
    }

    func currentEpoch() -> UInt64 {
        epoch
    }
}
