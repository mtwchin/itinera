import XCTest

final class ItineraUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testItineraryDemoLaunchesWithoutNetworkState() {
        let app = XCUIApplication()
        app.launchEnvironment["ITINERA_DEMO_SCREEN"] = "itinerary"
        app.launch()

        XCTAssertTrue(
            app.navigationBars["Lisbon, Portugal"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["Tiles, viewpoints & old Lisbon"].exists)
    }

    @MainActor
    func testInvalidConfigurationShowsRecoveryStateInsteadOfCrashing() {
        let app = XCUIApplication()
        app.launchEnvironment["ITINERA_FORCE_CONFIGURATION_FAILURE"] = "1"
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Itinera isn’t ready to open"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts["Install a current copy of Itinera, then try again."].exists
        )
    }

    @MainActor
    func testInviteDeepLinkRequiresExplicitConfirmation() {
        let app = XCUIApplication()
        app.launchEnvironment["ITINERA_TEST_INVITE_TOKEN"] = String(
            repeating: "a",
            count: 64
        )
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Join shared trip?"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["Join trip"].exists)
        XCTAssertTrue(app.buttons["Not now"].exists)
    }
}
