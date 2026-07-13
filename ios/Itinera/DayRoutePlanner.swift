import Foundation
import MapKit

enum TripTransportMode: String, CaseIterable, Identifiable, Sendable {
    case walking
    case transit
    case driving

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walking: "Walk"
        case .transit: "Transit"
        case .driving: "Drive"
        }
    }

    var systemImage: String {
        switch self {
        case .walking: "figure.walk"
        case .transit: "bus.fill"
        case .driving: "car.fill"
        }
    }

    var mapKitType: MKDirectionsTransportType {
        switch self {
        case .walking: .walking
        case .transit: .transit
        case .driving: .automobile
        }
    }
}

struct DayRouteLeg: Identifiable {
    let id: String
    let originName: String
    let destinationName: String
    let coordinates: [CLLocationCoordinate2D]
    let expectedTravelTime: TimeInterval
    let distance: CLLocationDistance

    var travelTimeLabel: String {
        let minutes = max(1, Int((expectedTravelTime / 60).rounded()))
        if minutes < 60 {
            return "\(minutes) min"
        }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }

    var distanceLabel: String {
        let measurement = Measurement(value: distance, unit: UnitLength.meters)
        return measurement.formatted(
            .measurement(
                width: .abbreviated,
                usage: .road,
                numberFormatStyle: .number.precision(.fractionLength(0...1))
            )
        )
    }
}

@MainActor
enum DayRoutePlanner {
    static func route(
        activities: [Activity],
        mode: TripTransportMode,
        arrivalDate: Date? = nil
    ) async throws -> [DayRouteLeg] {
        guard activities.count > 1 else { return [] }

        var legs: [DayRouteLeg] = []
        for (origin, destination) in zip(activities, activities.dropFirst()) {
            try Task.checkCancellation()

            let request = MKDirections.Request()
            request.source = mapItem(for: origin)
            request.destination = mapItem(for: destination)
            request.transportType = mode.mapKitType
            request.requestsAlternateRoutes = false
            if mode == .transit, let arrivalDate {
                request.arrivalDate = arrivalDate
            }

            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.first else {
                throw DayRoutePlannerError.routeUnavailable
            }

            let points = route.polyline.points()
            let coordinates = (0..<route.polyline.pointCount).map {
                points[$0].coordinate
            }
            legs.append(
                DayRouteLeg(
                    id: "\(origin.id)-\(destination.id)-\(mode.rawValue)",
                    originName: origin.name,
                    destinationName: destination.name,
                    coordinates: coordinates,
                    expectedTravelTime: route.expectedTravelTime,
                    distance: route.distance
                )
            )
        }
        return legs
    }

    private static func mapItem(for activity: Activity) -> MKMapItem {
        let coordinate = CLLocationCoordinate2D(
            latitude: activity.coordinates.lat,
            longitude: activity.coordinates.lng
        )
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = activity.name
        return item
    }
}

enum DayRoutePlannerError: LocalizedError {
    case routeUnavailable

    var errorDescription: String? {
        "Live directions aren't available for every stop right now."
    }
}
