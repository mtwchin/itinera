import Foundation

/// Saved trips, persisted as JSON in the app's Documents directory so
/// itineraries remain viewable offline.
@MainActor
final class TripStore: ObservableObject {
    @Published private(set) var trips: [SavedTrip] = []

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("trips.json")
        load()
    }

    func add(_ trip: SavedTrip) {
        trips.insert(trip, at: 0)
        save()
    }

    func delete(at offsets: IndexSet) {
        trips.remove(atOffsets: offsets)
        save()
    }

    func delete(id: UUID) {
        trips.removeAll { $0.id == id }
        save()
    }

    /// Replaces a stored trip (e.g. after a refine) if it exists.
    func update(_ trip: SavedTrip) {
        guard let index = trips.firstIndex(where: { $0.id == trip.id }) else { return }
        trips[index] = trip
        save()
    }

    func rename(id: UUID, to newName: String) {
        guard let index = trips.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        trips[index].destination = trimmed
        save()
    }

    func contains(id: UUID) -> Bool {
        trips.contains { $0.id == id }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        trips = (try? decoder.decode([SavedTrip].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(trips) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
