import Foundation
import XCTest
@testable import Itinera

final class AuthCredentialsTests: XCTestCase {
    func testLegacyCredentialRecordDecodesWithoutPrincipalIdentifier() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let credentials = try decoder.decode(
            AuthCredentials.self,
            from: Data(
                """
                {
                  "accessToken": "access-1",
                  "refreshToken": "refresh-1",
                  "tokenType": "bearer",
                  "expiresAt": "2026-07-16T00:00:00Z"
                }
                """.utf8
            )
        )

        XCTAssertNil(credentials.userID)
    }
}
