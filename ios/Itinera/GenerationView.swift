import SwiftUI

/// Shows progress while the backend generates the itinerary, then hands off
/// to ItineraryView. Pending job IDs survive relaunch and polling is cancellable.
struct GenerationView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settingsPreferences: SettingsPreferences
    @Environment(\.dismiss) private var dismiss
    @Environment(\.itineraTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    let jobID: String

    @State private var itinerary: Itinerary?
    @State private var errorMessage: String?
    @State private var pollAttempt = 0
    @State private var isTerminalFailure = false
    @State private var isIdentityRecoveryRequired = false

    var body: some View {
        ZStack {
            ItineraBackground()

            if let itinerary {
                ItineraryView(itinerary: itinerary)
                    .transition(.opacity)
            } else if let errorMessage {
                errorState(message: errorMessage)
                    .transition(.opacity)
            } else {
                loadingState
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.55), value: itinerary != nil)
        .animation(.easeInOut(duration: 0.35), value: errorMessage != nil)
        .sensoryFeedback(.success, trigger: itinerary != nil)
        .navigationTitle(itinerary == nil ? "Building your trip" : "Your itinerary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task(id: pollAttempt) {
            await appState.registerPending(jobID: jobID)
            let tripTitle = appState.pendingJobs.first { $0.jobID == jobID }?.title
            do {
                itinerary = try await appState.apiClient.awaitItinerary(jobID)
                if let itinerary {
                    await appState.cacheCompletedTrip(
                        jobID: jobID,
                        itinerary: itinerary
                    )
                }
                await appState.resolvePending(jobID: jobID)
                if settingsPreferences.generationNotificationsEnabled,
                   scenePhase != .active {
                    try? await GenerationNotificationManager.shared.notifyTripReady(
                        jobID: jobID,
                        title: tripTitle
                    )
                }
            } catch is CancellationError {
                return
            } catch let error as APIError where error.shouldRemovePendingJob {
                await appState.resolvePending(jobID: jobID)
                isTerminalFailure = true
                errorMessage = error.localizedDescription
                if settingsPreferences.generationNotificationsEnabled,
                   scenePhase != .active {
                    try? await GenerationNotificationManager.shared.notifyGenerationFailed(
                        jobID: jobID
                    )
                }
            } catch let error as APIError where error.requiresIdentityRecovery {
                isIdentityRecoveryRequired = true
                errorMessage = error.localizedDescription
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var loadingState: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 70)

                ItineraBrandHeader(
                    eyebrow: "Route in progress",
                    title: "We're mapping the shape of your days.",
                    message: "Itinera is finding places, balancing travel time, and arranging each stop around your home base."
                )

                ItineraSurface {
                    VStack(spacing: 22) {
                        ItineraGenerationSpinner()

                        Text("This can take a few minutes. You can leave this screen—your trip will keep generating in the background and appear in Trips.")
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                }
                .revealOnAppear(delay: 0.1)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 36)
        }
    }

    private func errorState(message: String) -> some View {
        ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 80)

                ItineraBrandHeader(
                    eyebrow: "Route interrupted",
                        title: isTerminalFailure ? "This trip couldn't be completed." : "We lost the trail for a moment.",
                    message: failureMessage
                )

                ItineraSurface {
                    VStack(spacing: 18) {
                        Image(systemName: failureSymbol)
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(theme.danger)
                            .frame(width: 70, height: 70)
                            .background(theme.danger.opacity(0.10), in: Circle())

                        ItineraStatusBanner(message: message, kind: .error)

                        Button(shouldReturnToTrips ? "Back to Trips" : "Try again") {
                            if shouldReturnToTrips {
                                dismiss()
                            } else {
                                errorMessage = nil
                                pollAttempt += 1
                            }
                        }
                        .buttonStyle(ItineraPrimaryButtonStyle())
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 36)
        }
    }

    private var shouldReturnToTrips: Bool {
        isTerminalFailure || isIdentityRecoveryRequired
    }

    private var failureSymbol: String {
        if isIdentityRecoveryRequired {
            return "person.crop.circle.badge.exclamationmark"
        }
        return isTerminalFailure ? "map.fill" : "wifi.exclamationmark"
    }

    private var failureMessage: String {
        if isIdentityRecoveryRequired {
            return "Your saved trip remains on this iPhone. Return to Trips while your identity is recovered."
        }
        if isTerminalFailure {
            return "The saved request is no longer running. Return to Trips and start a fresh route when you're ready."
        }
        return "Your request is still safe. Try reconnecting to check its progress."
    }
}

private struct ItineraGenerationSpinner: View {
    @Environment(\.itineraTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let phrases = [
        "Finding the right places…",
        "Balancing travel time…",
        "Arranging your route…",
        "Finalizing each stop…"
    ]

    @State private var spinAngle: Double = 0
    @State private var phraseIndex = 0

    var body: some View {
        VStack(spacing: 16) {
            ItineraLogoMark(size: 72)
                .rotationEffect(.degrees(reduceMotion ? 0 : spinAngle))
                .shadow(color: theme.highlight.opacity(0.22), radius: 16, y: 5)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                        spinAngle = 360
                    }
                }

            Text(phrases[phraseIndex])
                .font(.system(.subheadline, design: .serif))
                .foregroundStyle(theme.secondaryText)
                .id(phraseIndex)
                .transition(.opacity)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                withAnimation(.easeInOut(duration: 0.4)) {
                    phraseIndex = (phraseIndex + 1) % phrases.count
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Generating itinerary")
        .accessibilityValue(phrases[phraseIndex])
        .accessibilityHint("Itinera will announce the current generation step.")
        .accessibilityAddTraits(.updatesFrequently)
    }
}
