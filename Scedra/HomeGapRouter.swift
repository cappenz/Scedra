import CoreLocation
import Foundation
import MapKit

/// Live Apple Maps car times for a consecutive pair, at the moments she would
/// actually drive. Arithmetic stays in `HomeGapLogic` so tests never hit the network.
enum HomeGapRouter {
    static func suggestion(
        first: HomeGapStop,
        second: HomeGapStop,
        home: CLLocation?,
        leavingHomeBuffer: Int,
        walkMinutes: Int,
        preferTransit: Bool = false,
        minHomeMinutes: Int = 0,
        standingBring: [String] = []
    ) async -> HomeGapSuggestion? {
        var first = await enrich(first)
        var second = await enrich(second)
        guard let fromA = HomeGapLogic.pin(for: first, home: home),
              let toB = HomeGapLogic.pin(for: second, home: home)
        else {
            return nil
        }

        let aToB = await refinedDirect(
            from: fromA,
            to: toB,
            start: second.officialStart,
            extraBeforeMinutes: second.extraBeforeMinutes
        )
        guard let aToB else { return nil }

        let leaveA = TravelEstimator.returnMapsDeparture(
            end: first.officialEnd,
            extraAfterMinutes: first.extraAfterMinutes
        )
        let directTransitDeparture = TravelEstimator.outboundMapsDeparture(
            start: second.officialStart,
            knownDriveMinutes: aToB,
            bufferMinutes: 0,
            extraBeforeMinutes: second.extraBeforeMinutes
        )
        async let transitDirect = transitMinutes(from: fromA, to: toB, departingAt: directTransitDeparture)

        var minutes = HomeGapMinutes(aToHome: nil, homeToB: nil, aToB: aToB)
        if let home {
            async let homeLeg = driveMinutes(from: fromA, to: home.coordinate, departingAt: leaveA)
            async let backLeg = refinedOutbound(
                from: home.coordinate,
                to: toB,
                start: second.officialStart,
                bufferMinutes: leavingHomeBuffer,
                extraBeforeMinutes: second.extraBeforeMinutes
            )
            async let homeTransit = transitMinutes(from: fromA, to: home.coordinate, departingAt: leaveA)
            async let backTransit = transitMinutes(
                from: home.coordinate,
                to: toB,
                departingAt: TravelEstimator.outboundMapsDeparture(
                    start: second.officialStart,
                    knownDriveMinutes: nil,
                    bufferMinutes: leavingHomeBuffer,
                    extraBeforeMinutes: second.extraBeforeMinutes
                )
            )
            let aToHome = await homeLeg
            let homeToB = await backLeg
            if let aToHome, let homeToB {
                minutes.aToHome = aToHome
                minutes.homeToB = homeToB
            }
            minutes.aToHomeTransit = await homeTransit
            minutes.homeToBTransit = await backTransit
        }
        minutes.aToBTransit = await transitDirect

        var suggestion = HomeGapLogic.suggestion(
            first: first,
            second: second,
            minutes: minutes,
            leavingHomeBuffer: leavingHomeBuffer,
            walkMinutes: walkMinutes,
            preferTransit: preferTransit,
            minHomeMinutes: minHomeMinutes,
            standingBring: standingBring
        )
        if var next = suggestion, let stop = await NearbyTransit.nearest(to: toB, excluding: fromA) {
            next.nearbyTransitLine = stop.line
            suggestion = next
        }
        return suggestion
    }

    private static func enrich(_ stop: HomeGapStop) async -> HomeGapStop {
        var stop = HomeGapLogic.enrichFromMemory(stop)
        if stop.coordinate != nil { return stop }
        let query = stop.place.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? stop.title
            : stop.place
        guard let location = await PlaceResolver().geocodedSavedPlace(matching: query) else {
            return stop
        }
        stop.latitude = location.coordinate.latitude
        stop.longitude = location.coordinate.longitude
        if stop.place.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let saved = ProfileDetailsStore.place(matching: query) {
            stop.place = saved.address
        }
        return stop
    }

    static func suggestions(
        stops: [HomeGapStop],
        home: CLLocation?,
        leavingHomeBuffer: Int,
        walkMinutes: Int,
        preferTransit: Bool = false,
        minHomeMinutes: Int = 0,
        standingBring: [String] = [],
        involving ids: Set<String> = []
    ) async -> [HomeGapSuggestion] {
        var result: [HomeGapSuggestion] = []
        for (first, second) in HomeGapLogic.consecutivePairs(from: stops) {
            if !ids.isEmpty, !ids.contains(first.id), !ids.contains(second.id) {
                continue
            }
            if let suggestion = await suggestion(
                first: first,
                second: second,
                home: home,
                leavingHomeBuffer: leavingHomeBuffer,
                walkMinutes: walkMinutes,
                preferTransit: preferTransit,
                minHomeMinutes: minHomeMinutes,
                standingBring: standingBring
            ) {
                result.append(suggestion)
            }
        }
        return result
    }

    /// A→B at B's leave-by. No leaving-home buffer — she is not leaving home.
    private static func refinedDirect(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        start: Date,
        extraBeforeMinutes: Int
    ) async -> Int? {
        await refinedOutbound(
            from: origin,
            to: destination,
            start: start,
            bufferMinutes: 0,
            extraBeforeMinutes: extraBeforeMinutes
        )
    }

    private static func refinedOutbound(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        start: Date,
        bufferMinutes: Int,
        extraBeforeMinutes: Int
    ) async -> Int? {
        if isSamePlace(origin, destination) { return 0 }
        let seed = TravelEstimator.outboundMapsDeparture(
            start: start,
            knownDriveMinutes: nil,
            bufferMinutes: bufferMinutes,
            extraBeforeMinutes: extraBeforeMinutes
        )
        guard let first = await driveMinutes(from: origin, to: destination, departingAt: seed) else {
            return nil
        }
        let refined = TravelEstimator.outboundMapsDeparture(
            start: start,
            knownDriveMinutes: first,
            bufferMinutes: bufferMinutes,
            extraBeforeMinutes: extraBeforeMinutes
        )
        if abs(refined.timeIntervalSince(seed)) >= 60,
           let second = await driveMinutes(from: origin, to: destination, departingAt: refined) {
            return second
        }
        return first
    }

    private static func driveMinutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        departingAt departure: Date
    ) async -> Int? {
        if isSamePlace(origin, destination) { return 0 }
        return await TravelEstimator.automobileDriveMinutes(
            from: origin,
            to: destination,
            departingAt: departure
        )
    }

    private static func transitMinutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        departingAt departure: Date
    ) async -> Int? {
        if isSamePlace(origin, destination) { return 0 }
        return await TravelEstimator.mapsMinutes(
            from: origin,
            to: destination,
            departingAt: departure,
            transportType: .transit
        )
    }

    private static func isSamePlace(
        _ lhs: CLLocationCoordinate2D,
        _ rhs: CLLocationCoordinate2D
    ) -> Bool {
        let left = CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
        let right = CLLocation(latitude: rhs.latitude, longitude: rhs.longitude)
        return left.distance(from: right) < 80
    }
}
