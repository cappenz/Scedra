import CoreLocation
import Foundation
import MapKit

struct TravelEstimate: Equatable {
    var minutes: Int
    var mode: TravelMode
    var bufferMinutes: Int
    var leaveBy: Date
    /// True when the user asked for transit but no transit route existed, so this is drive time.
    var fellBackToDriving = false
    /// Separately routed return leg from Apple Maps. Nil means there is no return
    /// figure at all — we never copy the outbound minutes as a guess.
    var returnMinutes: Int?
    /// True when the route started from Settings home, not a live GPS fix.
    var fromHome = false
    /// Arrive-early minutes. Pads leave-by and the calendar start; never Maps drive minutes.
    var extraBeforeMinutes: Int = 0
    /// Stay-after minutes. Pads the calendar end; never Maps drive minutes.
    var extraAfterMinutes: Int = 0

    /// Apple Maps minutes home, only when that leg actually routed.
    var routedReturnMinutes: Int? {
        guard let returnMinutes, returnMinutes > 0 else { return nil }
        return returnMinutes
    }

    /// Drive + drive. Never appointment length, extra-time chips, or the leaving-home buffer.
    var roundTripMinutes: Int {
        minutes + (routedReturnMinutes ?? 0)
    }

    var originCaption: String {
        fromHome ? ScedraString("from Home") : ScedraString("from here")
    }
}

/// Read-only drive-time estimate for the Review screen.
/// Deliberately small: no navigation hand-off, no notifications, no lock-screen banner.
/// It never changes the draft, never blocks the save, and never touches existing events.
enum TravelEstimator {
    static func transportType(for mode: TravelMode) -> MKDirectionsTransportType {
        switch mode {
        case .drive: .automobile
        case .transit: .transit
        case .walk: .walking
        }
    }

    /// Start minus drive minus leaving-home buffer minus extra-before. Drive minutes stay Maps-only.
    static func leaveBy(
        start: Date,
        travelMinutes: Int,
        bufferMinutes: Int,
        extraBeforeMinutes: Int = 0
    ) -> Date {
        let minutes = max(travelMinutes, 0) + max(bufferMinutes, 0) + max(extraBeforeMinutes, 0)
        return start.addingTimeInterval(TimeInterval(-minutes * 60))
    }

    static func estimate(
        minutes: Int,
        mode: TravelMode,
        start: Date,
        bufferMinutes: Int,
        fellBackToDriving: Bool = false,
        returnMinutes: Int? = nil,
        fromHome: Bool = false,
        extraBeforeMinutes: Int = 0,
        extraAfterMinutes: Int = 0
    ) -> TravelEstimate {
        let before = max(extraBeforeMinutes, 0)
        let after = max(extraAfterMinutes, 0)
        return TravelEstimate(
            minutes: max(minutes, 0),
            mode: mode,
            bufferMinutes: max(bufferMinutes, 0),
            leaveBy: leaveBy(
                start: start,
                travelMinutes: minutes,
                bufferMinutes: bufferMinutes,
                extraBeforeMinutes: before
            ),
            fellBackToDriving: fellBackToDriving,
            returnMinutes: returnMinutes,
            fromHome: fromHome,
            extraBeforeMinutes: before,
            extraAfterMinutes: after
        )
    }

    static var loadingMessage: String { ScedraString("Asking Maps for drive time…") }
    static var noOriginMessage: String { ScedraString("Set Home in Settings for drive time") }
    static var noPinMessage: String { ScedraString("Couldn’t pin this place") }
    static var noRouteMessage: String { ScedraString("No drive time from Maps") }
    static var missingReturnMessage: String { ScedraString("couldn't get a drive back") }

    /// Drive time is part of the appointment whenever there is a place and a start.
    static func shouldEstimate(for draft: DraftEvent) -> Bool {
        draft.hasDisplayedDateAndTime && shouldEstimate(location: draft.locationToSave)
    }

    static func shouldEstimate(location: String) -> Bool {
        !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func line(for estimate: TravelEstimate) -> String {
        let leave = estimate.leaveBy.scedraDisplay(date: .omitted, time: .shortened)
        let leavePhrase = ScedraString("leaveByInline \(leave)")
        return "\(travelSummary(for: estimate)) · \(leavePhrase)"
    }

    /// Review / details travel line without leave-by. Saved notes stay English.
    static func travelSummary(for estimate: TravelEstimate) -> String {
        let mode = displayedMode(for: estimate)
        if let back = estimate.routedReturnMinutes {
            return localizedRoundTrip(
                outbound: estimate.minutes,
                back: back,
                total: estimate.roundTripMinutes,
                mode: mode
            )
        }
        return "\(localizedOutboundOnly(outbound: estimate.minutes, mode: mode)) · \(missingReturnMessage(for: estimate))"
    }

    static func displayedMode(for estimate: TravelEstimate) -> TravelMode {
        estimate.fellBackToDriving ? .drive : estimate.mode
    }

    static func localizedRoundTrip(outbound: Int, back: Int, total: Int, mode: TravelMode) -> String {
        switch mode {
        case .transit:
            ScedraString("~\(outbound) min transit · ~\(back) min back · ~\(total) min round trip")
        case .walk:
            ScedraString("~\(outbound) min walk · ~\(back) min back · ~\(total) min round trip")
        case .drive:
            ScedraString("~\(outbound) min drive · ~\(back) min back · ~\(total) min round trip")
        }
    }

    static func localizedOutboundOnly(outbound: Int, mode: TravelMode) -> String {
        switch mode {
        case .transit: ScedraString("~\(outbound) min transit")
        case .walk: ScedraString("~\(outbound) min walk")
        case .drive: ScedraString("~\(outbound) min drive")
        }
    }

    static func localizedBlockCaption(window: String, mode: TravelMode) -> String {
        switch mode {
        case .transit:
            ScedraString("Calendar \(window), with transit")
        case .walk:
            ScedraString("Calendar \(window), with walk")
        case .drive:
            ScedraString("Calendar \(window), with drive")
        }
    }

    /// Stored notes keep the English prefix so we can parse them after a language change.
    static let storedLeaveByPrefix = "Leave by"

    static func storedLeaveByLine(for date: Date) -> String {
        "\(storedLeaveByPrefix) \(date.scedraDisplay(date: .omitted, time: .shortened))"
    }

    /// Today / details chrome. The EventKit line stays `Leave by …`.
    static func localizedLeaveByLine(_ stored: String) -> String {
        guard let time = leaveByTimeText(from: stored) else { return stored }
        return ScedraString("Leave by \(time)")
    }

    /// Stored English plus display-language prefixes, so a locale change still parses.
    static let leaveByPrefixes = ["Leave by", "Partir à", "Salir a las", "Los um"]

    static func leaveByTimeText(from stored: String) -> String? {
        for prefix in leaveByPrefixes {
            if stored.hasPrefix(prefix) {
                let time = stored.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !time.isEmpty { return time }
            }
        }
        return nil
    }

    /// Saved notes store "~28 min there…" in English. Display reformats the numbers.
    static func labeledSavedLine(_ stripped: String, mode: TravelMode) -> String {
        guard let parsed = parseSavedTravelLine(stripped) else { return stripped }
        if let back = parsed.back {
            let total = parsed.total ?? (parsed.outbound + back)
            return localizedRoundTrip(outbound: parsed.outbound, back: back, total: total, mode: mode)
        }
        return localizedOutboundOnly(outbound: parsed.outbound, mode: mode)
    }

    struct ParsedSavedTravel: Equatable {
        var outbound: Int
        var back: Int?
        var total: Int?
    }

    static func parseSavedTravelLine(_ line: String) -> ParsedSavedTravel? {
        guard let regex = try? NSRegularExpression(pattern: #"~(\d+)\s*min"#) else { return nil }
        let ns = line as NSString
        let nums = regex.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap { match -> Int? in
            guard match.numberOfRanges > 1 else { return nil }
            return Int(ns.substring(with: match.range(at: 1)))
        }
        guard let outbound = nums.first else { return nil }
        if nums.count >= 3 {
            return ParsedSavedTravel(outbound: outbound, back: nums[1], total: nums[2])
        }
        if nums.count == 2 {
            return ParsedSavedTravel(outbound: outbound, back: nums[1], total: outbound + nums[1])
        }
        return ParsedSavedTravel(outbound: outbound, back: nil, total: nil)
    }

    /// "~25 min drive each way" only when Apple Maps routed both legs the same.
    static func legSummary(for estimate: TravelEstimate) -> String {
        let mode = displayedMode(for: estimate)
        let outbound = localizedLegMinutes(estimate.minutes, mode: mode)
        guard let back = estimate.routedReturnMinutes else { return outbound }
        guard back != estimate.minutes else { return localizedEachWay(estimate.minutes, mode: mode) }
        return localizedThereAndBack(outbound: estimate.minutes, back: back, mode: mode)
    }

    static func localizedLegMinutes(_ minutes: Int, mode: TravelMode) -> String {
        switch mode {
        case .transit: ScedraString("~\(minutes) min transit")
        case .walk: ScedraString("~\(minutes) min walk")
        case .drive: ScedraString("~\(minutes) min drive")
        }
    }

    static func localizedEachWay(_ minutes: Int, mode: TravelMode) -> String {
        switch mode {
        case .transit: ScedraString("~\(minutes) min transit each way")
        case .walk: ScedraString("~\(minutes) min walk each way")
        case .drive: ScedraString("~\(minutes) min drive each way")
        }
    }

    static func localizedThereAndBack(outbound: Int, back: Int, mode: TravelMode) -> String {
        switch mode {
        case .transit:             ScedraString("~\(outbound) min transit · ~\(back) min back")
        case .walk: ScedraString("~\(outbound) min walk · ~\(back) min back")
        case .drive: ScedraString("~\(outbound) min drive · ~\(back) min back")
        }
    }

    /// Drive wording when Maps fell back; otherwise the chosen mode.
    static func displayedTravelLabel(for estimate: TravelEstimate) -> String {
        (estimate.fellBackToDriving ? TravelMode.drive : estimate.mode).travelLabel
    }

    /// Notes prefix: "Drive" or "Transit". Fallback stays Drive because those minutes are a car route.
    static func noteKind(for estimate: TravelEstimate) -> String {
        (estimate.mode == .transit && !estimate.fellBackToDriving) ? "Transit" : "Drive"
    }

    static func appointmentModeTitle(for estimate: TravelEstimate) -> String {
        (estimate.mode == .transit && !estimate.fellBackToDriving)
            ? TravelMode.transit.appointmentTitleStorage
            : TravelMode.drive.appointmentTitleStorage
    }

    static func loadingMessage(for mode: TravelMode) -> String {
        mode == .transit ? ScedraString("Asking Maps for transit time…") : loadingMessage
    }

    static func noRouteMessage(for mode: TravelMode) -> String {
        mode == .transit ? ScedraString("No transit route") : noRouteMessage
    }

    static func missingReturnMessage(for estimate: TravelEstimate) -> String {
        displayedMode(for: estimate) == .transit
            ? ScedraString("couldn't get a transit back")
            : missingReturnMessage
    }

    /// The block actually written to EventKit. It wraps the drive, so the appointment
    /// itself is never moved — `noteLines` states the real appointment time.
    struct CalendarBlock: Equatable {
        var start: Date
        var end: Date
        /// False when there is no drive estimate: the event is saved at exactly the stated time.
        var isPadded: Bool
    }

    /// Travel-inclusive calendar block.
    /// Start: official start − drive there − leaving-home buffer − extra before.
    /// End: official end + drive back + extra after.
    /// Drive minutes stay Maps-only. Buffer is skipped when there is no drive.
    static func calendarBlock(
        start: Date,
        end: Date,
        travel: TravelEstimate?,
        extraBeforeMinutes: Int = 0,
        extraAfterMinutes: Int = 0
    ) -> CalendarBlock {
        let driveThere = max(travel?.minutes ?? 0, 0)
        let buffer = driveThere > 0 ? max(travel?.bufferMinutes ?? 0, 0) : 0
        let driveBack = max(travel?.routedReturnMinutes ?? 0, 0)
        let before = max(extraBeforeMinutes, 0)
        let after = max(extraAfterMinutes, 0)
        let startPad = driveThere + buffer + before
        let endPad = driveBack + after
        guard startPad > 0 || endPad > 0 else {
            return CalendarBlock(start: start, end: end, isPadded: false)
        }
        return CalendarBlock(
            start: start.addingTimeInterval(TimeInterval(-startPad * 60)),
            end: end.addingTimeInterval(TimeInterval(endPad * 60)),
            isPadded: true
        )
    }

    /// Read-only label so the padded block is never a surprise on the Review screen.
    static func blockLabel(for block: CalendarBlock, mode: TravelMode = .drive) -> String? {
        guard block.isPadded else { return nil }
        let start = block.start.scedraDisplay(date: .omitted, time: .shortened)
        let end = block.end.scedraDisplay(date: .omitted, time: .shortened)
        return localizedBlockCaption(window: "\(start) – \(end)", mode: mode)
    }

    /// Detail lines for the saved event's notes, so the trip is still readable in
    /// Apple Calendar days later. No estimate means no drive lines at all — never a
    /// placeholder and never a guessed number. When the block is padded the real
    /// appointment time comes first, so "6-9" still reads as 6-9.
    static func noteLines(
        appointmentStart: Date,
        appointmentEnd: Date,
        travel: TravelEstimate?,
        place: String,
        extraBeforeMinutes: Int = 0,
        arriveBy: Date? = nil
    ) -> [String] {
        var lines: [String] = []
        if let travel, travel.minutes > 0 {
            lines.append("Appointment: \(appointmentWindow(from: appointmentStart, to: appointmentEnd))")
            lines.append("Travel: \(appointmentModeTitle(for: travel))")
            let kind = noteKind(for: travel)
            if let back = travel.routedReturnMinutes {
                lines.append(
                    "\(kind): ~\(travel.minutes) min there, "
                        + "~\(back) min back (~\(travel.minutes + back) min round trip)"
                )
            } else {
                lines.append("\(kind): ~\(travel.minutes) min there")
            }
            let leave = leaveBy(
                start: arriveBy ?? appointmentStart,
                travelMinutes: travel.minutes,
                bufferMinutes: travel.bufferMinutes,
                extraBeforeMinutes: extraBeforeMinutes > 0 ? extraBeforeMinutes : travel.extraBeforeMinutes
            )
            lines.append(storedLeaveByLine(for: leave))
        }
        let place = place.trimmingCharacters(in: .whitespacesAndNewlines)
        if !place.isEmpty {
            lines.append(place)
        }
        return lines
    }

    static func appointmentWindow(from start: Date, to end: Date, calendar: Calendar = .current) -> String {
        let startText = start.scedraDisplay(date: .omitted, time: .shortened)
        let endText = calendar.isDate(start, inSameDayAs: end)
            ? end.scedraDisplay(date: .omitted, time: .shortened)
            : end.scedraDisplay(date: .abbreviated, time: .shortened)
        return "\(startText) – \(endText)"
    }

    static func note(for estimate: TravelEstimate) -> String? {
        var parts: [String] = [estimate.originCaption]
        if estimate.fellBackToDriving {
            parts.append(ScedraString("No transit — this is drive time"))
        }
        if estimate.bufferMinutes > 0 {
            parts.append(ScedraString("includes \(estimate.bufferMinutes) min leaving-home buffer"))
        }
        return parts.joined(separator: " · ")
    }

    /// Current/last-known pin is trusted for “from here” when Search from is Current
    /// location. Home-first only when that setting is Home (and Home is set).
    /// Simulator is not a reason to discard GPS.
    static func shouldTrustCurrentFix(
        homeAddressIsSet: Bool,
        isSimulator: Bool,
        searchFrom: PlaceSearchFrom = .currentLocation
    ) -> Bool {
        _ = isSimulator
        if searchFrom == .currentLocation { return true }
        if homeAddressIsSet { return false }
        return true
    }

    /// Drive origin: current or last-known pin when Search from is Current location
    /// and a pin exists. Fallback Home, then a trusted live fix.
    static func preferredOrigin(
        current: CLLocation?,
        home: CLLocation?,
        currentIsTrusted: Bool,
        lastKnown: CLLocation? = nil,
        searchFrom: PlaceSearchFrom = .currentLocation
    ) -> CLLocation? {
        let pin = current ?? lastKnown
        if searchFrom == .currentLocation {
            if currentIsTrusted, let current { return current }
            if let lastKnown { return lastKnown }
            if let home { return home }
            if currentIsTrusted, let pin { return pin }
            return nil
        }
        if let home { return home }
        if currentIsTrusted, let pin { return pin }
        return lastKnown
    }

    /// MKDirections reports seconds. There is no 60-minute default — 0 or garbage is "unknown".
    static func minutesFromExpectedTravelTime(_ seconds: TimeInterval) -> Int? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let minutes = Int((seconds / 60).rounded())
        return minutes > 0 ? minutes : nil
    }

    /// When she actually leaves: start − drive − leaving-home buffer − extra-before.
    /// Drive minutes unknown → treat drive as 0 for the first Maps pass.
    static func outboundMapsDeparture(
        start: Date,
        knownDriveMinutes: Int?,
        bufferMinutes: Int,
        extraBeforeMinutes: Int,
        now: Date = Date()
    ) -> Date {
        let planned = leaveBy(
            start: start,
            travelMinutes: max(knownDriveMinutes ?? 0, 0),
            bufferMinutes: bufferMinutes,
            extraBeforeMinutes: extraBeforeMinutes
        )
        return mapsDepartureDate(planned: planned, now: now)
    }

    /// When she actually drives home: official end plus extra-after (that's when she leaves).
    static func returnMapsDeparture(
        end: Date,
        extraAfterMinutes: Int,
        now: Date = Date()
    ) -> Date {
        let planned = end.addingTimeInterval(TimeInterval(max(extraAfterMinutes, 0) * 60))
        return mapsDepartureDate(planned: planned, now: now)
    }

    /// Future leave-by / return-leave. Never "now" while the appointment is still ahead.
    static func mapsDepartureDate(planned: Date, now: Date = Date()) -> Date {
        planned > now ? planned : now
    }

    /// Apple Maps minutes for the requested mode at the planned leave-by.
    /// Transit with no route is "No transit route" — never a silent car number.
    static func estimate(
        from origin: CLLocation,
        toLatitude latitude: Double,
        longitude: Double,
        mode: TravelMode,
        start: Date,
        bufferMinutes: Int,
        extraBeforeMinutes: Int = 0,
        extraAfterMinutes: Int = 0
    ) async -> TravelEstimate? {
        let destination = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(destination) else { return nil }
        guard CLLocationCoordinate2DIsValid(origin.coordinate) else { return nil }

        // First pass: leave-by without travel minutes (start − buffer − extra-before), not "now".
        let seedDeparture = outboundMapsDeparture(
            start: start,
            knownDriveMinutes: nil,
            bufferMinutes: bufferMinutes,
            extraBeforeMinutes: extraBeforeMinutes
        )
        let requested = transportType(for: mode)
        // Public transport must stay transit minutes. A missing bus/train
        // route is "couldn't get transit" — never a silent car time.
        guard var travelMinutes = await mapsMinutes(
            from: origin.coordinate,
            to: destination,
            departingAt: seedDeparture,
            transportType: requested
        ) else { return nil }

        // Second pass: traffic / scheduled transit at the real leave-by.
        let leaveDeparture = outboundMapsDeparture(
            start: start,
            knownDriveMinutes: travelMinutes,
            bufferMinutes: bufferMinutes,
            extraBeforeMinutes: extraBeforeMinutes
        )
        if abs(leaveDeparture.timeIntervalSince(seedDeparture)) >= 60,
           let refined = await mapsMinutes(
               from: origin.coordinate,
               to: destination,
               departingAt: leaveDeparture,
               transportType: requested
           ) {
            travelMinutes = refined
        }

        return estimate(
            minutes: travelMinutes,
            mode: mode,
            start: start,
            bufferMinutes: bufferMinutes,
            fellBackToDriving: false,
            extraBeforeMinutes: extraBeforeMinutes,
            extraAfterMinutes: extraAfterMinutes
        )
    }

    /// Outbound Apple Maps drive, plus the trip home when Maps can route that too.
    /// A missing return leg stays missing — it does not copy the outbound minutes,
    /// and it does not add appointment length, extra time, or the leaving-home buffer.
    static func roundTripEstimate(
        from origin: CLLocation,
        toLatitude latitude: Double,
        longitude: Double,
        mode: TravelMode,
        start: Date,
        end: Date,
        bufferMinutes: Int,
        fromHome: Bool = false,
        extraBeforeMinutes: Int = 0,
        extraAfterMinutes: Int = 0
    ) async -> TravelEstimate? {
        guard var outbound = await estimate(
            from: origin,
            toLatitude: latitude,
            longitude: longitude,
            mode: mode,
            start: start,
            bufferMinutes: bufferMinutes,
            extraBeforeMinutes: extraBeforeMinutes,
            extraAfterMinutes: extraAfterMinutes
        ) else {
            return nil
        }
        outbound.fromHome = fromHome
        let destination = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        outbound.returnMinutes = await mapsMinutes(
            from: destination,
            to: origin.coordinate,
            departingAt: returnMapsDeparture(end: end, extraAfterMinutes: extraAfterMinutes),
            transportType: transportType(for: outbound.mode)
        )
        return outbound
    }

    /// One Apple Maps car route. `expectedTravelTime` is seconds of driving — never
    /// (eta − now), never appointment length. `arrivalDate` is never set: it can count
    /// waiting or pick transit. `nil` means Maps had no automobile route.
    static func automobileDriveMinutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        departingAt departure: Date
    ) async -> Int? {
        await mapsMinutes(
            from: origin,
            to: destination,
            departingAt: departure,
            transportType: .automobile
        )
    }

    /// Apple Maps minutes for a transport type at a planned departure. Never guesses.
    /// Successful minutes are cached by origin + destination + mode + 5-minute
    /// departure bucket so day-chain reconcile can reuse them. Failures (including
    /// GEOErrorDomain -3 throttle) are not cached. Same-place pins skip Maps.
    static func mapsMinutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        departingAt departure: Date,
        transportType: MKDirectionsTransportType
    ) async -> Int? {
        guard CLLocationCoordinate2DIsValid(origin), CLLocationCoordinate2DIsValid(destination) else {
            return nil
        }
        if isApproximatelySamePlace(origin, destination) {
            return nil
        }
        if let cached = cachedMinutes(
            from: origin,
            to: destination,
            departingAt: departure,
            transportType: transportType
        ) {
            return cached
        }

        let minutes = await MKDirectionsGate.shared.limit {
            await requestMapsMinutes(
                from: origin,
                to: destination,
                departingAt: departure,
                transportType: transportType
            )
        }
        if let minutes, minutes > 0 {
            rememberMinutes(
                from: origin,
                to: destination,
                departingAt: departure,
                transportType: transportType,
                minutes: minutes
            )
        }
        return minutes
    }

    /// Home / same-building pins — do not spend an MKDirections quota.
    static func isApproximatelySamePlace(
        _ lhs: CLLocationCoordinate2D,
        _ rhs: CLLocationCoordinate2D
    ) -> Bool {
        HomeGapLogic.pinsAreSamePlace(lhs, rhs)
    }

    static func cachedMinutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        departingAt departure: Date,
        transportType: MKDirectionsTransportType
    ) -> Int? {
        TravelMinutesCache.minutes(
            from: origin,
            to: destination,
            departingAt: departure,
            transportType: transportType
        )
    }

    static func rememberMinutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        departingAt departure: Date,
        transportType: MKDirectionsTransportType,
        minutes: Int
    ) {
        TravelMinutesCache.store(
            from: origin,
            to: destination,
            departingAt: departure,
            transportType: transportType,
            minutes: minutes
        )
    }

    static func resetMinutesCache() {
        TravelMinutesCache.reset()
    }

    private static func requestMapsMinutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        departingAt departure: Date,
        transportType: MKDirectionsTransportType
    ) async -> Int? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = transportType
        request.requestsAlternateRoutes = false
        request.departureDate = mapsDepartureDate(planned: departure)
        request.arrivalDate = nil

        do {
            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.first,
                  accepts(routeTransport: route.transportType, requested: transportType)
            else { return nil }
            return minutesFromExpectedTravelTime(route.expectedTravelTime)
        } catch {
            return nil
        }
    }

    /// Maps sometimes answers a transit request with a car route. That is drive time — reject it.
    static func accepts(routeTransport actual: MKDirectionsTransportType, requested: MKDirectionsTransportType) -> Bool {
        if requested == .any { return true }
        if requested == .automobile {
            return actual == .automobile || actual.contains(.automobile)
        }
        if requested == .transit {
            return actual == .transit || actual.contains(.transit)
        }
        if requested == .walking {
            return actual == .walking || actual.contains(.walking)
        }
        return actual == requested
    }
}

/// Caps live `MKDirections.calculate()` so a day reconcile cannot burst 50 pairs.
private actor MKDirectionsGate {
    static let shared = MKDirectionsGate()
    private let limit = 2
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func limit<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
        await acquire()
        let result = await work()
        release()
        return result
    }

    private func acquire() async {
        while running >= limit {
            await withCheckedContinuation { waiting.append($0) }
        }
        running += 1
    }

    private func release() {
        running -= 1
        if waiting.isEmpty { return }
        waiting.removeFirst().resume()
    }
}

/// In-memory + small UserDefaults JSON. Keyed by pins, transport, and a 5-minute leave bucket.
private enum TravelMinutesCache {
    static let defaultsKey = "scedra.travelMinutesCache"
    static let bucketSeconds: TimeInterval = 5 * 60
    private static let maxEntries = 200
    private static let lock = NSLock()
    private static var memory: [String: Entry] = load()

    struct Entry: Codable {
        var minutes: Int
        var savedAt: TimeInterval
    }

    static func minutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        departingAt departure: Date,
        transportType: MKDirectionsTransportType
    ) -> Int? {
        let key = cacheKey(from: origin, to: destination, departingAt: departure, transportType: transportType)
        lock.lock()
        let value = memory[key]?.minutes
        lock.unlock()
        return value.flatMap { $0 > 0 ? $0 : nil }
    }

    static func store(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        departingAt departure: Date,
        transportType: MKDirectionsTransportType,
        minutes: Int
    ) {
        guard minutes > 0 else { return }
        let key = cacheKey(from: origin, to: destination, departingAt: departure, transportType: transportType)
        lock.lock()
        memory[key] = Entry(minutes: minutes, savedAt: Date().timeIntervalSince1970)
        persistLocked()
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        memory = [:]
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        lock.unlock()
    }

    static func cacheKey(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        departingAt departure: Date,
        transportType: MKDirectionsTransportType
    ) -> String {
        let bucket = Int(floor(departure.timeIntervalSince1970 / bucketSeconds))
        func pin(_ coordinate: CLLocationCoordinate2D) -> String {
            String(format: "%.4f,%.4f", coordinate.latitude, coordinate.longitude)
        }
        return "\(pin(origin))|\(pin(destination))|\(transportType.rawValue)|\(bucket)"
    }

    private static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func persistLocked() {
        if memory.count > maxEntries {
            let keep = memory.sorted { $0.value.savedAt > $1.value.savedAt }.prefix(maxEntries)
            memory = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(memory) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
