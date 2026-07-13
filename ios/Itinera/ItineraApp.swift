import Foundation
import SwiftUI
import UIKit
import UserNotifications

@main
struct ItineraApp: App {
    @UIApplicationDelegateAdaptor(ItineraAppDelegate.self) private var appDelegate
    @StateObject private var appState: AppState
    @StateObject private var settingsPreferences: SettingsPreferences

    init() {
        _appState = StateObject(wrappedValue: AppState.live())
        _settingsPreferences = StateObject(wrappedValue: SettingsPreferences())
    }

    var body: some Scene {
        WindowGroup {
            ItineraRootView(
                appState: appState,
                settingsPreferences: settingsPreferences
            )
        }
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
        Group {
            if appState.identityPhase.presentsPrivateContent,
               let privateAppSession = appState.privateAppSession {
                ContentView()
                    .id(appState.identityEpoch)
                    .environment(\.privateAppSession, privateAppSession)
            } else {
                PrivateIdentityStatusView(
                    phase: appState.identityPhase,
                    onRetry: appState.canRetryIdentityBootstrap
                        ? {
                            Task {
                                await appState.bootstrapIdentity(isRetry: true)
                            }
                        }
                        : nil
                )
            }
        }
            .environmentObject(appState)
            .environmentObject(settingsPreferences)
            .environment(\.itineraTheme, theme)
            .tint(theme.accent)
            .preferredColorScheme(preferredColorScheme)
            .task {
                guard appState.identityPhase == .restoring else { return }
                await appState.bootstrapIdentity()
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
    @Environment(\.privateAppSession) private var privateAppSession
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settingsPreferences: SettingsPreferences
    @State private var selectedTab: Tab = .plan
    @State private var deepLinkError: String?
    @State private var pendingInvite: PendingInvite?
    @State private var recoveryError: String?
    @State private var isRetryingRecovery = false
    @State private var isConfirmingRecoverySignOut = false

    private struct PendingInvite: Identifiable {
        let id = UUID()
        let token: String
        let session: PrivateAppSession
    }

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
                        serverSessionNeedsRecovery: {
                            if case .recoveryRequired = appState.identityPhase {
                                return true
                            }
                            return false
                        }(),
                        retryServerSession: {
                            guard let privateAppSession else {
                                throw IdentityCoordinatorError.staleIdentity
                            }
                            try await appState.retryServerSession(
                                session: privateAppSession
                            )
                        },
                        clearLocalTripData: {
                            guard let privateAppSession else {
                                throw IdentityCoordinatorError.staleIdentity
                            }
                            try await appState.clearDownloadedTripData(
                                session: privateAppSession
                            )
                        },
                        signOut: {
                            guard let privateAppSession else {
                                throw IdentityCoordinatorError.staleIdentity
                            }
                            try await appState.signOut(
                                session: privateAppSession
                            )
                        },
                        deleteMyData: {
                            guard let privateAppSession else {
                                throw IdentityCoordinatorError.staleIdentity
                            }
                            try await appState.deleteMyData(
                                session: privateAppSession
                            )
                        },
                        supportURL: PrivateIdentitySupport.defaultURL,
                        validatePrivateSession: {
                            guard let privateAppSession else { return false }
                            return await appState.isCurrent(privateAppSession)
                        },
                        connectAppleAccount: { identityToken in
                            guard let privateAppSession else {
                                throw IdentityCoordinatorError.staleIdentity
                            }
                            return try await appState.connectAppleAccount(
                                identityToken: identityToken,
                                session: privateAppSession
                            )
                        },
                        switchToAppleAccount: { identityToken in
                            guard let privateAppSession else {
                                throw IdentityCoordinatorError.staleIdentity
                            }
                            try await appState.switchToAppleAccount(
                                identityToken: identityToken,
                                session: privateAppSession
                            )
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if case .recoveryRequired = appState.identityPhase {
                recoveryBanner
            } else if let identityOutcome = appState.identityOutcome {
                identityOutcomeBanner(identityOutcome)
            }
        }
        .onOpenURL { url in
            Task { await handleDeepLink(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .itineraOpenTrip)) { event in
            guard let session = event.object as? PrivatePresentationSession,
                  appState.isCurrentPresentationSession(session) else {
                return
            }
            selectedTab = .trips
        }
        .confirmationDialog(
            "Accept invitation?",
            isPresented: Binding(
                get: { pendingInvite != nil },
                set: { if !$0 { pendingInvite = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Accept into This Library") {
                guard let invitation = pendingInvite else { return }
                pendingInvite = nil
                Task { await accept(invitation) }
            }
            Button("Cancel", role: .cancel) {
                pendingInvite = nil
            }
        } message: {
            Text("The invitation will be added only to the private library currently open. Libraries are not merged.")
        }
        .confirmationDialog(
            "Sign out of this library?",
            isPresented: $isConfirmingRecoverySignOut,
            titleVisibility: .visible
        ) {
            Button("Sign Out on This iPhone", role: .destructive) {
                Task { await signOutFromRecovery() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes this library's offline device data and starts a separate guest library. Server data is not deleted.")
        }
        .alert("Couldn't open link", isPresented: Binding(
            get: { deepLinkError != nil },
            set: { if !$0 { deepLinkError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deepLinkError ?? "The link is invalid or expired.")
        }
    }

    private func identityOutcomeBanner(
        _ outcome: PrivateIdentityOutcome
    ) -> some View {
        PrivateIdentityOutcomeBanner(
            outcome: outcome,
            onDismiss: appState.dismissIdentityOutcome
        )
    }

    @ViewBuilder
    private var recoveryBanner: some View {
        ServerSessionRecoveryBanner(
            errorMessage: recoveryError,
            isRetrying: isRetryingRecovery,
            onRetry: { Task { await retryRecovery() } },
            onOpenSettings: { selectedTab = .settings },
            onSignOut: { isConfirmingRecoverySignOut = true }
        )
    }

    @MainActor
    private func retryRecovery() async {
        guard let privateAppSession else { return }
        isRetryingRecovery = true
        recoveryError = nil
        defer { isRetryingRecovery = false }
        do {
            try await appState.retryServerSession(
                session: privateAppSession
            )
        } catch {
            guard await appState.isCurrent(privateAppSession) else { return }
            recoveryError = error.localizedDescription
        }
    }

    @MainActor
    private func signOutFromRecovery() async {
        guard let privateAppSession else { return }
        do {
            try await appState.signOut(session: privateAppSession)
        } catch {
            guard await appState.isCurrent(privateAppSession) else { return }
            recoveryError = error.localizedDescription
        }
    }

    @MainActor
    private func handleDeepLink(_ url: URL) async {
        guard url.scheme == "itinera" else { return }
        switch url.host {
        case "trip":
            guard let session = ScopedTripURL.presentationSession(from: url),
                  appState.isCurrentPresentationSession(session) else {
                deepLinkError = "This trip link belongs to a private-library session that is no longer open. Open the trip from Trips instead."
                return
            }
            selectedTab = .trips
        case "invite":
            let token = url.pathComponents.dropFirst().first ?? ""
            guard token.count >= 32 else {
                deepLinkError = "This invitation link is incomplete."
                return
            }
            guard let privateAppSession else {
                deepLinkError = "Wait for your private library to finish opening, then try the invitation again."
                return
            }
            pendingInvite = PendingInvite(
                token: token,
                session: privateAppSession
            )
        default:
            deepLinkError = "Itinera doesn't recognize this link."
        }
    }

    @MainActor
    private func accept(_ invitation: PendingInvite) async {
        do {
            _ = try await appState.acceptCollaborationInvite(
                token: invitation.token,
                session: invitation.session
            )
            guard await appState.isCurrent(invitation.session) else {
                throw IdentityCoordinatorError.staleIdentity
            }
            selectedTab = .trips
        } catch is IdentityCoordinatorError {
            guard await appState.isCurrent(invitation.session) else { return }
            deepLinkError = "The private library changed before the invitation was accepted. Open the link again if you still want to accept it."
        } catch {
            guard await appState.isCurrent(invitation.session) else { return }
            deepLinkError = error.localizedDescription
        }
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

struct PrivateIdentityOutcomeBanner: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.itineraTheme) private var theme

    let outcome: PrivateIdentityOutcome
    let onDismiss: () -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    outcomeMessage
                    dismissButton
                        .frame(maxWidth: .infinity)
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    outcomeMessage
                    Spacer(minLength: 4)
                    dismissButton
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.surface)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .onAppear {
            UIAccessibility.post(
                notification: .announcement,
                argument: outcome.message
            )
        }
        .id(outcome.message)
    }

    private var outcomeMessage: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(theme.success)
                .accessibilityHidden(true)
            Text(outcome.message)
                .font(.subheadline)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dismissButton: some View {
        Button("Dismiss", action: onDismiss)
            .frame(minWidth: 44, minHeight: 44)
            .buttonStyle(.bordered)
    }
}

struct ServerSessionRecoveryBanner: View {
    @Environment(\.itineraTheme) private var theme
    @AccessibilityFocusState private var isStatusFocused: Bool

    let errorMessage: String?
    let isRetrying: Bool
    let onRetry: () -> Void
    let onOpenSettings: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    "Offline library · Server changes paused",
                    systemImage: "exclamationmark.shield.fill"
                )
                .font(.headline)
                .foregroundStyle(theme.primaryText)

                Text(statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Offline library. Server changes paused")
            .accessibilityValue(statusMessage)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($isStatusFocused)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actions }
                VStack(spacing: 8) { actions }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.surface)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .onAppear(perform: focusStatus)
        .onChange(of: errorMessage) { _, _ in
            focusStatus()
        }
    }

    private var statusMessage: String {
        errorMessage
            ?? "Your offline private library remains available on this iPhone. Retry the same session, or sign out to start a separate guest library."
    }

    private func focusStatus() {
        isStatusFocused = false
        DispatchQueue.main.async {
            isStatusFocused = true
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button(action: onRetry) {
            if isRetrying {
                HStack(spacing: 8) {
                    ProgressView()
                        .accessibilityHidden(true)
                    Text("Retrying Session")
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                Label("Retry Session", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isRetrying)
        .accessibilityValue(isRetrying ? "In progress" : "")

        Button(action: onOpenSettings) {
            Label("Settings", systemImage: "gearshape.fill")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(isRetrying)

        Button("Sign Out", role: .destructive, action: onSignOut)
            .frame(maxWidth: .infinity, minHeight: 44)
            .buttonStyle(.bordered)
            .disabled(isRetrying)
    }
}

#if DEBUG
#Preview(
    "Identity · Established recovery · Accessibility",
    traits: .fixedLayout(width: 320, height: 560)
) {
    ZStack(alignment: .top) {
        ItineraBackground()
        ServerSessionRecoveryBanner(
            errorMessage: "The same server session could not be restored. Try again when you're connected.",
            isRetrying: false,
            onRetry: {},
            onOpenSettings: {},
            onSignOut: {}
        )
    }
    .environment(\.itineraTheme, .atlas)
    .environment(\.dynamicTypeSize, .accessibility2)
    .preferredColorScheme(.light)
}

#Preview(
    "Identity · Deletion outcome · Compact accessibility",
    traits: .fixedLayout(width: 320, height: 620)
) {
    ZStack(alignment: .top) {
        ItineraBackground()
        PrivateIdentityOutcomeBanner(
            outcome: .accountDeleted,
            onDismiss: {}
        )
    }
    .environment(\.itineraTheme, .atlas)
    .environment(\.dynamicTypeSize, .accessibility2)
    .preferredColorScheme(.light)
}
#endif

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
        guard
            let session = GenerationNotificationManager.presentationSession(
                from: notification.request.identifier,
                userInfo: notification.request.content.userInfo
            ),
            await GenerationNotificationManager.shared.isCurrent(session)
        else {
            return []
        }
        return [.banner, .sound, .badge]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard
            let session = GenerationNotificationManager.presentationSession(
                from: response.notification.request.identifier,
                userInfo: response.notification.request.content.userInfo
            ),
            await GenerationNotificationManager.shared.isCurrent(session)
        else {
            return
        }
        NotificationCenter.default.post(
            name: .itineraOpenTrip,
            object: session
        )
    }
}

extension Notification.Name {
    static let itineraOpenTrip = Notification.Name("ItineraOpenTrip")
}
