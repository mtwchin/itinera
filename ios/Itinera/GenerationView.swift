import SwiftUI

/// Shows progress while the backend generates the itinerary, then hands off
/// to ItineraryView. Uses polling for the MVP (the backend also offers SSE).
struct GenerationView: View {
    let jobID: String

    @State private var itinerary: Itinerary?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let itinerary {
                ItineraryView(itinerary: itinerary)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Generation failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
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
        .task {
            do {
                itinerary = try await APIClient.shared.awaitItinerary(jobID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
