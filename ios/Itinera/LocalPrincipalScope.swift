import CryptoKit
import Foundation

/// An opaque, versioned namespace for private device-local state.
///
/// The server UUID is never placed in a file path or UserDefaults key. Changing
/// the namespace version is an explicit storage migration boundary.
struct LocalPrincipalScope: Hashable, Sendable {
    private static let namespaceVersion = "private-state-v1"

    let digest: String

    init?(userID: String) {
        guard let userID = UUID(uuidString: userID) else { return nil }
        let normalized = userID.uuidString.lowercased()
        digest = SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func directory(root: URL) -> URL {
        root
            .appending(path: "Itinera", directoryHint: .isDirectory)
            .appending(path: Self.namespaceVersion, directoryHint: .isDirectory)
            .appending(path: digest, directoryHint: .isDirectory)
    }

    func fileURL(root: URL, name: String) -> URL {
        directory(root: root).appending(path: name)
    }

    /// Namespaces a UserDefaults key without placing the server UUID in the
    /// defaults database. `name` is an app-defined key, never user input.
    func defaultsKey(name: String) -> String {
        "itinera.\(Self.namespaceVersion).\(digest).\(name)"
    }
}
