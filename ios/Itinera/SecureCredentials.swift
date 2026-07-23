import Foundation
import Security

struct AuthCredentials: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let expiresAt: Date
    /// Optional for backward-compatible decoding of credentials saved before
    /// the client persisted the server's stable principal identifier.
    let userID: String?

    init(
        accessToken: String,
        refreshToken: String,
        tokenType: String,
        expiresAt: Date,
        userID: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiresAt = expiresAt
        self.userID = userID
    }

    func isExpired(at date: Date, leeway: TimeInterval = 30) -> Bool {
        expiresAt <= date.addingTimeInterval(leeway)
    }
}

protocol CredentialStoring: Sendable {
    func loadCredentials() async throws -> AuthCredentials?
    func saveCredentials(_ credentials: AuthCredentials) async throws
    func clearCredentials() async throws
    /// Removes all account-linkable client state after a confirmed deletion.
    func clearAccountState() async throws
    func installationIdentifier() async throws -> String
}

enum KeychainError: LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "The secure credential store returned error \(status)."
        case .invalidData:
            return "The secure credential store contained invalid data."
        }
    }
}

actor KeychainCredentialStore: CredentialStoring {
    private enum Account {
        static let credentials = "auth-credentials"
        static let installationID = "installation-id"
    }

    private let service: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(service: String = Bundle.main.bundleIdentifier ?? "com.itinera.app") {
        self.service = service
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadCredentials() throws -> AuthCredentials? {
        guard let data = try read(account: Account.credentials) else { return nil }
        do {
            return try decoder.decode(AuthCredentials.self, from: data)
        } catch {
            throw KeychainError.invalidData
        }
    }

    func saveCredentials(_ credentials: AuthCredentials) throws {
        try write(try encoder.encode(credentials), account: Account.credentials)
    }

    func clearCredentials() throws {
        try delete(account: Account.credentials)
    }

    func clearAccountState() throws {
        // Delete the pseudonymous identifier first. If that fails, retain the
        // deletion replay credential; there is no operation after deleting
        // credentials that can safely recover it.
        try delete(account: Account.installationID)
        try clearCredentials()
    }

    func installationIdentifier() throws -> String {
        if let data = try read(account: Account.installationID),
           let identifier = String(data: data, encoding: .utf8),
           UUID(uuidString: identifier) != nil {
            return identifier
        }

        let identifier = UUID().uuidString.lowercased()
        guard let data = identifier.data(using: .utf8) else {
            throw KeychainError.invalidData
        }
        try write(data, account: Account.installationID)
        return identifier
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.invalidData }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func write(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var newItem = query
        newItem[kSecValueData as String] = data
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
