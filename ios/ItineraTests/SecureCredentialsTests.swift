import Foundation
import XCTest
@testable import Itinera

final class SecureCredentialsTests: XCTestCase {
    func testLegacyCredentialRecordDecodesWithoutUserID() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let credentials = try decoder.decode(
            AuthCredentials.self,
            from: Data(
                """
                {
                  "accessToken": "legacy-access",
                  "refreshToken": "legacy-refresh",
                  "tokenType": "bearer",
                  "expiresAt": "2030-01-01T00:00:00Z"
                }
                """.utf8
            )
        )

        XCTAssertEqual(credentials.accessToken, "legacy-access")
        XCTAssertNil(credentials.userID)
    }

    func testCredentialRecordRoundTripsServerUserID() throws {
        let credentials = AuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            tokenType: "bearer",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            userID: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let encoded = try encoder.encode(credentials)
        let decoded = try decoder.decode(AuthCredentials.self, from: encoded)

        XCTAssertEqual(decoded, credentials)
    }

    func testKeychainRefusesToWriteCredentialWithoutCanonicalUserID() async throws {
        let store = KeychainCredentialStore(
            service: "com.itinera.tests.invalid-credential.\(UUID().uuidString)"
        )
        let legacy = AuthCredentials(
            accessToken: "legacy-access",
            refreshToken: "legacy-refresh",
            tokenType: "bearer",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        do {
            try await store.saveCredentials(legacy)
            XCTFail("A new Keychain write must include a canonical server user_id")
        } catch let error as KeychainError {
            XCTAssertEqual(error, .invalidData)
        }
    }
}
