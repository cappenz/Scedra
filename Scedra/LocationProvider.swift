import CoreLocation
import Foundation

/// When-In-Use GPS through `CLLocationManager`.
/// Simulator Features → Location reaches the app the same way a device GPS fix does.
/// Apple Park is a valid origin when that is the injected location — it is never special-cased away.
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    /// Reject stale last-known values. Simulator injections are timestamped now.
    static let maxAgeSeconds: TimeInterval = 180
    /// Negative accuracy is invalid. Past a kilometer is not a usable driving origin.
    static let maxHorizontalAccuracy: CLLocationAccuracy = 1_000

    private let manager = CLLocationManager()
    private var authorizationWaiter: CheckedContinuation<CLAuthorizationStatus, Never>?
    private var locationWaiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var timeoutTask: Task<Void, Never>?
    private var cached: (location: CLLocation, taken: Date)?

    override init() {
        super.init()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = kCLDistanceFilterNone
        manager.delegate = self
    }

    /// Recent, authorized, accuracy-sane fix. Nil if denied, unset in Simulator, or garbage.
    func currentFix() async -> CLLocation? {
        if let cached, Self.isUsableFix(cached.location) {
            return cached.location
        }
        guard await ensureAuthorized() else { return nil }
        if let last = manager.location, Self.isUsableFix(last) {
            cached = (last, Date())
            return last
        }
        let location = await requestUpdatingLocation()
        guard let location, Self.isUsableFix(location) else { return nil }
        cached = (location, Date())
        return location
    }

    /// A Core Location fix we will actually route from. Coordinates are not filtered by city.
    static func isUsableFix(_ location: CLLocation, now: Date = Date()) -> Bool {
        guard CLLocationCoordinate2DIsValid(location.coordinate) else { return false }
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= maxHorizontalAccuracy else {
            return false
        }
        return now.timeIntervalSince(location.timestamp) <= maxAgeSeconds
    }

    private func ensureAuthorized() async -> Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return true
        case .notDetermined:
            let status = await requestWhenInUse()
            return status == .authorizedWhenInUse || status == .authorizedAlways
        default:
            return false
        }
    }

    private func requestWhenInUse() async -> CLAuthorizationStatus {
        await withCheckedContinuation { continuation in
            if authorizationWaiter != nil {
                continuation.resume(returning: manager.authorizationStatus)
                return
            }
            authorizationWaiter = continuation
            manager.requestWhenInUseAuthorization()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                await self?.finishAuthorization(
                    self?.manager.authorizationStatus ?? .denied,
                    allowingUndetermined: true
                )
            }
        }
    }

    private func requestUpdatingLocation() async -> CLLocation? {
        await withCheckedContinuation { continuation in
            locationWaiters.append(continuation)
            if locationWaiters.count == 1 {
                manager.startUpdatingLocation()
                timeoutTask?.cancel()
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(8))
                    await self?.finishLocation(nil)
                }
            }
        }
    }

    private func finishAuthorization(
        _ status: CLAuthorizationStatus,
        allowingUndetermined: Bool = false
    ) {
        guard authorizationWaiter != nil else { return }
        if status == .notDetermined && !allowingUndetermined { return }
        authorizationWaiter?.resume(returning: status)
        authorizationWaiter = nil
    }

    private func finishLocation(_ location: CLLocation?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        manager.stopUpdatingLocation()
        let waiters = locationWaiters
        locationWaiters = []
        for waiter in waiters {
            waiter.resume(returning: location)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.finishAuthorization(status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            guard Self.isUsableFix(location) else { return }
            self.finishLocation(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // `locationUnknown` is normal while the Simulator injection settles — keep listening.
        guard let error = error as? CLError, error.code == .denied else { return }
        Task { @MainActor in
            self.finishLocation(nil)
        }
    }
}
