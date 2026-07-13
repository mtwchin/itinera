import AuthenticationServices
import SwiftUI

enum SettingsPrivacyCopy {
    static let appleRecovery = "Linking Apple provides a future sign-in method. If you approve sharing an email or private relay address, Itinera may store it on this server account. Linking does not enable cloud sync or upload offline trip copies to iCloud. If Apple already has a separate library, switching opens it and does not delete the current server account or its separate library. Itinera never merges them."

    static let appleConflict = "Apple is already linked to a separate Itinera library. Switching opens that Apple library; trips, drafts, progress, and offline copies are not merged or cloud-synced. The current server account and its separate library are not deleted."

    static let deleteRowTitle = "Delete your Itinera account and app data"
    static let deleteRowDetail = "Delete this server account and app data; Calendar events, exported PDFs, files or text, and prior shares remain"
    static let deleteUnavailableDetail = "Requires the server deletion endpoint; Calendar events, exported PDFs/files/text, and prior shares remain"
    static let deleteRecoveryRequiredDetail = "Restore this same server session before deleting the account"
    static let deleteConfirmationTitle = "Delete your Itinera account and app data?"
    static let deleteConfirmationMessage = "This permanently deletes this Itinera server account and its trips, then removes this account's private app data from this iPhone. Calendar events, exported PDFs, files or text, and anything previously shared remain outside the app. If interrupted, Itinera hides the library and resumes this same deletion. This cannot be undone."
}

enum SettingsBusyOperation: Equatable, Sendable {
    case linkingApple
    case switchingAppleLibrary
    case retryingServerSession
    case clearingDownloads
    case signingOut
    case deletingData

    var title: String {
        switch self {
        case .linkingApple:
            return "Linking this library to Apple"
        case .switchingAppleLibrary:
            return "Switching private libraries"
        case .retryingServerSession:
            return "Retrying this server session"
        case .clearingDownloads:
            return "Clearing downloaded trips"
        case .signingOut:
            return "Signing out on this iPhone"
        case .deletingData:
            return "Deleting your Itinera account and app data"
        }
    }
}

struct SettingsActions: Sendable {
    var serverSessionNeedsRecovery = false
    var retryServerSession: (@MainActor @Sendable () async throws -> Void)?
    var clearLocalTripData: (@MainActor @Sendable () async throws -> Void)?
    var signOut: (@MainActor @Sendable () async throws -> Void)?
    var deleteMyData: (@MainActor @Sendable () async throws -> Void)?
    var privacyPolicyURL: URL?
    var supportURL: URL?
    var validatePrivateSession: (@MainActor @Sendable () async -> Bool)?
    var connectAppleAccount: (@MainActor @Sendable (String) async throws -> AppleLinkResult)?
    var switchToAppleAccount: (@MainActor @Sendable (String) async throws -> Void)?

    static let placeholders = SettingsActions()
}

struct SettingsView: View {
    private enum PendingConfirmation: Identifiable {
        case clearLocalData
        case signOut
        case deleteAllData

        var id: Self { self }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.itineraTheme) private var theme
    @StateObject private var preferences: SettingsPreferences
    @State private var pendingConfirmation: PendingConfirmation?
    @State private var busyOperation: SettingsBusyOperation?
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showingDisclosure = false
    @State private var appleAccountStatus: String?
    @State private var pendingAppleSwitchToken: String?
    @AccessibilityFocusState private var busyStatusIsFocused: Bool
    @AccessibilityFocusState private var errorStatusIsFocused: Bool

    private let actions: SettingsActions
    private let showsDoneButton: Bool

    init(
        preferences: SettingsPreferences? = nil,
        actions: SettingsActions = .placeholders,
        showsDoneButton: Bool = true,
        initialBusyOperation: SettingsBusyOperation? = nil,
        initialAppleSwitchToken: String? = nil
    ) {
        _preferences = StateObject(wrappedValue: preferences ?? SettingsPreferences())
        _busyOperation = State(initialValue: initialBusyOperation)
        _pendingAppleSwitchToken = State(initialValue: initialAppleSwitchToken)
        self.actions = actions
        self.showsDoneButton = showsDoneButton
    }

    private var isWorking: Bool {
        busyOperation != nil
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
                            .accessibilityFocused($errorStatusIsFocused)
                    }
                    if actions.serverSessionNeedsRecovery {
                        ItineraStatusBanner(
                            message: "This library is available offline, but server changes are paused. Retry the same session or sign out to start a separate guest library.",
                            kind: .warning
                        )
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
            .accessibilityHidden(isWorking)

            if let busyOperation {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(theme.route)
                        .accessibilityHidden(true)
                    Text(busyOperation.title)
                        .font(.headline)
                        .foregroundStyle(theme.primaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 22)
                .frame(maxWidth: 300)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(theme.border, lineWidth: 1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(busyOperation.title)
                .accessibilityValue("In progress")
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityFocused($busyStatusIsFocused)
            }
        }
        .onChange(of: busyOperation) { _, operation in
            busyStatusIsFocused = operation != nil
            if operation != nil {
                errorStatusIsFocused = false
            } else if errorMessage != nil {
                errorStatusIsFocused = true
            }
        }
        .onChange(of: errorMessage) { _, message in
            guard message != nil, busyOperation == nil else { return }
            errorStatusIsFocused = true
        }
        .onAppear {
            if busyOperation != nil {
                busyStatusIsFocused = true
            }
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
        .confirmationDialog(
            "Switch private libraries?",
            isPresented: Binding(
                get: { pendingAppleSwitchToken != nil },
                set: {
                    if !$0 {
                        pendingAppleSwitchToken = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Switch to Apple Library", role: .destructive) {
                guard let token = pendingAppleSwitchToken else { return }
                pendingAppleSwitchToken = nil
                Task { await performAppleSwitch(identityToken: token) }
            }
            Button("Keep Current Library", role: .cancel) {
                pendingAppleSwitchToken = nil
                appleAccountStatus = "Kept the current private library. Nothing was merged or replaced."
            }
        } message: {
            Text(SettingsPrivacyCopy.appleConflict)
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
                .frame(minHeight: 44)
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
            Text(SettingsPrivacyCopy.appleRecovery)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)

            if let appleAccountStatus {
                Text(appleAccountStatus)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.success)
            }

            if actions.serverSessionNeedsRecovery {
                Button {
                    Task { await retryServerSession() }
                } label: {
                    settingsRow(
                        title: "Retry this server session",
                        detail: "Keep the same private library and try its saved credentials again",
                        systemImage: "arrow.clockwise.circle.fill",
                        tint: theme.route
                    )
                }
                .buttonStyle(.plain)
                .disabled(actions.retryServerSession == nil)

                Divider()
            }

            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = [.email]
            } onCompletion: { result in
                handleAppleAuthorization(result)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .disabled(
                actions.connectAppleAccount == nil
                    || actions.switchToAppleAccount == nil
            )
            .opacity(
                actions.connectAppleAccount == nil
                    || actions.switchToAppleAccount == nil ? 0.55 : 1
            )
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
                pendingConfirmation = .signOut
            } label: {
                settingsRow(
                    title: "Sign out on this iPhone",
                    detail: actions.signOut == nil
                        ? "Available when private identity is connected"
                        : "Remove this library's device data and start a new guest library",
                    systemImage: "rectangle.portrait.and.arrow.right",
                    tint: theme.warning
                )
            }
            .buttonStyle(.plain)
            .disabled(actions.signOut == nil)

            Divider()

            Button {
                pendingConfirmation = .deleteAllData
            } label: {
                settingsRow(
                    title: SettingsPrivacyCopy.deleteRowTitle,
                    detail: actions.serverSessionNeedsRecovery
                        ? SettingsPrivacyCopy.deleteRecoveryRequiredDetail
                        : actions.deleteMyData == nil
                        ? SettingsPrivacyCopy.deleteUnavailableDetail
                        : SettingsPrivacyCopy.deleteRowDetail,
                    systemImage: "trash.fill",
                    tint: theme.danger
                )
            }
            .buttonStyle(.plain)
            .disabled(
                actions.deleteMyData == nil
                    || actions.serverSessionNeedsRecovery
            )
            .accessibilityHint(
                actions.serverSessionNeedsRecovery
                    ? SettingsPrivacyCopy.deleteRecoveryRequiredDetail
                    : "This action cannot be undone"
            )
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
        .frame(minHeight: 44, alignment: .leading)
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
                busyOperation = .linkingApple
                defer { busyOperation = nil }
                do {
                    let linkResult = try await connectAppleAccount(token)
                    if let validatePrivateSession = actions.validatePrivateSession,
                       !(await validatePrivateSession()) {
                        throw IdentityCoordinatorError.staleIdentity
                    }
                    switch linkResult {
                    case .linked:
                        appleAccountStatus = nil
                        errorMessage = nil
                    case .switchConfirmationRequired:
                        appleAccountStatus = nil
                        pendingAppleSwitchToken = token
                    }
                } catch {
                    if let validatePrivateSession = actions.validatePrivateSession,
                       !(await validatePrivateSession()) {
                        return
                    }
                    errorMessage = error.localizedDescription
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performAppleSwitch(identityToken: String) async {
        guard let switchToAppleAccount = actions.switchToAppleAccount else {
            return
        }
        busyOperation = .switchingAppleLibrary
        statusMessage = nil
        errorMessage = nil
        defer { busyOperation = nil }
        do {
            try await switchToAppleAccount(identityToken)
        } catch {
            if let validatePrivateSession = actions.validatePrivateSession,
               !(await validatePrivateSession()) {
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    private func retryServerSession() async {
        guard let retryServerSession = actions.retryServerSession else {
            return
        }
        busyOperation = .retryingServerSession
        statusMessage = nil
        errorMessage = nil
        defer { busyOperation = nil }
        do {
            try await retryServerSession()
        } catch {
            if let validatePrivateSession = actions.validatePrivateSession,
               !(await validatePrivateSession()) {
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    private func perform(_ confirmation: PendingConfirmation) async {
        pendingConfirmation = nil
        statusMessage = nil
        errorMessage = nil
        busyOperation = {
            switch confirmation {
            case .clearLocalData: return .clearingDownloads
            case .signOut: return .signingOut
            case .deleteAllData: return .deletingData
            }
        }()
        defer { busyOperation = nil }

        do {
            switch confirmation {
            case .clearLocalData:
                guard let clearLocalTripData = actions.clearLocalTripData else { return }
                try await clearLocalTripData()
            case .signOut:
                guard let signOut = actions.signOut else { return }
                try await signOut()
            case .deleteAllData:
                guard let deleteMyData = actions.deleteMyData else { return }
                try await deleteMyData()
                preferences.reset()
                await GenerationNotificationManager.shared.removeAllItineraNotifications()
            }
        } catch {
            if let validatePrivateSession = actions.validatePrivateSession,
               !(await validatePrivateSession()) {
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    private var confirmationTitle: String {
        switch pendingConfirmation {
        case .clearLocalData: return "Clear downloaded trips?"
        case .signOut: return "Sign out on this iPhone?"
        case .deleteAllData: return SettingsPrivacyCopy.deleteConfirmationTitle
        case nil: return "Confirm"
        }
    }

    private var confirmationButtonTitle: String {
        switch pendingConfirmation {
        case .clearLocalData: return "Clear Downloads"
        case .signOut: return "Sign Out"
        case .deleteAllData: return "Delete Account and App Data"
        case nil: return "Continue"
        }
    }

    private var confirmationMessage: String {
        switch pendingConfirmation {
        case .clearLocalData:
            return "Server copies remain available and can be downloaded again."
        case .signOut:
            return "This removes this library's downloaded trips, drafts, progress, pending work, notifications, widget, and device session. Server data remains. Itinera then starts a separate guest library."
        case .deleteAllData:
            return SettingsPrivacyCopy.deleteConfirmationMessage
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
                        title: "Shared for AI generation",
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

#Preview("Settings · Deleting") {
    NavigationStack {
        SettingsView(initialBusyOperation: .deletingData)
    }
    .environment(\.itineraTheme, .atlas)
    .preferredColorScheme(.light)
}

#Preview(
    "Settings · Apple conflict · Compact accessibility",
    traits: .fixedLayout(width: 320, height: 760)
) {
    NavigationStack {
        SettingsView(initialAppleSwitchToken: "preview-ephemeral-token")
    }
    .environment(\.itineraTheme, .atlas)
    .environment(\.dynamicTypeSize, .accessibility2)
    .preferredColorScheme(.light)
}
