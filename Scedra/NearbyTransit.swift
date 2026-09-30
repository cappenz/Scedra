import CoreLocation
import Foundation
import MapKit

struct NearbyTransitStop: Equatable {
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double
    var meters: Int

    var line: String {
        if meters < 80 {
            return ScedraString("\(name) is at the place")
        }
        if meters < 400 {
            return ScedraString("\(name) is about a \(walkMinutes)-min walk")
        }
        return ScedraString("Nearest transit: \(name) (\(formattedDistance))")
    }

    var walkMinutes: Int {
        max(Int((Double(meters) / 80).rounded()), 1)
    }

    var formattedDistance: String {
        if meters < 1000 { return "\(meters) m" }
        let km = (Double(meters) / 100).rounded() / 10
        return "\(km) km"
    }
}

/// Finds a public-transport stop near a pin. Honest empty if Maps has none.
enum NearbyTransit {
    static let searchRadiusMeters: CLLocationDistance = 1_200

    static func nearest(
        to coordinate: CLLocationCoordinate2D,
        excluding origin: CLLocationCoordinate2D? = nil
    ) async -> NearbyTransitStop? {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let items = await search(near: coordinate)
        let ranked = items.compactMap { item -> NearbyTransitStop? in
            let pin = item.placemark.coordinate
            guard CLLocationCoordinate2DIsValid(pin) else { return nil }
            if let origin, samePlace(origin, pin) { return nil }
            let meters = Int(here.distance(from: CLLocation(latitude: pin.latitude, longitude: pin.longitude)))
            guard meters <= Int(searchRadiusMeters) else { return nil }
            let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return nil }
            return NearbyTransitStop(
                name: name,
                address: shortAddress(item.placemark),
                latitude: pin.latitude,
                longitude: pin.longitude,
                meters: meters
            )
        }
        return ranked.min { $0.meters < $1.meters }
    }

    private static func search(near coordinate: CLLocationCoordinate2D) async -> [MKMapItem] {
        var found: [MKMapItem] = []
        for query in ["transit station", "bus stop", "train station", "caltrain"] {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.resultTypes = .pointOfInterest
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.publicTransport])
            request.region = MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: searchRadiusMeters * 2,
                longitudinalMeters: searchRadiusMeters * 2
            )
            do {
                let response = try await MKLocalSearch(request: request).start()
                found.append(contentsOf: response.mapItems)
            } catch {
                continue
            }
            if !found.isEmpty { break }
        }
        return found
    }

    private static func samePlace(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> Bool {
        let left = CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
        let right = CLLocation(latitude: rhs.latitude, longitude: rhs.longitude)
        return left.distance(from: right) < 40
    }

    private static func shortAddress(_ placemark: MKPlacemark) -> String {
        [placemark.thoroughfare, placemark.locality]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}
