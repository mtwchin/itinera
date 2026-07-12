import SwiftUI

/// Shows progress while the backend generates the itinerary, then hands off
/// to ItineraryView. Pending job IDs survive relaunch and polling is cancellable.
struct GenerationView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let jobID: String

    @State private var itinerary: Itinerary?
    @State private var errorMessage: String?
    @State private var pollAttempt = 0
    @State private var isTerminalFailure = false

    var body: some View {
        Group {
            if let itinerary {
                ItineraryView(itinerary: itinerary)
            } else if let errorMessage {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "Couldn’t update this trip",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                    Button(isTerminalFailure ? "Back to My Trips" : "Try Again") {
                        if isTerminalFailure {
                            dismiss()
                        } else {
                            self.errorMessage = nil
                            pollAttempt += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Building your itinerary…")
                        .font(.headline)
                    Text("Finding trending spots, mapping them, and planning your days. This can take up to a minute.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
        }
        .navigationTitle("Your Trip")
        .task(id: pollAttempt) {
            await appState.registerPending(jobID: jobID)
            do {
                itinerary = try await appState.apiClient.awaitItinerary(jobID)
                await appState.resolvePending(jobID: jobID)
            } catch is CancellationError {
                return
            } catch let error as APIError where error.shouldRemovePendingJob {
                await appState.resolvePending(jobID: jobID)
                isTerminalFailure = true
                errorMessage = error.localizedDescription
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
