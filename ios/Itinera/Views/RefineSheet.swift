import SwiftUI

/// "Tweak this trip" — sends the current itinerary plus freeform feedback to
/// the refine endpoint and hands back the updated itinerary.
struct RefineSheet: View {
    let itinerary: Itinerary
    let onRefined: (Itinerary) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var feedback = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    private let suggestions = [
        "More food stops",
        "Slower mornings",
        "Add nightlife",
        "More time outdoors",
        "Fewer museums",
        "Make it kid-friendly",
    ]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Tell Itinera what to change and it will rework your itinerary.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField(
                    "e.g. swap day 2's museum for a beach afternoon",
                    text: $feedback,
                    axis: .vertical
                )
                .lineLimit(3...6)
                .padding(12)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                .focused($fieldFocused)

                FlowChips(items: suggestions) { suggestion in
                    Haptics.tap()
                    if feedback.isEmpty {
                        feedback = suggestion
                    } else {
                        feedback += feedback.hasSuffix(" ") ? suggestion : ". \(suggestion)"
                    }
                }

                Spacer()

                Button {
                    refine()
                } label: {
                    HStack(spacing: 8) {
                        if isWorking {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "wand.and.rays")
                        }
                        Text(isWorking ? "Reworking your trip…" : "Refine Itinerary")
                            .font(.headline)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        Theme.gradient.opacity(canSubmit ? 1 : 0.4),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                }
                .disabled(!canSubmit || isWorking)
            }
            .padding()
            .navigationTitle("Tweak this trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
            }
            .interactiveDismissDisabled(isWorking)
            .alert("Couldn't refine itinerary", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear { fieldFocused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private var canSubmit: Bool {
        !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func refine() {
        guard canSubmit else { return }
        isWorking = true
        fieldFocused = false

        Task {
            defer { isWorking = false }
            do {
                let refined = try await APIClient().refineItinerary(
                    itinerary,
                    feedback: feedback.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                Haptics.success()
                onRefined(refined)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Simple wrapping chip row for tappable suggestions.
struct FlowChips: View {
    let items: [String]
    let onTap: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button {
                    onTap(item)
                } label: {
                    Text(item)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Minimal wrapping layout (left-aligned, wraps to new rows).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview {
    RefineSheet(
        itinerary: Itinerary(itinerary: [], tips: nil, accommodationInfo: nil, estimatedBudget: nil)
    ) { _ in }
}
