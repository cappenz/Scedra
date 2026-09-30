import XCTest
import MapKit
import CoreLocation
@testable import Scedra

/// THROWAWAY network probe. Not part of the normal suite — skipped so it cannot ship as a failing test.
final class ScedraMapProbe: XCTestCase {

    override func setUpWithError() throws {
        throw XCTSkip("Manual MapKit network probe — not part of the shipping test suite")
    }

    private func dump(_ label: String, _ items: [MKMapItem]) {
        print("PROBE >>> \(label): \(items.count) result(s)")
        for (i, item) in items.prefix(8).enumerated() {
            let c = item.placemark.coordinate
            let addr = [
                item.placemark.subThoroughfare,
                item.placemark.thoroughfare,
                item.placemark.locality,
                item.placemark.administrativeArea
            ].compactMap { $0 }.joined(separator: " ")
            print("PROBE >>>   [\(i)] name=\(item.name ?? "nil") | coord=\(c.latitude),\(c.longitude) | addr=\(addr)")
        }
    }

    private func search(_ query: String, region: MKCoordinateRegion?) async -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        if let region { request.region = region }
        do {
            return try await MKLocalSearch(request: request).start().mapItems
        } catch {
            print("PROBE >>> ERROR for '\(query)': \(error)")
            return []
        }
    }

    func testProbeWestwind() async throws {
        let losAltosHills = CLLocationCoordinate2D(latitude: 37.3797, longitude: -122.1372)
        let wide = MKCoordinateRegion(
            center: losAltosHills,
            latitudinalMeters: 200_000,
            longitudinalMeters: 200_000
        )
        let tight = MKCoordinateRegion(
            center: losAltosHills,
            latitudinalMeters: 20_000,
            longitudinalMeters: 20_000
        )

        let queries = [
            "westwind community barn",
            "Westwind Community Barn",
            "westwind barn",
            "Westwind Barn Los Altos Hills",
            "westwind community barn los altos hills",
            "27210 Altamont Rd, Los Altos Hills, CA",
            "westwind",
            "community barn"
        ]

        for q in queries {
            dump("WIDE   '\(q)'", await search(q, region: wide))
            dump("TIGHT  '\(q)'", await search(q, region: tight))
            dump("NOREG  '\(q)'", await search(q, region: nil))
        }

        // Geocoder on address forms
        for addr in [
            "27210 Altamont Rd, Los Altos Hills, CA",
            "Westwind Community Barn, Los Altos Hills, CA",
            "Westwind Barn, Los Altos Hills, CA"
        ] {
            do {
                let marks = try await CLGeocoder().geocodeAddressString(addr)
                print("PROBE >>> GEOCODE '\(addr)': \(marks.count) result(s)")
                for m in marks.prefix(5) {
                    print("PROBE >>>   name=\(m.name ?? "nil") | coord=\(m.location?.coordinate.latitude ?? 0),\(m.location?.coordinate.longitude ?? 0) | locality=\(m.locality ?? "nil") | thoroughfare=\(m.subThoroughfare ?? "") \(m.thoroughfare ?? "")")
                }
            } catch {
                print("PROBE >>> GEOCODE ERROR '\(addr)': \(error)")
            }
        }

        // What does the app's own resolver do right now?
        let resolver = PlaceResolver()
        for q in ["westwind community barn", "westwind barn"] {
            let resolved = await resolver.resolve(q)
            print("PROBE >>> RESOLVER '\(q)' -> \(String(describing: resolved))")
            print("PROBE >>> PLAN '\(q)' -> \(PlaceResolver.searchPlan(for: q))")
        }
    }

    /// Live Apple Maps automobile time. Cupertino → Westwind Community Barn is a ~15 min drive.
    /// Departure is the planned leave-by a few hours from now — not current traffic, not arrive-by.
    func testAutomobileDriveTimeCupertinoToWestwindBarn() async throws {
        let cupertino = CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)
        let barn = CLLocationCoordinate2D(latitude: 37.3649643, longitude: -122.1599489)
        let origin = CLLocation(latitude: cupertino.latitude, longitude: cupertino.longitude)
        let now = Date()
        let appointmentStart = now.addingTimeInterval(4 * 60 * 60)
        let appointmentEnd = appointmentStart.addingTimeInterval(60 * 60)
        let buffer = 5
        let extraBefore = 0
        let extraAfter = 0
        let leaveBy = TravelEstimator.outboundMapsDeparture(
            start: appointmentStart,
            knownDriveMinutes: nil,
            bufferMinutes: buffer,
            extraBeforeMinutes: extraBefore,
            now: now
        )
        let returnLeave = TravelEstimator.returnMapsDeparture(
            end: appointmentEnd,
            extraAfterMinutes: extraAfter,
            now: now
        )
        XCTAssertGreaterThan(leaveBy.timeIntervalSince(now), 3 * 3600)
        print("PROBE DRIVE >>> planned leave-by: \(leaveBy)")
        print("PROBE DRIVE >>> planned return leave: \(returnLeave)")

        let outbound = await automobileMinutes(from: cupertino, to: barn, departingAt: leaveBy)
        print("PROBE DRIVE >>> Cupertino → barn (automobile, leave-by in ~4h): \(minutesText(outbound))")

        let comingBack = await automobileMinutes(from: barn, to: cupertino, departingAt: returnLeave)
        print("PROBE DRIVE >>> barn → Cupertino (automobile, after appointment end): \(minutesText(comingBack))")

        let estimator = await TravelEstimator.roundTripEstimate(
            from: origin,
            toLatitude: barn.latitude,
            longitude: barn.longitude,
            mode: .drive,
            start: appointmentStart,
            end: appointmentEnd,
            bufferMinutes: buffer,
            fromHome: false,
            extraBeforeMinutes: extraBefore,
            extraAfterMinutes: extraAfter
        )
        print("PROBE DRIVE >>> TravelEstimator Cupertino→barn minutes: \(estimator.map { String($0.minutes) } ?? "nil")")
        print("PROBE DRIVE >>> TravelEstimator barn→Cupertino return: \(estimator?.returnMinutes.map(String.init) ?? "nil")")
        print("PROBE DRIVE >>> Review line would be: \(estimator.map { TravelEstimator.line(for: $0) } ?? "unavailable")")
        XCTAssertEqual(estimator?.bufferMinutes, 5, "buffer is leave-by only; must not be baked into Maps minutes")
        XCTAssertEqual(
            estimator?.leaveBy,
            TravelEstimator.leaveBy(
                start: appointmentStart,
                travelMinutes: estimator?.minutes ?? 0,
                bufferMinutes: buffer,
                extraBeforeMinutes: extraBefore
            )
        )
        if let estimator, let outbound {
            XCTAssertLessThanOrEqual(
                abs(estimator.minutes - outbound),
                8,
                "Review must show the same automobile minutes as the probe, not arrive-by / transit"
            )
        }

        if let homeMinutes = await homeToBarnMinutes(barn: barn, departingAt: leaveBy) {
            print("PROBE DRIVE >>> home → barn (automobile, leave-by): \(minutesText(homeMinutes))")
        } else {
            print("PROBE DRIVE >>> home → barn skipped (no geocodable home address in UserDefaults)")
        }

        guard let outbound else {
            XCTFail("Apple Maps returned no automobile route Cupertino → barn from the simulator")
            return
        }
        XCTAssertGreaterThanOrEqual(outbound, 8, "Cupertino → barn should be a short drive, got \(outbound)")
        XCTAssertLessThanOrEqual(outbound, 25, "Cupertino → barn is ~15 min driving, not \(outbound) (arrive-by/transit)")
        if let comingBack {
            XCTAssertGreaterThanOrEqual(comingBack, 8)
            XCTAssertLessThanOrEqual(comingBack, 45, "return can be slower in commute traffic, but 50+ is arrive-by/waiting")
        }
        if let estimator {
            XCTAssertGreaterThanOrEqual(estimator.minutes, 8)
            XCTAssertLessThanOrEqual(estimator.minutes, 25, "Review would still show a non-driving number")
            XCTAssertTrue(
                (TravelEstimator.note(for: estimator) ?? "").contains("from here"),
                "Cupertino pin is current location; Home still wins in Review when an address is set"
            )
        }

        // Do not await LocationProvider.currentFix() here — Simulator authorization
        // can hang the suite after the Maps assertions already finished.
    }

    private func minutesText(_ minutes: Int?) -> String {
        minutes.map { "\($0) min" } ?? "no route"
    }

    private func homeToBarnMinutes(barn: CLLocationCoordinate2D, departingAt: Date) async -> Int? {
        let raw = UserDefaults.standard.string(forKey: PlaceResolver.homeAddressKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        do {
            let marks = try await CLGeocoder().geocodeAddressString(raw)
            guard let home = marks.first?.location?.coordinate else { return nil }
            print("PROBE DRIVE >>> home geocode '\(raw)' -> \(home.latitude),\(home.longitude)")
            return await automobileMinutes(from: home, to: barn, departingAt: departingAt)
        } catch {
            print("PROBE DRIVE >>> home geocode error: \(error)")
            return nil
        }
    }

    /// Direct MKDirections car route. No arrivalDate — that can count waiting or pick transit.
    private func automobileMinutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        departingAt departure: Date
    ) async -> Int? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .automobile
        request.requestsAlternateRoutes = false
        request.departureDate = departure
        request.arrivalDate = nil

        do {
            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.first else {
                print("PROBE DRIVE >>> no routes")
                return nil
            }
            print(
                "PROBE DRIVE >>> expectedTravelTime=\(route.expectedTravelTime)s distance=\(route.distance)m transport=\(route.transportType.rawValue)"
            )
            return TravelEstimator.minutesFromExpectedTravelTime(route.expectedTravelTime)
        } catch {
            print("PROBE DRIVE >>> MKDirections error: \(error)")
            return nil
        }
    }
}
