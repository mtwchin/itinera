import CoreLocation
import Foundation

struct LocationCoordinate: Equatable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct SelectedLocation: Equatable, Hashable, Sendable {
    var name: String
    var address: String
    var city: String
    var country: String
    var coordinate: LocationCoordinate

    var destinationInputLabel: String {
        [city, country]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    var homeBaseInputLabel: String {
        address.isEmpty ? name : address
    }

    var accommodation: Accommodation {
        Accommodation(
            address: homeBaseInputLabel,
            lat: coordinate.latitude,
            lng: coordinate.longitude
        )
    }
}
