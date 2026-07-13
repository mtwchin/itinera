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

    var body: some View {
        ZStack {
            ItineraBackground()

            if let itinerary {
                ItineraryView(itinerary: itinerary)
            } else if let errorMessage {
                errorState(message: errorMessage)
            } else {
                loadingState
            }
        }
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
                        RouteProgressIndicator()

                        VStack(spacing: 8) {
                            Text("Finding the right rhythm")
                                .font(.system(.title3, design: .serif, weight: .bold))
                                .foregroundStyle(theme.primaryText)
                            Text("This can take a few minutes with a local model. You can leave this screen—your trip will keep generating and appear in Trips.")
                                .font(.subheadline)
                                .foregroundStyle(theme.secondaryText)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack(spacing: 8) {
                            ItineraPill(text: "Places", systemImage: "mappin")
                            ItineraPill(text: "Pacing", systemImage: "clock")
                            ItineraPill(text: "Route", systemImage: "map")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
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
                    message: isTerminalFailure
                        ? "The saved request is no longer running. Return to Trips and start a fresh route when you're ready."
                        : "Your request is still safe. Try reconnecting to check its progress."
                )

                ItineraSurface {
                    VStack(spacing: 18) {
                        Image(systemName: isTerminalFailure ? "map.fill" : "wifi.exclamationmark")
                            .font(.system(size: 42))
                            .foregroundStyle(theme.highlight)

                        ItineraStatusBanner(message: message, kind: .error)

                        Button(isTerminalFailure ? "Back to Trips" : "Try again") {
                            if isTerminalFailure {
                                dismiss()
                            } else {
                                errorMessage = nil
                                pollAttempt += 1
                            }
                        }
                        .buttonStyle(ItineraPrimaryButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 36)
        }
    }
}

private struct RouteProgressIndicator: View {
    @Environment(\.itineraTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(index == 3 ? theme.highlight : theme.route)
                    .frame(width: 16, height: 16)
                    .scaleEffect(isAnimating && !reduceMotion ? 1 : 0.72)
                    .opacity(isAnimating || reduceMotion ? 1 : 0.45)
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.72)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.13),
                        value: isAnimating
                    )

                if index < 3 {
                    Rectangle()
                        .fill(theme.route.opacity(0.45))
                        .frame(height: 2)
                        .frame(maxWidth: 52)
                }
            }
        }
        .frame(maxWidth: 250)
        .padding(.vertical, 10)
        .onAppear { isAnimating = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Generating itinerary")
    }
}
