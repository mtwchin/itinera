import CoreLocation
import Foundation

struct LocationCoordinate: Codable, Equatable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct SelectedLocation: Codable, Equatable, Hashable, Sendable {
    var name: String
    var address: String
    var city: String
    var country: String
    var coordinate: LocationCoordinate
    var timeZoneIdentifier: String? = nil

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
