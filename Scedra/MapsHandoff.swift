import CoreLocation
import MapKit
import UIKit

/// Opens directions to a pin. Apple Maps is the real hand-off (drive / transit /
/// walk from Settings). Google follows that mode; Waze is drive-only.
enum MapsHandoff {
    static func appleMapsMode(for travelMode: TravelMode) -> String {
        switch travelMode {
        case .drive: MKLaunchOptionsDirectionsModeDriving
        case .transit: MKLaunchOptionsDirectionsModeTransit
        case .walk: MKLaunchOptionsDirectionsModeWalking
        }
    }

    static func googleMapsMode(for travelMode: TravelMode) -> String {
        switch travelMode {
        case .drive: "driving"
        case .transit: "transit"
        case .walk: "walking"
        }
    }

    static func openAppleMaps(
        latitude: Double,
        longitude: Double,
        name: String,
        mode: TravelMode = .drive
    ) {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        item.name = trimmed.isEmpty ? "Destination" : trimmed
        item.openInMaps(launchOptions: appleMapsLaunchOptions(mode: mode))
    }

    static func appleMapsLaunchOptions(mode: TravelMode) -> [String: String] {
        [MKLaunchOptionsDirectionsModeKey: appleMapsMode(for: mode)]
    }

    static func googleMapsWebURL(latitude: Double, longitude: Double, mode: TravelMode) -> URL? {
        URL(string: "https://maps.google.com/?daddr=\(latitude),\(longitude)&directionsmode=\(googleMapsMode(for: mode))")
    }

    static func wazeWebURL(latitude: Double, longitude: Double) -> URL? {
        URL(string: "https://waze.com/ul?ll=\(latitude),\(longitude)&navigate=yes")
    }

    static func openGoogleMaps(
        latitude: Double,
        longitude: Double,
        mode: TravelMode = .drive
    ) {
        let directions = googleMapsMode(for: mode)
        let app = URL(string: "comgooglemaps://?daddr=\(latitude),\(longitude)&directionsmode=\(directions)")
        if let app, UIApplication.shared.canOpenURL(app) {
            UIApplication.shared.open(app)
        } else if let web = googleMapsWebURL(latitude: latitude, longitude: longitude, mode: mode) {
            UIApplication.shared.open(web)
        }
    }

    static func openWaze(latitude: Double, longitude: Double) {
        let app = URL(string: "waze://?ll=\(latitude),\(longitude)&navigate=yes")
        if let app, UIApplication.shared.canOpenURL(app) {
            UIApplication.shared.open(app)
            return
        }
        if let web = wazeWebURL(latitude: latitude, longitude: longitude) {
            UIApplication.shared.open(web)
        }
    }
}
