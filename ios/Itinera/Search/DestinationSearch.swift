import Foundation
import MapKit

struct SelectedDestination: Hashable {
    var city: String
    var country: String
    var latitude: Double
    var longitude: Double

    var displayName: String {
        country.isEmpty ? city : "\(city), \(country)"
    }
}

/// Wraps MKLocalSearchCompleter for the destination picker. Fully on-device
/// Apple Maps search — no Google key ships in the app.
final class DestinationSearchModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query: String = "" {
        didSet { completer.queryFragment = query }
    }
    @Published var results: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }

    func resolve(_ completion: MKLocalSearchCompletion) async throws -> SelectedDestination {
        let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completion))
        let response = try await search.start()
        guard let item = response.mapItems.first else {
            throw APIError.server("Couldn't find that place. Try a different search.")
        }
        let placemark = item.placemark
        let city = placemark.locality
            ?? placemark.administrativeArea
            ?? completion.title
        return SelectedDestination(
            city: city,
            country: placemark.country ?? "",
            latitude: placemark.coordinate.latitude,
            longitude: placemark.coordinate.longitude
        )
    }
}
