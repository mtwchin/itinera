import Foundation
import XCTest
@testable import Itinera

final class PrincipalScopeTests: XCTestCase {
    func testPrincipalScopeDigestUsesDomainSeparatedCanonicalUUIDTextVectors() throws {
        let vectors = [
            (
                "00000000-0000-0000-0000-000000000001",
                "c224077163d0ca1d6a6e504eeb417082d2520d788d6e8e37161a3963cebdfd88"
            ),
            (
                "12345678-9ABC-DEF0-1234-56789ABCDEF0",
                "a4a5f7fddc058546772a207bb2a9f7409ba13e32989f9b745460636b5f4c6315"
            ),
        ]

        for (serverUserID, expectedDigest) in vectors {
            let identity = try PrincipalIdentity(serverUserID: serverUserID)

            XCTAssertEqual(identity.scope.digest, expectedDigest)
        }
    }

    func testValidScopeUsesSingleStringCodableRepresentation() throws {
        let digest = String(repeating: "a", count: PrincipalScope.digestLength)
        let scope = try PrincipalScope(validating: digest)

        let data = try JSONEncoder().encode(scope)

        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"\(digest)\"")
        XCTAssertEqual(try JSONDecoder().decode(PrincipalScope.self, from: data), scope)
    }

    func testInitializerRejectsUppercaseWrongLengthAndNonHex() {
        XCTAssertThrowsError(
            try PrincipalScope(
                validating: String(repeating: "A", count: PrincipalScope.digestLength)
            )
        )
        XCTAssertThrowsError(
            try PrincipalScope(
                validating: String(repeating: "a", count: PrincipalScope.digestLength - 1)
            )
        )
        XCTAssertThrowsError(
            try PrincipalScope(
                validating: String(repeating: "g", count: PrincipalScope.digestLength)
            )
        )
    }

    func testDecoderRevalidatesCanonicalDigest() {
        for value in [
            String(repeating: "A", count: PrincipalScope.digestLength),
            String(repeating: "a", count: PrincipalScope.digestLength - 1),
            String(repeating: "z", count: PrincipalScope.digestLength),
        ] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    PrincipalScope.self,
                    from: Data("\"\(value)\"".utf8)
                )
            )
        }
    }
}
