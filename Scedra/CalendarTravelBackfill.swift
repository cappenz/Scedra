import CoreLocation
import Foundation
import MapKit

/// Backfills drive/transit minutes onto timed EventKit events that already have a place.
/// Uses `TravelEstimator` / `PlaceResolver` — never a second Maps stack.
/// Apple Calendar events keep their EventKit start/end and get linked travel blocks
/// above and below. Settings “part of the event” never pads existing events.
enum CalendarTravelBackfill {
    /// Tests replace Maps with known minutes. Production leaves this nil.
    static var estimateProvider: (([DriveChainStop]) async -> DriveChainEstimates)?
    /// Live `MKDirections` this pass. Cache hits are free; the 2-at-a-time gate
    /// still applies. Remaining unresolved events wait for the next appear.
    static let liveDirectionsPerPass = 4

    static func shouldEstimate(_ item: TodayItem) -> Bool {
        guard !item.isAllDay, !item.isDriveEvent else { return false }
        if item.savedInfo.driveLine != nil { return false }
        return destinationQuery(for: item) != nil || item.navigationCoordinate != nil
    }

    /// Missing pin or missing drive sibling — retry even when notes already exist.
    static func needsTravelRetry(_ item: TodayItem, hasDriveSibling: Bool = false) -> Bool {
        guard !item.isAllDay, !item.isDriveEvent else { return false }
        guard destinationQuery(for: item) != nil || item.navigationCoordinate != nil else {
            return false
        }
        if item.navigationCoordinate == nil { return true }
        return !hasDriveSibling
    }

    /// Location text, street after ·, address in notes, then title.
    static func destinationQuery(for item: TodayItem) -> String? {
        let location = item.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let notesAddress = addressFromNotes(item)
        if !location.isEmpty {
            if PlaceResolver.isSpecificAddress(location) { return location }
            if let notesAddress, PlaceResolver.isSpecificAddress(notesAddress) {
                return "\(location) · \(notesAddress)"
            }
            return location
        }
        if let notesAddress, !notesAddress.isEmpty { return notesAddress }
        let fromNotes = item.savedInfo.placeFromNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fromNotes.isEmpty { return fromNotes }
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    static func addressFromNotes(_ item: TodayItem) -> String? {
        var lines: [String] = []
        if let place = item.savedInfo.placeFromNotes { lines.append(place) }
        lines.append(contentsOf: item.savedInfo.extraLines)
        if let notes = item.notes {
            lines.append(contentsOf: notes.components(separatedBy: .newlines))
        }
        var seen = Set<String>()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            if SavedAppointmentInfo.isManagedDetailLine(trimmed) { continue }
            if trimmed == EventNotes.marker { continue }
            if PlaceResolver.isSpecificAddress(trimmed) { return trimmed }
            if let snippet = PlaceResolver.addressInText(trimmed) { return snippet }
        }
        return nil
    }

    /// Appointments that already have a Drive to / Drive home / between sibling.
    static func siblingAppointmentIDs(from drives: [TodayItem]) -> Set<String> {
        var ids = Set<String>()
        for drive in drives {
            let ends = DriveTimeLogic.endpointIDs(fromNotes: drive.notes)
            if let from = ends.from { ids.insert(from) }
            if let to = ends.to { ids.insert(to) }
            if let linked = DriveTimeLogic.appointmentIdentifier(fromDriveNotes: drive.notes) {
                ids.insert(linked)
            }
        }
        return ids
    }

    /// Missing siblings first so a throttled pass still plants the first Drive to.
    static func prioritizedForRetry(
        _ items: [TodayItem],
        siblingIDs: Set<String>
    ) -> [TodayItem] {
        items.sorted { lhs, rhs in
            let leftMissing = !siblingIDs.contains(lhs.id)
            let rightMissing = !siblingIDs.contains(rhs.id)
            if leftMissing != rightMissing { return leftMissing && !rightMissing }
            return lhs.officialStart < rhs.officialStart
        }
    }

    /// Never skip because the event was created in Apple Calendar.
    static func skipsMissingScedraIdentifier(_ item: TodayItem) -> Bool {
        _ = item.savedInfo.isScedraEvent
        return false
    }

    @MainActor
    static func fill(
        _ item: TodayItem,
        origin: CLLocation,
        fromHome: Bool,
        mode: TravelMode,
        bufferMinutes: Int,
        neighbors: DriveNeighborContext = DriveNeighborContext(),
        resolve: (String) async -> ResolvedPlace?,
        estimate: (CLLocation, Double, Double, TravelMode, Date, Date, Int, Bool) async -> TravelEstimate?,
        write: (TodayItem, TravelEstimate, Double?, Double?, DriveNeighborContext) async throws -> Void
    ) async {
        guard shouldEstimate(item), !skipsMissingScedraIdentifier(item) else { return }

        var latitude = item.latitude
        var longitude = item.longitude
        if latitude == nil || longitude == nil {
            guard let query = destinationQuery(for: item),
                  let place = await resolve(query),
                  let lat = place.latitude,
                  let lng = place.longitude
            else { return }
            latitude = lat
            longitude = lng
        }
        guard let latitude, let longitude else { return }

        guard let travel = await estimate(
            origin,
            latitude,
            longitude,
            mode,
            item.officialStart,
            item.officialEnd,
            bufferMinutes,
            fromHome
        ) else { return }

        var context = neighbors
        if context.onwardGoesHome,
           (context.onwardPlace ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            context.onwardPlace = ScedraString("Home")
        }
        if context.onwardMinutes == nil || (context.onwardMinutes ?? 0) <= 0 {
            let minutes = DriveTimeLogic.reasonableReturnMinutes(travel: travel, neighbors: context)
            context.onwardMinutes = minutes > 0 ? minutes : nil
        }

        try? await write(item, travel, latitude, longitude, context)
    }

    @MainActor
    static func refresh(
        items: [TodayItem],
        using calendar: CalendarStore,
        resolver: PlaceResolver = PlaceResolver()
    ) async {
        let unique = timedAppointments(items)
        guard unique.contains(where: { !$0.isDriveEvent && !$0.isAllDay }) else { return }
        let pin = await resolver.resolvedSearchOrigin()
        let defaults = UserDefaults.standard
        let mode = TravelMode.appointmentDefault()
        let buffer = defaults.object(forKey: UserProfile.homeGapKey) as? Int
            ?? UserProfile.defaultHomeGapMinutes
        if let pin {
            for (index, item) in unique.enumerated() where shouldEstimate(item) {
                let previous = unique[..<index].last { !$0.isDriveEvent }
                await fill(
                    item,
                    origin: pin.location,
                    fromHome: pin.fromHome,
                    mode: item.savedInfo.travelMode ?? mode,
                    bufferMinutes: buffer,
                    neighbors: DriveNeighborContext(previousPlace: previous?.placeLabel),
                    resolve: { await resolver.resolve($0, allowLiveGPS: false) },
                    estimate: { origin, latitude, longitude, mode, start, end, buffer, fromHome in
                        await TravelEstimator.roundTripEstimate(
                            from: origin,
                            toLatitude: latitude,
                            longitude: longitude,
                            mode: mode,
                            start: start,
                            end: end,
                            bufferMinutes: buffer,
                            fromHome: fromHome
                        )
                    },
                    write: { item, travel, latitude, longitude, neighbors in
                        try calendar.updateTravelNotes(
                            for: item,
                            travel: travel,
                            latitude: latitude,
                            longitude: longitude,
                            neighbors: neighbors
                        )
                    }
                )
            }
        }
        var days = Set<Date>()
        let calendarDay = Calendar.current
        for item in unique {
            days.insert(calendarDay.startOfDay(for: item.officialStart))
            days.insert(calendarDay.startOfDay(for: item.start))
        }
        for day in days.sorted() {
            await calendar.reconcileDrives(on: day)
        }
    }

    /// Rebuild the day's Drive to / Drive from / Drive home siblings as one chain.
    @MainActor
    static func reconcileDriveChain(
        items: [TodayItem],
        using calendar: CalendarStore,
        resolver: PlaceResolver = PlaceResolver(),
        origin: CLLocation? = nil,
        homeLocation: CLLocation? = nil,
        homeLabel: String? = nil,
        seeded: DriveChainEstimates = DriveChainEstimates()
    ) async {
        let unique = timedAppointments(items)
        let day = unique.first?.officialStart
            ?? unique.first?.start
            ?? items.first { !$0.isDriveEvent }?.officialStart
            ?? items.first?.start
        let drives: [TodayItem]
        if let day {
            drives = calendar.driveSiblings(on: day)
        } else {
            drives = unique.filter {
                $0.isDriveEvent
                    || DriveTimeLogic.isScedraLinkedDrive(title: $0.title, notes: $0.notes, identifier: $0.id)
            }
        }
        // Every timed appointment that day — Scedra and Apple Calendar — including
        // ones that already have notes or failed a previous pin/drive pass.
        let appointments = unique.filter {
            !$0.isDriveEvent
                && !DriveTimeLogic.isScedraLinkedDrive(title: $0.title, notes: $0.notes, identifier: $0.id)
        }
        guard !appointments.isEmpty else {
            if !drives.isEmpty {
                let empty = DriveChainPlan(
                    legs: [],
                    removeIdentifiers: drives.map(\.id)
                )
                try? calendar.applyDriveChain(empty, calendar: nil, covering: day)
            }
            return
        }

        let defaults = UserDefaults.standard
        let buffer = defaults.object(forKey: UserProfile.homeGapKey) as? Int
            ?? UserProfile.defaultHomeGapMinutes
        let minHome = UserProfile.minimumHomeMinutes
        let mode = TravelMode.appointmentDefault()
        let transport = TravelEstimator.transportType(for: mode)
        let label = (homeLabel ?? defaults.string(forKey: PlaceResolver.homeAddressKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usesLiveMaps = estimateProvider == nil
        let homePin: CLLocation?
        if !usesLiveMaps {
            homePin = homeLocation
        } else if let homeLocation {
            homePin = homeLocation
        } else if PlaceResolver.isHomeAddressSet {
            homePin = await resolver.geocodedHomeLocation()
        } else {
            homePin = nil
        }
        let travelOrigin: CLLocation?
        if !usesLiveMaps {
            travelOrigin = origin
        } else if let origin {
            travelOrigin = origin
        } else {
            travelOrigin = await resolver.resolvedSearchOrigin()?.location
        }

        let siblingIDs = siblingAppointmentIDs(from: drives)
        var resolved: [TodayItem] = []
        for item in prioritizedForRetry(appointments, siblingIDs: siblingIDs) {
            var next = item
            if usesLiveMaps,
               next.navigationCoordinate == nil,
               let query = destinationQuery(for: next),
               let place = await resolver.resolve(query, allowLiveGPS: false) {
                next.latitude = place.latitude
                next.longitude = place.longitude
                if let latitude = place.latitude, let longitude = place.longitude {
                    calendar.attachResolvedPin(
                        to: item,
                        latitude: latitude,
                        longitude: longitude
                    )
                }
            }
            resolved.append(next)
        }
        resolved.sort { $0.officialStart < $1.officialStart }

        let chainStops = resolved.map { item -> DriveChainStop in
            let place = item.placeLabel
                ?? destinationQuery(for: item)
                ?? ""
            let padded = item.savedInfo.isScedraEvent
                && DriveTimePlacement.resolved() == .partOfEvent
                && item.start < item.officialStart.addingTimeInterval(-30)
            return DriveChainStop(
                id: item.id,
                title: item.title,
                place: place,
                start: item.officialStart,
                end: item.officialEnd,
                usesHome: HomeGapLogic.looksLikeHome(place),
                padsInbound: padded
            )
        }

        var estimates = DriveChainEstimates()
        let away = chainStops.filter(DriveChainLogic.isAway)
        if let provider = estimateProvider {
            estimates = await provider(chainStops)
            estimates.fillMissing(from: seeded)
        } else {
            estimates = seeded
            for item in appointments {
                if let minutes = LeaveToNavigateNotifier.driveMinutes(from: item.savedInfo.driveLine), minutes > 0 {
                    if estimates.fromHome[item.id] == nil { estimates.fromHome[item.id] = minutes }
                }
                if let back = LeaveToNavigateNotifier.returnMinutes(from: item.savedInfo.driveLine), back > 0 {
                    if estimates.toHome[item.id] == nil { estimates.toHome[item.id] = back }
                }
            }
        }
        if estimateProvider == nil {
            seedEstimates(from: drives, bufferMinutes: buffer, into: &estimates)
            var liveBudget = liveDirectionsPerPass
            let orderedAway = prioritizedForRetry(
                resolved.filter { item in away.contains { $0.id == item.id } },
                siblingIDs: siblingIDs
            )
            for item in orderedAway {
                guard let stop = away.first(where: { $0.id == item.id }),
                      let pin = item.navigationCoordinate
                else { continue }
                if let homePin {
                    if estimates.fromHome[stop.id] == nil,
                       !TravelEstimator.isApproximatelySamePlace(homePin.coordinate, pin) {
                        let inbound = await mapsMinutesIfBudgeted(
                            from: homePin.coordinate,
                            to: pin,
                            departingAt: TravelEstimator.leaveBy(
                                start: stop.start,
                                travelMinutes: 0,
                                bufferMinutes: buffer
                            ),
                            transportType: transport,
                            budget: &liveBudget
                        )
                        if let inbound, inbound > 0 {
                            estimates.fromHome[stop.id] = inbound
                        }
                    }
                    if estimates.toHome[stop.id] == nil,
                       !TravelEstimator.isApproximatelySamePlace(pin, homePin.coordinate) {
                        let outbound = await mapsMinutesIfBudgeted(
                            from: pin,
                            to: homePin.coordinate,
                            departingAt: stop.end,
                            transportType: transport,
                            budget: &liveBudget
                        )
                        if let outbound, outbound > 0 {
                            estimates.toHome[stop.id] = outbound
                        }
                    }
                } else if let travelOrigin, estimates.fromHome[stop.id] == nil,
                          !TravelEstimator.isApproximatelySamePlace(travelOrigin.coordinate, pin) {
                    let inbound = await mapsMinutesIfBudgeted(
                        from: travelOrigin.coordinate,
                        to: pin,
                        departingAt: TravelEstimator.leaveBy(
                            start: stop.start,
                            travelMinutes: 0,
                            bufferMinutes: buffer
                        ),
                        transportType: transport,
                        budget: &liveBudget
                    )
                    if let inbound, inbound > 0 {
                        estimates.fromHome[stop.id] = inbound
                    }
                }
            }
            if away.count >= 2 {
                for index in 0..<(away.count - 1) {
                    let first = away[index]
                    let second = away[index + 1]
                    let key = "\(first.id)|\(second.id)"
                    guard estimates.between[key] == nil,
                          !DriveTimeLogic.isSamePlace(first.place, second.place),
                          let from = resolved.first(where: { $0.id == first.id })?.navigationCoordinate,
                          let to = resolved.first(where: { $0.id == second.id })?.navigationCoordinate,
                          !TravelEstimator.isApproximatelySamePlace(from, to)
                    else { continue }
                    let minutes = await mapsMinutesIfBudgeted(
                        from: from,
                        to: to,
                        departingAt: first.end,
                        transportType: transport,
                        budget: &liveBudget
                    )
                    if let minutes, minutes > 0 {
                        estimates.between[key] = minutes
                    }
                }
            }
        }

        var existing: [String: String] = DriveEventLinkStore.allChainEntries()
        for item in drives {
            if let key = DriveTimeLogic.chainKey(fromNotes: item.notes) {
                existing[key] = item.id
            }
        }
        let stale = Set(drives.map(\.id))

        let plan = DriveChainLogic.plan(
            stops: chainStops,
            estimates: estimates,
            minHomeMinutes: minHome,
            leavingHomeBuffer: buffer,
            existingIdentifiers: existing,
            staleIdentifiers: Array(stale),
            homeLabel: label.isEmpty ? ScedraString("Home") : label,
            mode: mode
        )
        try? calendar.applyDriveChain(plan, calendar: nil, covering: day)
    }

    /// Last written sibling duration is a known estimate — skip Maps for that pair.
    static func seedEstimates(
        from drives: [TodayItem],
        bufferMinutes: Int,
        into estimates: inout DriveChainEstimates
    ) {
        let buffer = max(bufferMinutes, 0)
        for drive in drives {
            let duration = Int(drive.end.timeIntervalSince(drive.start) / 60)
            guard duration > 0 else { continue }
            let ends = DriveTimeLogic.endpointIDs(fromNotes: drive.notes)
            switch DriveTimeLogic.inferredLeg(title: drive.title, notes: drive.notes) {
            case .inbound:
                if let to = ends.to, estimates.fromHome[to] == nil {
                    estimates.fromHome[to] = max(1, duration - buffer)
                }
            case .onward:
                if let from = ends.from, estimates.toHome[from] == nil {
                    estimates.toHome[from] = duration
                }
            case .between:
                if let from = ends.from, let to = ends.to {
                    let key = "\(from)|\(to)"
                    if estimates.between[key] == nil {
                        estimates.between[key] = duration
                    }
                }
            }
        }
    }

    /// Timed appointments only. Notes, a previous failed pin, or a Scedra vs
    /// Apple Calendar source are not reasons to drop the event.
    static func timedAppointments(_ items: [TodayItem]) -> [TodayItem] {
        var seen = Set<String>()
        return items.filter { item in
            guard !item.isAllDay else { return false }
            if item.isDriveEvent
                || DriveTimeLogic.isScedraLinkedDrive(title: item.title, notes: item.notes, identifier: item.id) {
                return false
            }
            return seen.insert(item.id).inserted
        }
        .sorted { $0.officialStart < $1.officialStart }
    }

    /// Cache first (free). A live miss spends one of this pass's slots so a day
    /// cannot enqueue 50 Directions behind the 2-at-a-time gate.
    static func mapsMinutesIfBudgeted(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        departingAt departure: Date,
        transportType: MKDirectionsTransportType,
        budget: inout Int
    ) async -> Int? {
        if let cached = TravelEstimator.cachedMinutes(
            from: origin,
            to: destination,
            departingAt: departure,
            transportType: transportType
        ) {
            return cached
        }
        guard budget > 0 else { return nil }
        budget -= 1
        return await TravelEstimator.mapsMinutes(
            from: origin,
            to: destination,
            departingAt: departure,
            transportType: transportType
        )
    }

    private static func coordinate(latitude: Double?, longitude: Double?) -> CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        let pin = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(pin) ? pin : nil
    }
}
