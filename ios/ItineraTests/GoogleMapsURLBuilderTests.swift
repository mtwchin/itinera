import Foundation
import XCTest
@testable import Itinera

final class GoogleMapsURLBuilderTests: XCTestCase {
    func testEmptyDayProducesNoRoutes() throws {
        XCTAssertEqual(try GoogleMapsURLBuilder.routeSegments(for: []), [])
    }

    func testOneStopProducesSearchURL() throws {
        let routes = try GoogleMapsURLBuilder.routeSegments(for: [activity(0)])

        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes[0].url.path, "/maps/search")
        XCTAssertEqual(queryItems(in: routes[0].url)["api"], "1")
        XCTAssertEqual(queryItems(in: routes[0].url)["query"], "38.700000,-9.100000")
        XCTAssertEqual(routes[0].title, "Open stop in Google Maps")
        XCTAssertTrue(routes[0].url.absoluteString.contains("38.700000%2C-9.100000"))
    }

    func testFiveStopsFitInOneDirectionsURLInOrder() throws {
        let routes = try GoogleMapsURLBuilder.routeSegments(
            for: (0..<5).map(activity)
        )

        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes[0].activityNames, ["Stop 0", "Stop 1", "Stop 2", "Stop 3", "Stop 4"])
        XCTAssertEqual(routes[0].url.path, "/maps/dir")
        let query = queryItems(in: routes[0].url)
        XCTAssertEqual(query["origin"], "38.700000,-9.100000")
        XCTAssertEqual(query["destination"], "38.704000,-9.104000")
        XCTAssertEqual(
            query["waypoints"],
            "38.701000,-9.101000|38.702000,-9.102000|38.703000,-9.103000"
        )
        let encodedQuery = try XCTUnwrap(
            URLComponents(url: routes[0].url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        )
        XCTAssertTrue(encodedQuery.contains("%2C"))
        XCTAssertTrue(encodedQuery.contains("%7C"))
        XCTAssertFalse(encodedQuery.contains(","))
        XCTAssertFalse(encodedQuery.contains("|"))
    }

    func testLongDayUsesOverlappingBrowserSafeSegments() throws {
        let routes = try GoogleMapsURLBuilder.routeSegments(
            for: (0..<10).map(activity)
        )

        XCTAssertEqual(routes.count, 3)
        XCTAssertEqual(routes.map(\.activityNames), [
            ["Stop 0", "Stop 1", "Stop 2", "Stop 3", "Stop 4"],
            ["Stop 4", "Stop 5", "Stop 6", "Stop 7", "Stop 8"],
            ["Stop 8", "Stop 9"],
        ])
        XCTAssertTrue(routes.allSatisfy { $0.activityNames.count <= 5 })
        XCTAssertTrue(
            routes.allSatisfy {
                $0.url.absoluteString.utf8.count <= GoogleMapsURLBuilder.maximumURLLength
            }
        )
    }

    func testOneStopProducesAppSearchURL() throws {
        let routes = try GoogleMapsURLBuilder.routeSegments(for: [activity(0)])
        let appURL = try XCTUnwrap(routes[0].appURL)
        XCTAssertEqual(appURL.scheme, "comgooglemaps")
        XCTAssertTrue(appURL.absoluteString.contains("q=38.700000,-9.100000"))
    }

    func testMultiStopProducesAppDirectionsURL() throws {
        let routes = try GoogleMapsURLBuilder.routeSegments(for: (0..<3).map(activity))
        let appURL = try XCTUnwrap(routes[0].appURL)
        XCTAssertEqual(appURL.scheme, "comgooglemaps")
        XCTAssertTrue(appURL.absoluteString.contains("saddr=38.700000,-9.100000"))
        XCTAssertTrue(appURL.absoluteString.contains("waypoints=38.701000,-9.101000"))
        XCTAssertTrue(appURL.absoluteString.contains("daddr=38.702000,-9.102000"))
    }

    func testInvalidCoordinateFailsWithoutCreatingPartialRoute() {
        let invalid = Activity(
            time: "10:00",
            name: "Invalid Stop",
            type: "culture",
            duration: "1 hour",
            description: "Invalid coordinate fixture",
            address: "Nowhere",
            coordinates: Coordinates(lat: 91, lng: 0)
        )

        XCTAssertThrowsError(
            try GoogleMapsURLBuilder.routeSegments(for: [activity(0), invalid])
        ) { error in
            XCTAssertEqual(
                error as? GoogleMapsURLBuilderError,
                .invalidCoordinate(activityName: "Invalid Stop")
            )
        }
    }

    private func activity(_ index: Int) -> Activity {
        Activity(
            time: "\(9 + index):00",
            name: "Stop \(index)",
            type: "culture",
            duration: "1 hour",
            description: "Stop \(index) description",
            address: "Stop \(index) address",
            coordinates: Coordinates(
                lat: 38.7 + (Double(index) / 1_000),
                lng: -9.1 - (Double(index) / 1_000)
            )
        )
    }

    private func queryItems(in url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.compactMap { item in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })
    }
}
