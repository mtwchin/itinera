import Foundation

enum PrincipalScopeValidationError: Error, Equatable, Sendable {
    case invalidScope
}

/// An opaque local ownership label shared by the app and its extensions.
///
/// The digest is suitable for storage routing and system-surface metadata, but
/// remains pseudonymous and must never be displayed or logged.
struct PrincipalScope: Hashable, Sendable {
    static let digestLength = 64

    let digest: String

    init(validating digest: String) throws {
        guard digest.count == Self.digestLength,
              digest.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            throw PrincipalScopeValidationError.invalidScope
        }
        self.digest = digest
    }
}

extension PrincipalScope: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let digest = try container.decode(String.self)
        do {
            try self.init(validating: digest)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Principal scope must be 64 lowercase hexadecimal characters."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(digest)
    }
}

/// Identifies one UI publication lifetime for an established principal.
/// A fresh UUID is required on every establishment, including A → B → A, so
/// delayed work from an earlier lifetime cannot publish into the later one.
struct PrivatePresentationSession: Codable, Hashable, Sendable {
    let scope: PrincipalScope
    let id: UUID

    init(scope: PrincipalScope, id: UUID = UUID()) {
        self.scope = scope
        self.id = id
    }
}
