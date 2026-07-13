import XCTest
@testable import Itinera

final class ItineraryPDFExporterTests: XCTestCase {
    func testRendererCreatesMultipageCapablePDFData() {
        let data = ItineraryPDFRenderer.render(
            itinerary: .preview,
            tripTitle: "Lisbon, Portugal",
            dateRange: "Jul 20 → Jul 23"
        )

        XCTAssertGreaterThan(data.count, 1_000)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "%PDF")
    }
}
