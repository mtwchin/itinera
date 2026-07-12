import Foundation

struct GoogleMapsRouteSegment: Equatable, Identifiable, Sendable {
    let index: Int
    let totalSegments: Int
    let url: URL
    let activityNames: [String]

    var id: Int { index }

    var title: String {
        if activityNames.count == 1 {
            return "Open stop in Google Maps"
        }
        return totalSegments == 1
            ? "Open route in Google Maps"
            : "Open route \(index) of \(totalSegments)"
    }
}

enum GoogleMapsURLBuilderError: LocalizedError, Equatable {
    case invalidCoordinate(activityName: String)
    case couldNotBuildURL
    case urlTooLong

    var errorDescription: String? {
        switch self {
        case .invalidCoordinate(let activityName):
            return "\(activityName) has an invalid map location."
        case .couldNotBuildURL:
            return "This Google Maps route couldn't be created."
        case .urlTooLong:
            return "This route is too long to open safely in Google Maps."
        }
    }
}

enum GoogleMapsURLBuilder {
    // Google Maps mobile-browser URLs support at most three waypoints in
    // addition to an origin and destination. Adjacent segments overlap at one
    // stop so no activity disappears between route links.
    static let maximumLocationsPerSegment = 5
    static let maximumURLLength = 2_048

    static func routeSegments(
        for activities: [Activity]
    ) throws -> [GoogleMapsRouteSegment] {
        guard !activities.isEmpty else { return [] }

        for activity in activities where !isValid(activity.coordinates) {
            throw GoogleMapsURLBuilderError.invalidCoordinate(activityName: activity.name)
        }

        var activitySegments: [[Activity]] = []
        var startIndex = 0
        while startIndex < activities.count {
            let endIndex = min(startIndex + maximumLocationsPerSegment, activities.count)
            activitySegments.append(Array(activities[startIndex..<endIndex]))
            guard endIndex < activities.count else { break }
            startIndex = endIndex - 1
        }

        return try activitySegments.enumerated().map { offset, segment in
            GoogleMapsRouteSegment(
                index: offset + 1,
                totalSegments: activitySegments.count,
                url: try makeURL(for: segment),
                activityNames: segment.map(\.name)
            )
        }
    }

    private static func makeURL(for activities: [Activity]) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"

        if activities.count == 1, let activity = activities.first {
            components.path = "/maps/search/"
            components.percentEncodedQuery = try percentEncodedQuery([
                ("api", "1"),
                ("query", coordinateString(activity.coordinates)),
            ])
        } else {
            guard let origin = activities.first, let destination = activities.last else {
                throw GoogleMapsURLBuilderError.couldNotBuildURL
            }
            components.path = "/maps/dir/"
            var queryItems = [
                ("api", "1"),
                ("origin", coordinateString(origin.coordinates)),
                ("destination", coordinateString(destination.coordinates)),
            ]
            let waypoints = activities.dropFirst().dropLast()
            if !waypoints.isEmpty {
                queryItems.append(
                    (
                        "waypoints",
                        waypoints
                            .map { coordinateString($0.coordinates) }
                            .joined(separator: "|")
                    )
                )
            }
            components.percentEncodedQuery = try percentEncodedQuery(queryItems)
        }

        guard let url = components.url else {
            throw GoogleMapsURLBuilderError.couldNotBuildURL
        }
        guard url.absoluteString.utf8.count <= maximumURLLength else {
            throw GoogleMapsURLBuilderError.urlTooLong
        }
        return url
    }

    private static func isValid(_ coordinates: Coordinates) -> Bool {
        coordinates.lat.isFinite
            && coordinates.lng.isFinite
            && (-90...90).contains(coordinates.lat)
            && (-180...180).contains(coordinates.lng)
    }

    private static func percentEncodedQuery(
        _ items: [(name: String, value: String)]
    ) throws -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")

        return try items.map { item in
            guard let name = item.name.addingPercentEncoding(withAllowedCharacters: allowed),
                  let value = item.value.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw GoogleMapsURLBuilderError.couldNotBuildURL
            }
            return "\(name)=\(value)"
        }
        .joined(separator: "&")
    }

    private static func coordinateString(_ coordinates: Coordinates) -> String {
        String(
            format: "%.6f,%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            coordinates.lat,
            coordinates.lng
        )
    }
}
