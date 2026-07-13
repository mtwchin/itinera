import Combine
import Foundation
import SwiftUI

enum AppAppearance: String, CaseIterable, Hashable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var detail: String {
        switch self {
        case .system: return "Match this iPhone's appearance"
        case .light: return "Always use the light field guide"
        case .dark: return "Always use the dark field guide"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum SettingsConsentVersion {
    static let current = 2
}

/// Versioned acknowledgement for the data that is sent when Itinera builds a trip.
/// Bump `currentVersion` whenever the disclosure changes in a material way.
@MainActor
final class SettingsPreferences: ObservableObject {
    static let currentConsentVersion = SettingsConsentVersion.current

    private enum Key {
        static let acceptedConsentVersion = "settings.aiDataConsent.acceptedVersion"
        static let appAppearance = "settings.appearance"
        static let generationNotifications = "settings.notifications.generationComplete"
        static let tripReminders = "settings.notifications.tripReminders"
    }

    private let defaults: UserDefaults

    @Published private(set) var acceptedConsentVersion: Int
    @Published var appAppearance: AppAppearance {
        didSet { defaults.set(appAppearance.rawValue, forKey: Key.appAppearance) }
    }
    @Published var generationNotificationsEnabled: Bool {
        didSet { defaults.set(generationNotificationsEnabled, forKey: Key.generationNotifications) }
    }
    @Published var tripRemindersEnabled: Bool {
        didSet { defaults.set(tripRemindersEnabled, forKey: Key.tripReminders) }
    }

    var hasCurrentAIDataConsent: Bool {
        acceptedConsentVersion == Self.currentConsentVersion
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        acceptedConsentVersion = defaults.integer(forKey: Key.acceptedConsentVersion)
        appAppearance = defaults.string(forKey: Key.appAppearance)
            .flatMap(AppAppearance.init(rawValue:))
            ?? .system
        generationNotificationsEnabled = defaults.object(forKey: Key.generationNotifications) as? Bool ?? false
        tripRemindersEnabled = defaults.object(forKey: Key.tripReminders) as? Bool ?? false
    }

    func acceptCurrentAIDataConsent() {
        acceptedConsentVersion = Self.currentConsentVersion
        defaults.set(Self.currentConsentVersion, forKey: Key.acceptedConsentVersion)
    }

    func withdrawAIDataConsent() {
        acceptedConsentVersion = 0
        defaults.removeObject(forKey: Key.acceptedConsentVersion)
    }

    func reset() {
        withdrawAIDataConsent()
        appAppearance = .system
        generationNotificationsEnabled = false
        tripRemindersEnabled = false
    }
}

struct AIDataDisclosure: Equatable, Sendable {
    let version: Int
    let summary: String
    let sentItems: [String]
    let notSentItems: [String]

    static let current = AIDataDisclosure(
        version: SettingsConsentVersion.current,
        summary: "For hosted generation, Itinera sends the trip details you enter to OpenAI so AI can create your plan. Local development may use a private Ollama model instead.",
        sentItems: [
            "Destination, dates, accommodation, group size, budget, and preferences",
            "The text you enter in food and must-do fields",
        ],
        notSentItems: [
            "Contacts, photos, precise live location, or calendar contents",
            "Data from other apps unless you explicitly share it",
        ]
    )
}
