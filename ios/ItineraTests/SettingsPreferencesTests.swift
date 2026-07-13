import XCTest
@testable import Itinera

@MainActor
final class SettingsPreferencesTests: XCTestCase {
    func testDefaultsRequireExplicitConsentAndNotificationOptIn() {
        let defaults = makeDefaults()
        let preferences = SettingsPreferences(defaults: defaults)

        XCTAssertFalse(preferences.hasCurrentAIDataConsent)
        XCTAssertEqual(preferences.appAppearance, .system)
        XCTAssertFalse(preferences.generationNotificationsEnabled)
        XCTAssertFalse(preferences.tripRemindersEnabled)
    }

    func testConsentAndNotificationChoicesPersist() {
        let defaults = makeDefaults()
        let preferences = SettingsPreferences(defaults: defaults)
        preferences.acceptCurrentAIDataConsent()
        preferences.appAppearance = .dark
        preferences.generationNotificationsEnabled = true
        preferences.tripRemindersEnabled = true

        let restored = SettingsPreferences(defaults: defaults)
        XCTAssertTrue(restored.hasCurrentAIDataConsent)
        XCTAssertEqual(restored.appAppearance, .dark)
        XCTAssertTrue(restored.generationNotificationsEnabled)
        XCTAssertTrue(restored.tripRemindersEnabled)
    }

    func testOutdatedDisclosureAcceptanceRequiresConsentAgain() {
        let defaults = makeDefaults()
        defaults.set(
            SettingsPreferences.currentConsentVersion - 1,
            forKey: "settings.aiDataConsent.acceptedVersion"
        )

        let preferences = SettingsPreferences(defaults: defaults)

        XCTAssertFalse(preferences.hasCurrentAIDataConsent)
        XCTAssertEqual(
            AIDataDisclosure.current.version,
            SettingsPreferences.currentConsentVersion
        )
    }

    func testResetWithdrawsConsentAndRestoresDefaults() {
        let defaults = makeDefaults()
        let preferences = SettingsPreferences(defaults: defaults)
        preferences.acceptCurrentAIDataConsent()
        preferences.appAppearance = .light
        preferences.generationNotificationsEnabled = true
        preferences.tripRemindersEnabled = true

        preferences.reset()

        XCTAssertFalse(preferences.hasCurrentAIDataConsent)
        XCTAssertEqual(preferences.appAppearance, .system)
        XCTAssertFalse(preferences.generationNotificationsEnabled)
        XCTAssertFalse(preferences.tripRemindersEnabled)
    }

    func testUnknownStoredAppearanceFallsBackToSystem() {
        let defaults = makeDefaults()
        defaults.set("sepia", forKey: "settings.appearance")

        let preferences = SettingsPreferences(defaults: defaults)

        XCTAssertEqual(preferences.appAppearance, .system)
    }

    func testAppearanceMapsToExpectedColorSchemeOverride() {
        XCTAssertNil(AppAppearance.system.preferredColorScheme)
        XCTAssertEqual(AppAppearance.light.preferredColorScheme, .light)
        XCTAssertEqual(AppAppearance.dark.preferredColorScheme, .dark)
    }

    func testThemeResolutionUsesAtlasForLightAndSignalForDark() {
        XCTAssertEqual(
            ItineraTheme.resolved(for: .light, aestheticOverride: nil).name,
            ItineraTheme.atlas.name
        )
        XCTAssertEqual(
            ItineraTheme.resolved(for: .dark, aestheticOverride: nil).name,
            ItineraTheme.signal.name
        )
    }

    func testExplicitAestheticOverrideRemainsDeterministic() {
        for aesthetic in ItineraAesthetic.allCases {
            XCTAssertEqual(
                ItineraTheme.resolved(
                    for: aesthetic == .signal ? .light : .dark,
                    aestheticOverride: aesthetic
                ).name,
                aesthetic.theme.name
            )
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "SettingsPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
