import CoreLocation
import XCTest
@testable import Scedra

/// Live MapKit / geocoder. Skips when the environment has no network.
final class ScedraPlaceNetworkTests: XCTestCase {
    func testKnownPublicAddressResolvesWithoutRelyingOnLiveGPS() async throws {
        let resolver = PlaceResolver()
        let place = await resolver.resolve("1 Apple Park Way, Cupertino, CA 95014")
        guard let place else {
            throw XCTSkip("MapKit/geocoder unavailable in this environment")
        }
        let latitude = try XCTUnwrap(place.latitude)
        let longitude = try XCTUnwrap(place.longitude)
        XCTAssertEqual(latitude, 37.33, accuracy: 0.08, "Apple Park should pin in Cupertino")
        XCTAssertEqual(longitude, -122.01, accuracy: 0.08)
        XCTAssertFalse(place.displayLine.isEmpty)
    }

    func testDistinctiveVenueResolvesWithDefaultSearchRegion() async throws {
        let resolver = PlaceResolver()
        let place = await resolver.resolve("westwind community barn")
        guard let place else {
            throw XCTSkip("MapKit/geocoder unavailable in this environment")
        }
        let latitude = try XCTUnwrap(place.latitude)
        let longitude = try XCTUnwrap(place.longitude)
        XCTAssertEqual(latitude, 37.36, accuracy: 0.15)
        XCTAssertEqual(longitude, -122.16, accuracy: 0.15)
    }
}
