import SwiftUI

enum PrivateIdentitySupport {
    static let defaultURL = URL(
        string: "https://github.com/mtwchin/itinera/issues/new"
    )!
}

enum PrivateIdentityPhase: Equatable, Sendable {
    case restoring
    case ready(isOffline: Bool)
    case recoveryRequired(message: String)
    case cleanupRequired(
        intent: PrivateCleanupIntent,
        stage: PrivateCleanupStage,
        message: String
    )
    case cleanupBlocked(
        intent: PrivateCleanupIntent,
        stage: PrivateCleanupStage,
        message: String
    )
    case resumingCleanup(
        intent: PrivateCleanupIntent,
        stage: PrivateCleanupStage
    )
    case clearingDownloads
    case creatingReplacementSession(intent: PrivateCleanupIntent)
    case switching
    case signingOut
    case deleting
    case blocked(message: String)

    var presentsPrivateContent: Bool {
        if case .ready = self { return true }
        if case .recoveryRequired = self { return true }
        if case .clearingDownloads = self { return true }
        return false
    }
}

struct PrivateIdentityStatusView: View {
    @Environment(\.itineraTheme) private var theme
    @AccessibilityFocusState private var isStatusFocused: Bool

    let phase: PrivateIdentityPhase
    var onRetry: (() -> Void)?
    var supportURL: URL? = PrivateIdentitySupport.defaultURL

    var body: some View {
        ZStack {
            ItineraBackground()

            ScrollView {
                VStack(spacing: 22) {
                    Spacer(minLength: 34)

                    Image(systemName: icon)
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(theme.route)
                        .frame(width: 82, height: 82)
                        .background(theme.route.opacity(0.12), in: Circle())
                        .accessibilityHidden(true)

                    VStack(spacing: 9) {
                        Text(title)
                            .font(.system(.title2, design: .serif, weight: .bold))
                            .foregroundStyle(theme.primaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(message)
                            .font(.body)
                            .foregroundStyle(theme.secondaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(title)
                    .accessibilityValue(statusAccessibilityValue)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($isStatusFocused)

                    if isWorking {
                        ProgressView()
                            .controlSize(.large)
                            .tint(theme.route)
                            .accessibilityHidden(true)
                    } else if needsSupport, let supportURL {
                        Link(destination: supportURL) {
                            Label(
                                "Contact Support",
                                systemImage: "lifepreserver.fill"
                            )
                            .frame(maxWidth: .infinity, minHeight: 54)
                        }
                        .buttonStyle(ItineraPrimaryButtonStyle())
                        .accessibilityHint(
                            "Opens Itinera support without including private trip data"
                        )
                    } else if allowsRetry, let onRetry {
                        Button(action: onRetry) {
                            Label(retryTitle, systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity, minHeight: 54)
                        }
                        .buttonStyle(ItineraPrimaryButtonStyle())
                        .accessibilityHint(retryHint)
                    }

                    Spacer(minLength: 34)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 520, minHeight: 520)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .contain)
            }
        }
        .onAppear(perform: announcePhase)
        .onChange(of: phase) { _, _ in
            announcePhase()
        }
    }

    var isWorking: Bool {
        switch phase {
        case .restoring, .switching, .signingOut, .deleting,
             .resumingCleanup, .clearingDownloads,
             .creatingReplacementSession:
            return true
        case .ready, .recoveryRequired, .cleanupRequired, .cleanupBlocked,
             .blocked:
            return false
        }
    }

    var allowsRetry: Bool {
        if case .cleanupBlocked = phase { return false }
        return true
    }

    var needsSupport: Bool {
        if case .cleanupBlocked = phase { return true }
        return false
    }

    var icon: String {
        switch phase {
        case .restoring: return "lock.shield.fill"
        case .switching: return "person.2.badge.gearshape.fill"
        case .signingOut: return "rectangle.portrait.and.arrow.right"
        case .deleting: return "trash.slash.fill"
        case .blocked: return "exclamationmark.shield.fill"
        case .recoveryRequired: return "wifi.exclamationmark"
        case .cleanupRequired(let intent, _, _):
            return intent == .delete
                ? "trash.slash.fill"
                : "rectangle.portrait.and.arrow.right"
        case .cleanupBlocked:
            return "person.crop.circle.badge.exclamationmark"
        case .resumingCleanup(let intent, _):
            return intent == .delete
                ? "trash.slash.fill"
                : "rectangle.portrait.and.arrow.right"
        case .clearingDownloads:
            return "arrow.down.circle.fill"
        case .creatingReplacementSession:
            return "person.crop.circle.badge.plus"
        case .ready: return "checkmark.shield.fill"
        }
    }

    var title: String {
        switch phase {
        case .restoring:
            return "Opening your private library"
        case .switching:
            return "Switching private libraries"
        case .signingOut:
            return "Signing out on this iPhone"
        case .deleting:
            return "Removing your private library"
        case .clearingDownloads:
            return "Clearing downloaded trips"
        case .creatingReplacementSession:
            return "Starting a separate guest library"
        case .blocked:
            return "Private library unavailable"
        case .recoveryRequired:
            return "Your offline library is still private"
        case .cleanupRequired(let intent, let stage, _):
            switch (intent, stage) {
            case (.delete, .serverDeletionPending):
                return "Deletion needs your attention"
            case (.delete, .localCleanup):
                return "Finish removing app data"
            case (.signOut, .localCleanup):
                return "Sign-out cleanup needs your attention"
            case (.signOut, .serverDeletionPending):
                return "Private cleanup needs your attention"
            }
        case .cleanupBlocked(let intent, let stage, _):
            switch (intent, stage) {
            case (.delete, .serverDeletionPending):
                return "Account re-verification required"
            case (.delete, .localCleanup):
                return "Deletion cleanup requires support"
            case (.signOut, _):
                return "Sign-out cleanup requires support"
            }
        case .resumingCleanup(let intent, let stage):
            switch (intent, stage) {
            case (.delete, .serverDeletionPending):
                return "Resuming account deletion"
            case (.delete, .localCleanup):
                return "Finishing deletion on this iPhone"
            case (.signOut, .localCleanup):
                return "Finishing sign out on this iPhone"
            case (.signOut, .serverDeletionPending):
                return "Checking private cleanup"
            }
        case .ready:
            return "Private library ready"
        }
    }

    var message: String {
        switch phase {
        case .restoring:
            return "Itinera is opening the library saved for this account on this iPhone."
        case .switching:
            return "The libraries stay separate. Trips, drafts, and progress are not being merged."
        case .signingOut:
            return "Itinera is removing this library's offline device data before starting a separate guest library. Server data is not being deleted."
        case .deleting:
            return "Itinera is removing this account's private data from the app and its system surfaces."
        case .clearingDownloads:
            return "Itinera is removing this private library's downloaded trips and progress from this iPhone. Server copies are not being deleted."
        case .creatingReplacementSession(let intent):
            return intent == .delete
                ? "The deleted Itinera account stays closed. Itinera is creating a separate guest library; no library is being restored or merged."
                : "The signed-out library stays separate. Itinera is creating a guest library on this iPhone. Server data was not deleted."
        case .blocked(let message),
             .recoveryRequired(let message),
             .cleanupRequired(_, _, let message),
             .cleanupBlocked(_, _, let message):
            return message
        case .resumingCleanup(let intent, let stage):
            switch (intent, stage) {
            case (.delete, .serverDeletionPending):
                return "Itinera is retrying the same journaled server deletion. Private content and system surfaces remain hidden."
            case (.delete, .localCleanup):
                return "The server deletion was accepted. Itinera is finishing removal of this account's private app data; Calendar events, exported PDFs, files or text, and prior shares remain outside the app."
            case (.signOut, .localCleanup):
                return "Itinera is removing this library's app data before opening a separate guest library. Server data is not being deleted."
            case (.signOut, .serverDeletionPending):
                return "Itinera is validating the saved cleanup request while private content remains hidden."
            }
        case .ready(let isOffline):
            return isOffline
                ? "This is the offline copy saved for this account on this iPhone."
                : "This account's private library is ready."
        }
    }

    var retryTitle: String {
        if case .cleanupRequired(let intent, let stage, _) = phase {
            switch (intent, stage) {
            case (.delete, .serverDeletionPending): return "Resume Deletion"
            case (.delete, .localCleanup): return "Finish Deletion"
            case (.signOut, _): return "Resume Sign Out"
            }
        }
        return "Try Again"
    }

    var retryHint: String {
        if case .cleanupRequired(let intent, _, _) = phase {
            return intent == .delete
                ? "Continues the journaled deletion for the same Itinera account"
                : "Continues removing this library's app data before opening a guest library"
        }
        return "Attempts to establish this iPhone's private library again"
    }

    private var statusAccessibilityValue: String {
        isWorking ? "\(message) In progress." : message
    }

    private func announcePhase() {
        isStatusFocused = false
        DispatchQueue.main.async {
            isStatusFocused = true
        }
    }
}

#Preview("Identity · Restoring") {
    PrivateIdentityStatusView(phase: .restoring)
        .environment(\.itineraTheme, .atlas)
        .preferredColorScheme(.light)
}

#Preview(
    "Identity · Switching · Compact accessibility",
    traits: .fixedLayout(width: 320, height: 720)
) {
    PrivateIdentityStatusView(phase: .switching)
        .environment(\.itineraTheme, .atlas)
        .environment(\.dynamicTypeSize, .accessibility2)
        .preferredColorScheme(.light)
}

#Preview("Identity · Blocked") {
    PrivateIdentityStatusView(
        phase: .blocked(
            message: "Itinera couldn't establish a private library. Connect to the internet and try again."
        ),
        onRetry: {}
    )
    .environment(\.itineraTheme, .atlas)
    .preferredColorScheme(.light)
}

#Preview("Identity · Resume deletion") {
    PrivateIdentityStatusView(
        phase: .cleanupRequired(
            intent: .delete,
            stage: .serverDeletionPending,
            message: "Itinera could not reach the server. Your private content remains hidden; resume the same deletion when you're connected."
        ),
        onRetry: {}
    )
    .environment(\.itineraTheme, .atlas)
    .preferredColorScheme(.light)
}

#Preview("Identity · Deletion re-verification") {
    PrivateIdentityStatusView(
        phase: .cleanupBlocked(
            intent: .delete,
            stage: .serverDeletionPending,
            message: "The saved server credentials were rejected. Account re-verification is required before deletion can continue; contact Itinera support."
        ),
        onRetry: {}
    )
    .environment(\.itineraTheme, .atlas)
    .preferredColorScheme(.light)
}

#Preview("Identity · Deleting") {
    PrivateIdentityStatusView(phase: .deleting)
        .environment(\.itineraTheme, .atlas)
        .preferredColorScheme(.light)
}

#Preview("Identity · Signing out") {
    PrivateIdentityStatusView(phase: .signingOut)
        .environment(\.itineraTheme, .atlas)
        .preferredColorScheme(.light)
}

#Preview("Identity · Clearing downloads") {
    PrivateIdentityStatusView(phase: .clearingDownloads)
        .environment(\.itineraTheme, .atlas)
        .preferredColorScheme(.light)
}

#Preview("Identity · Starting guest after deletion") {
    PrivateIdentityStatusView(
        phase: .creatingReplacementSession(intent: .delete)
    )
    .environment(\.itineraTheme, .atlas)
    .preferredColorScheme(.light)
}

#Preview(
    "Identity · Resume sign out · Accessibility",
    traits: .fixedLayout(width: 320, height: 720)
) {
    PrivateIdentityStatusView(
        phase: .cleanupRequired(
            intent: .signOut,
            stage: .localCleanup,
            message: "Itinera is keeping private content hidden until this iPhone finishes removing the previous library."
        ),
        onRetry: {}
    )
    .environment(\.itineraTheme, .atlas)
    .environment(\.dynamicTypeSize, .accessibility2)
    .preferredColorScheme(.light)
}
