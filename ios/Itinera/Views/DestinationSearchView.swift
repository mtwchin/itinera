import SwiftUI
import MapKit

struct DestinationSearchView: View {
    let onSelect: (SelectedDestination) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = DestinationSearchModel()
    @State private var resolving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.results, id: \.self) { completion in
                    Button {
                        select(completion)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(completion.title)
                                .foregroundStyle(.primary)
                            if !completion.subtitle.isEmpty {
                                Text(completion.subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if model.query.isEmpty {
                    ContentUnavailableView(
                        "Search for a destination",
                        systemImage: "globe.europe.africa",
                        description: Text("Try a city, like “Lisbon” or “Tokyo”.")
                    )
                } else if resolving {
                    ProgressView()
                }
            }
            .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "City")
            .navigationTitle("Destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Search failed", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func select(_ completion: MKLocalSearchCompletion) {
        resolving = true
        Task {
            defer { resolving = false }
            do {
                let destination = try await model.resolve(completion)
                onSelect(destination)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    DestinationSearchView { _ in }
}
