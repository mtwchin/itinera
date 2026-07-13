import AuthenticationServices
import SwiftUI

struct SettingsActions: Sendable {
    var clearLocalTripData: (@MainActor @Sendable () async throws -> Void)?
    var deleteMyData: (@MainActor @Sendable () async throws -> Void)?
    var privacyPolicyURL: URL?
    var supportURL: URL?
    var connectAppleAccount: (@MainActor @Sendable (String) async throws -> Void)?

    static let placeholders = SettingsActions()
}

struct SettingsView: View {
    private enum PendingConfirmation: Identifiable {
        case clearLocalData
        case deleteAllData

        var id: Self { self }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.itineraTheme) private var theme
    @StateObject private var preferences: SettingsPreferences
    @State private var pendingConfirmation: PendingConfirmation?
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showingDisclosure = false
    @State private var appleAccountStatus: String?

    private let actions: SettingsActions
    private let showsDoneButton: Bool

    init(
        preferences: SettingsPreferences? = nil,
        actions: SettingsActions = .placeholders,
        showsDoneButton: Bool = true
    ) {
        _preferences = StateObject(wrappedValue: preferences ?? SettingsPreferences())
        self.actions = actions
        self.showsDoneButton = showsDoneButton
    }

    var body: some View {
        ZStack {
            ItineraBackground()

            ScrollView {
                VStack(spacing: 18) {
                    ItineraBrandHeader(
                        eyebrow: "Your field kit",
                        title: "Settings",
                        message: "Control what is shared, what stays on this iPhone, and how Itinera gets your attention."
                    )

                    if let statusMessage {
                        ItineraStatusBanner(message: statusMessage, kind: .success)
                    }
                    if let errorMessage {
                        ItineraStatusBanner(message: errorMessage, kind: .error)
                    }

                    appearanceSection
                    privacySection
                    accountSection
                    notificationSection
                    localDataSection
                    helpSection
                    aboutSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .disabled(isWorking)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .sheet(isPresented: $showingDisclosure) {
            NavigationStack {
                AIDataDisclosureView(
                    disclosure: .current,
                    hasConsent: preferences.hasCurrentAIDataConsent,
                    onAccept: preferences.acceptCurrentAIDataConsent,
                    onWithdraw: preferences.withdrawAIDataConsent
                )
            }
            .environment(\.itineraTheme, theme)
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingConfirmation {
                Button(confirmationButtonTitle, role: .destructive) {
                    Task { await perform(pendingConfirmation) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private var appearanceSection: some View {
        settingsCard(title: "Appearance", systemImage: "circle.lefthalf.filled") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Appearance", selection: $preferences.appAppearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title)
                            .tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityHint("Controls the color appearance throughout Itinera")

                Label(
                    preferences.appAppearance.detail,
                    systemImage: appearanceSystemImage
                )
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            }
        }
    }

    private var appearanceSystemImage: String {
        switch preferences.appAppearance {
        case .system: return "iphone"
        case .light: return "sun.max.fill"
        case .dark: return "moon.stars.fill"
        }
    }

    private var privacySection: some View {
        settingsCard(title: "AI & privacy", systemImage: "hand.raised.fill") {
            Button {
                showingDisclosure = true
            } label: {
                settingsRow(
                    title: "AI data use",
                    detail: preferences.hasCurrentAIDataConsent
                        ? "Disclosure v\(AIDataDisclosure.current.version) accepted"
                        : "Review required before generating a trip",
                    systemImage: preferences.hasCurrentAIDataConsent ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                    tint: preferences.hasCurrentAIDataConsent ? theme.success : theme.warning,
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)

            Divider()

            linkOrPlaceholder(
                title: "Privacy policy",
                detail: actions.privacyPolicyURL == nil ? "Publishing before external beta" : nil,
                systemImage: "doc.text.fill",
                url: actions.privacyPolicyURL
            )
        }
    }

    private var notificationSection: some View {
        settingsCard(title: "Notifications", systemImage: "bell.fill") {
            Toggle(isOn: $preferences.generationNotificationsEnabled) {
                settingsRow(
                    title: "Trip ready",
                    detail: "Notify me when generation finishes",
                    systemImage: "sparkles",
                    tint: theme.accent
                )
            }
            .onChange(of: preferences.generationNotificationsEnabled) { _, enabled in
                guard enabled else { return }
                Task { await requestNotificationPermission() }
            }

            Divider()

            Toggle(isOn: $preferences.tripRemindersEnabled) {
                settingsRow(
                    title: "Trip reminders",
                    detail: "Upcoming departure and leave-by reminders",
                    systemImage: "clock.badge.fill",
                    tint: theme.highlightStrong
                )
            }
            .onChange(of: preferences.tripRemindersEnabled) { _, enabled in
                guard enabled else { return }
                Task { await requestNotificationPermission() }
            }
        }
    }

    private var accountSection: some View {
        settingsCard(
            title: "Account recovery",
            systemImage: "person.crop.circle.badge.checkmark"
        ) {
            Text("Sign in with Apple to recover this library on another iPhone. If an existing Apple library is found, Itinera switches to it without deleting this device's offline copy.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)

            if let appleAccountStatus {
                Text(appleAccountStatus)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.success)
            }

            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = [.email]
            } onCompletion: { result in
                handleAppleAuthorization(result)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .disabled(actions.connectAppleAccount == nil)
            .opacity(actions.connectAppleAccount == nil ? 0.55 : 1)
        }
    }

    private var localDataSection: some View {
        settingsCard(title: "Your data", systemImage: "internaldrive.fill") {
            Button {
                pendingConfirmation = .clearLocalData
            } label: {
                settingsRow(
                    title: "Clear downloaded trips",
                    detail: actions.clearLocalTripData == nil
                        ? "Available when offline trip storage is connected"
                        : "Remove offline copies from this iPhone",
                    systemImage: "arrow.down.circle.fill",
                    tint: theme.warning
                )
            }
            .buttonStyle(.plain)
            .disabled(actions.clearLocalTripData == nil)

            Divider()

            Button {
                pendingConfirmation = .deleteAllData
            } label: {
                settingsRow(
                    title: "Delete my data",
                    detail: actions.deleteMyData == nil
                        ? "Requires the server deletion endpoint"
                        : "Permanently delete server and local data",
                    systemImage: "trash.fill",
                    tint: theme.danger
                )
            }
            .buttonStyle(.plain)
            .disabled(actions.deleteMyData == nil)
            .accessibilityHint("This action cannot be undone")
        }
    }

    private var helpSection: some View {
        settingsCard(title: "Help", systemImage: "lifepreserver.fill") {
            linkOrPlaceholder(
                title: "Contact support",
                detail: actions.supportURL == nil ? "Support channel coming before beta" : nil,
                systemImage: "envelope.fill",
                url: actions.supportURL
            )
        }
    }

    private var aboutSection: some View {
        settingsCard(title: "About", systemImage: "info.circle.fill") {
            settingsRow(
                title: "Itinera",
                detail: "Version \(appVersion) (\(buildNumber))",
                systemImage: "app.badge.fill",
                tint: theme.accent
            )
        }
    }

    private func settingsCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ItineraSurface {
            VStack(alignment: .leading, spacing: 14) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                content()
            }
        }
    }

    private func settingsRow(
        title: String,
        detail: String?,
        systemImage: String,
        tint: Color,
        showsChevron: Bool = false
    ) -> some View {
        HStack(spacing: 13) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(theme.primaryText)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func linkOrPlaceholder(
        title: String,
        detail: String?,
        systemImage: String,
        url: URL?
    ) -> some View {
        if let url {
            Link(destination: url) {
                settingsRow(
                    title: title,
                    detail: detail,
                    systemImage: systemImage,
                    tint: theme.accent,
                    showsChevron: true
                )
            }
        } else {
            settingsRow(
                title: title,
                detail: detail,
                systemImage: systemImage,
                tint: theme.secondaryText
            )
            .opacity(0.72)
        }
    }

    private func requestNotificationPermission() async {
        do {
            let granted = try await GenerationNotificationManager.shared.requestAuthorization()
            if !granted {
                preferences.generationNotificationsEnabled = false
                preferences.tripRemindersEnabled = false
                errorMessage = "Notifications are disabled in iOS Settings."
            }
        } catch {
            preferences.generationNotificationsEnabled = false
            preferences.tripRemindersEnabled = false
            errorMessage = "Notification permission could not be requested."
        }
    }

    private func handleAppleAuthorization(
        _ result: Result<ASAuthorization, Error>
    ) {
        guard let connectAppleAccount = actions.connectAppleAccount else { return }
        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                throw APIError.authenticationFailed(
                    "Apple did not return an identity token."
                )
            }
            Task {
                do {
                    try await connectAppleAccount(token)
                    appleAccountStatus = "Your library is connected to Apple."
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func perform(_ confirmation: PendingConfirmation) async {
        pendingConfirmation = nil
        statusMessage = nil
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }

        do {
            switch confirmation {
            case .clearLocalData:
                guard let clearLocalTripData = actions.clearLocalTripData else { return }
                try await clearLocalTripData()
                statusMessage = "Downloaded trips were removed from this iPhone."
            case .deleteAllData:
                guard let deleteMyData = actions.deleteMyData else { return }
                try await deleteMyData()
                preferences.reset()
                await GenerationNotificationManager.shared.removeAllItineraNotifications()
                statusMessage = "Your Itinera data was deleted."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var confirmationTitle: String {
        switch pendingConfirmation {
        case .clearLocalData: return "Clear downloaded trips?"
        case .deleteAllData: return "Delete all your data?"
        case nil: return "Confirm"
        }
    }

    private var confirmationButtonTitle: String {
        switch pendingConfirmation {
        case .clearLocalData: return "Clear Downloads"
        case .deleteAllData: return "Delete My Data"
        case nil: return "Continue"
        }
    }

    private var confirmationMessage: String {
        switch pendingConfirmation {
        case .clearLocalData:
            return "Server copies remain available and can be downloaded again."
        case .deleteAllData:
            return "This permanently removes your server data, downloaded trips, and device session. This cannot be undone."
        case nil:
            return ""
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
}

struct AIDataDisclosureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.itineraTheme) private var theme

    let disclosure: AIDataDisclosure
    let hasConsent: Bool
    let onAccept: () -> Void
    let onWithdraw: () -> Void

    var body: some View {
        ZStack {
            ItineraBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ItineraBrandHeader(
                        eyebrow: "Disclosure v\(disclosure.version)",
                        title: "How AI uses your trip details",
                        message: disclosure.summary
                    )

                    disclosureCard(
                        title: "Sent to Itinera",
                        systemImage: "arrow.up.forward.circle.fill",
                        items: disclosure.sentItems,
                        tint: theme.warning
                    )
                    disclosureCard(
                        title: "Not collected automatically",
                        systemImage: "lock.shield.fill",
                        items: disclosure.notSentItems,
                        tint: theme.success
                    )

                    if hasConsent {
                        Button("Withdraw consent", role: .destructive) {
                            onWithdraw()
                            dismiss()
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                    } else {
                        Button("I understand and agree") {
                            onAccept()
                            dismiss()
                        }
                        .buttonStyle(ItineraPrimaryButtonStyle())
                    }

                    Text("You can change this choice at any time. Withdrawing consent prevents new AI generation; existing trips remain until you delete them.")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                }
                .padding(20)
            }
        }
        .navigationTitle("AI data use")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Close") { dismiss() }
            }
        }
    }

    private func disclosureCard(
        title: String,
        systemImage: String,
        items: [String],
        tint: Color
    ) -> some View {
        ItineraSurface {
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .foregroundStyle(tint)
                    .accessibilityAddTraits(.isHeader)
                ForEach(items, id: \.self) { item in
                    Label(item, systemImage: "circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(theme.primaryText)
                        .labelStyle(ItineraDisclosureLabelStyle())
                }
            }
        }
    }
}

private struct ItineraDisclosureLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            configuration.icon
                .font(.system(size: 6))
            configuration.title
        }
    }
}

#Preview("Settings") {
    NavigationStack {
        SettingsView()
    }
    .environment(\.itineraTheme, ItineraTheme.atlas)
}
