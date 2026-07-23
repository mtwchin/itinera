import XCTest
@testable import Itinera

final class APIConfigurationTests: XCTestCase {
    func testMissingServiceAddressReturnsRecoverableConfigurationError() {
        XCTAssertThrowsError(
            try APIConfiguration.configured(
                baseURLValue: nil,
                allowsInsecureLocalhost: false
            )
        ) { error in
            XCTAssertEqual(error as? APIConfigurationError, .missingBaseURL)
        }
    }

    func testInvalidServiceAddressReturnsRecoverableConfigurationError() {
        XCTAssertThrowsError(
            try APIConfiguration.configured(
                baseURLValue: "http://api.example.test",
                allowsInsecureLocalhost: false
            )
        ) { error in
            XCTAssertEqual(error as? APIConfigurationError, .invalidBaseURL)
        }
    }

    func testReleaseConfigurationAcceptsHTTPSAddress() throws {
        let configuration = try APIConfiguration.configured(
            baseURLValue: "https://api.example.test",
            allowsInsecureLocalhost: false
        )

        XCTAssertEqual(configuration.baseURL, URL(string: "https://api.example.test"))
    }
}
