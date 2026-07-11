import SwiftUI

/// Full-screen progress overlay shown while the backend builds an itinerary
/// (typically 15–40 seconds). Rotating messages keep it from feeling hung.
struct GeneratingView: View {
    private let messages = [
        "Finding trending spots…",
        "Mapping the city…",
        "Clustering nearby places…",
        "Building your days…",
        "Adding food picks…",
        "Almost there…",
    ]

    @State private var messageIndex = 0

    private let timer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                ProgressView()
                    .controlSize(.large)
                Text(messages[messageIndex])
                    .font(.headline)
                    .contentTransition(.opacity)
                Text("This usually takes under a minute.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
        .onReceive(timer) { _ in
            withAnimation {
                messageIndex = min(messageIndex + 1, messages.count - 1)
            }
        }
    }
}

#Preview {
    GeneratingView()
}
