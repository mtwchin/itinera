import Foundation
import SwiftUI
import UserNotifications

@main
struct ItineraApp: App {
    @UIApplicationDelegateAdaptor(ItineraAppDelegate.self) private var appDelegate
    @StateObject private var bootstrap: ItineraBootstrap
    @StateObject private var settingsPreferences: SettingsPreferences

    init() {
        _bootstrap = StateObject(wrappedValue: ItineraBootstrap())
        _settingsPreferences = StateObject(wrappedValue: SettingsPreferences())
    }

    var body: some Scene {
        WindowGroup {
            if let appState = bootstrap.appState {
                ItineraRootView(
                    appState: appState,
                    settingsPreferences: settingsPreferences
                )
            } else {
                StartupConfigurationFailureView(
                    message: bootstrap.errorMessage
                )
            }
        }
    }
}

@MainActor
private final class ItineraBootstrap: ObservableObject {
    let appState: AppState?
    let errorMessage: String

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["ITINERA_FORCE_CONFIGURATION_FAILURE"] == "1" {
            appState = nil
            errorMessage = "This build is missing its Itinera service address."
            return
        }
        #endif
        do {
            appState = try AppState.live()
            errorMessage = ""
        } catch {
            appState = nil
            errorMessage = error.localizedDescription
        }
    }
}

private struct StartupConfigurationFailureView: View {
    let message: String
    @Environment(\.colorScheme) private var colorScheme

    private var theme: ItineraTheme {
        ItineraTheme.resolved(
            for: colorScheme,
            aestheticOverride: ItineraAesthetic.environmentOverride
        )
    }

    var body: some View {
        ZStack {
            ItineraBackground()
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(theme.warning)
                    .accessibilityHidden(true)
                Text("Itinera isn’t ready to open")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(message)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                Text("Install a current copy of Itinera, then try again.")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(28)
            .frame(maxWidth: 420)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .stroke(theme.border.opacity(0.5), lineWidth: 1)
            }
            .padding(24)
            .accessibilityElement(children: .combine)
        }
        .environment(\.itineraTheme, theme)
        .foregroundStyle(theme.primaryText)
    }
}

private struct ItineraRootView: View {
    @Environment(\.colorScheme) private var systemColorScheme
    @ObservedObject var appState: AppState
    @ObservedObject var settingsPreferences: SettingsPreferences

    private var aestheticOverride: ItineraAesthetic? {
        ItineraAesthetic.environmentOverride
    }

    private var preferredColorScheme: ColorScheme? {
        aestheticOverride?.theme.preferredColorScheme
            ?? settingsPreferences.appAppearance.preferredColorScheme
    }

    private var effectiveColorScheme: ColorScheme {
        preferredColorScheme ?? systemColorScheme
    }

    private var theme: ItineraTheme {
        ItineraTheme.resolved(
            for: effectiveColorScheme,
            aestheticOverride: aestheticOverride
        )
    }

    var body: some View {
        ContentView()
            .environmentObject(appState)
            .environmentObject(settingsPreferences)
            .environment(\.itineraTheme, theme)
            .tint(theme.accent)
            .preferredColorScheme(preferredColorScheme)
            .task {
                await appState.loadCachedTrips()
                await appState.loadPendingJobs()
                await appState.resumePendingSubmissions()
            }
    }
}

struct ContentView: View {
    private enum Tab: Hashable {
        case today
        case plan
        case popular
        case trips
        case settings
    }

    @Environment(\.itineraTheme) private var theme
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settingsPreferences: SettingsPreferences
    @State private var selectedTab: Tab = .plan
    @State private var deepLinkError: String?
    @State private var pendingInviteToken: String?

    var body: some View {
        #if DEBUG
        debugRoot
        #else
        tabs
        #endif
    }

    @ViewBuilder
    private var tabs: some View {
        TabView(selection: $selectedTab) {
            TodayRootView(
                onPlanTrip: { selectedTab = .plan },
                onOpenTrips: { selectedTab = .trips }
            )
            .tabItem { Label("Today", systemImage: "location.fill.viewfinder") }
            .tag(Tab.today)
            TripFormView()
                .tabItem { Label("Plan", systemImage: "map.fill") }
                .tag(Tab.plan)
            PopularItinerariesView()
                .tabItem { Label("Popular", systemImage: "flame.fill") }
                .tag(Tab.popular)
            SavedTripsView(onPlanTrip: { selectedTab = .plan })
                .tabItem { Label("Trips", systemImage: "suitcase.fill") }
                .tag(Tab.trips)
            NavigationStack {
                SettingsView(
                    preferences: settingsPreferences,
                    actions: SettingsActions(
                        clearLocalTripData: {
                            try await appState.clearDownloadedTripData()
                        },
                        deleteMyData: {
                            try await appState.deleteMyData()
                        },
                        connectAppleAccount: { identityToken in
                            try await appState.connectAppleAccount(
                                identityToken: identityToken
                            )
                        },
                        grantAIConsent: { version in
                            try await appState.grantAIConsent(version: version)
                        },
                        withdrawAIConsent: {
                            try await appState.withdrawAIConsent()
                        }
                    ),
                    showsDoneButton: false
                )
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            .tag(Tab.settings)
        }
        .toolbarBackground(theme.surface.opacity(0.96), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .sensoryFeedback(.selection, trigger: selectedTab)
        .onOpenURL { url in
            Task { await handleDeepLink(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .itineraOpenTrip)) { _ in
            selectedTab = .trips
        }
        .alert("Couldn't open link", isPresented: Binding(
            get: { deepLinkError != nil },
            set: { if !$0 { deepLinkError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deepLinkError ?? "The link is invalid or expired.")
        }
        .confirmationDialog(
            "Join shared trip?",
            isPresented: Binding(
                get: { pendingInviteToken != nil },
                set: { if !$0 { pendingInviteToken = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Join trip") {
                Task { await acceptPendingInvite() }
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Joining lets the trip owner see you as a collaborator. Review the invitation before continuing.")
        }
        #if DEBUG
        .task {
            guard let token = ProcessInfo.processInfo.environment[
                "ITINERA_TEST_INVITE_TOKEN"
            ], let url = URL(string: "itinera://invite/\(token)") else { return }
            await handleDeepLink(url)
        }
        #endif
    }

    @MainActor
    private func handleDeepLink(_ url: URL) async {
        guard url.scheme == "itinera" else { return }
        switch url.host {
        case "trip":
            selectedTab = .trips
        case "invite":
            let token = url.pathComponents.dropFirst().first ?? ""
            guard isValidInviteToken(token) else {
                deepLinkError = "This invitation link is incomplete."
                return
            }
            pendingInviteToken = token
        default:
            deepLinkError = "Itinera doesn't recognize this link."
        }
    }

    private func acceptPendingInvite() async {
        guard let token = pendingInviteToken else { return }
        pendingInviteToken = nil
        do {
            _ = try await appState.apiClient.acceptCollaborationInvite(token: token)
            appState.markLibraryChanged()
            selectedTab = .trips
        } catch {
            deepLinkError = error.localizedDescription
        }
    }

    private func isValidInviteToken(_ token: String) -> Bool {
        token.range(
            of: "^[A-Za-z0-9_-]{32,256}$",
            options: .regularExpression
        ) != nil
    }

    #if DEBUG
    @ViewBuilder
    private var debugRoot: some View {
        let demoScreen = ProcessInfo.processInfo.environment["ITINERA_DEMO_SCREEN"]
        if demoScreen == "itinerary" {
            NavigationStack {
                ItineraryView(itinerary: .preview)
                    .navigationTitle("Lisbon, Portugal")
            }
        } else if demoScreen == "settings" {
            NavigationStack {
                SettingsView(
                    preferences: settingsPreferences,
                    showsDoneButton: false
                )
            }
        } else {
            tabs
        }
    }
    #endif
}

final class ItineraAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.content.userInfo["itinera_job_id"] != nil else {
            return
        }
        NotificationCenter.default.post(name: .itineraOpenTrip, object: nil)
    }
}

extension Notification.Name {
    static let itineraOpenTrip = Notification.Name("ItineraOpenTrip")
}
