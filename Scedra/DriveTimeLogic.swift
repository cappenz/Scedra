import Foundation

/// How drive time is written onto Apple Calendar for **new** Scedra events (Confirm).
/// Default matches Confirm's original padding so existing users do not jump.
/// Existing Apple Calendar events ignore this and always get separate blocks above and below.
enum DriveTimePlacement: String, CaseIterable, Identifiable {
    /// Pad/shift the EventKit event. Official appointment times stay in notes.
    case partOfEvent
    /// Distinct timed EventKit event for the outbound drive, linked to the appointment.
    case separateEvent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .partOfEvent: ScedraString("Part of the event")
        case .separateEvent: ScedraString("Separate event")
        }
    }

    static func resolved(defaults: UserDefaults = .standard) -> DriveTimePlacement {
        DriveTimePlacement(rawValue: defaults.string(forKey: UserProfile.driveTimePlacementKey) ?? "")
            ?? .partOfEvent
    }
}

/// Confirm/task writes honor Settings. Existing Apple Calendar events always get above+below.
enum DriveTimeSource: Equatable {
    case newScedraEvent
    case existingCalendarEvent
}

enum DriveLeg: String, Equatable {
    case inbound
    case onward
    case between
}

/// Previous/next stops and the onward destination for an existing calendar event.
struct DriveNeighborContext: Equatable {
    var previousPlace: String? = nil
    /// Home address or the next event's place. Empty still allows Drive from [this place]
    /// when a reasonable return exists (Maps back, else outbound minutes).
    var onwardPlace: String? = nil
    /// Preferred Maps minutes for the after block. Nil/0 falls back to the routed return,
    /// then outbound — never a guessed hour, and never a reason to skip a real destination.
    var onwardMinutes: Int? = nil
    var onwardGoesHome: Bool = false
}

struct PlannedDriveEvent: Equatable {
    var title: String
    var start: Date
    var end: Date
    var location: String
    /// Existing EventKit identifier to update. Nil means create — never a second copy.
    var existingIdentifier: String?
    var leg: DriveLeg = .inbound
}

struct DriveTimePlan: Equatable {
    var appointmentStart: Date
    var appointmentEnd: Date
    var isAppointmentPadded: Bool
    var driveEvent: PlannedDriveEvent?
    var returnDriveEvent: PlannedDriveEvent?
    var removeDriveEventIdentifier: String?
    var removeReturnDriveEventIdentifier: String?
}

/// What `updateTravelNotes` may write. Existing Apple Calendar events never
/// get a new start or end — only notes plus sibling drive events.
struct DriveTimeWrite: Equatable {
    var notes: String
    /// Times that must remain on the original EKEvent after the write.
    var eventStart: Date
    var eventEnd: Date
    /// False for existing calendar events: CalendarStore must not assign startDate/endDate.
    var writesOriginalTimes: Bool
    var plan: DriveTimePlan
}

/// Pure plan for padding vs linked drive events. EventKit lives in CalendarStore.
enum DriveTimeLogic {
    static let driveMarker = "Scedra drive"
    static let forPrefix = "For:"
    static let fromPrefix = "From:"
    static let toPrefix = "To:"
    static let keyPrefix = "Key:"
    static let legPrefix = "Leg:"

    static func source(for item: TodayItem) -> DriveTimeSource {
        item.savedInfo.isScedraEvent ? .newScedraEvent : .existingCalendarEvent
    }

    static func plan(
        officialStart: Date,
        officialEnd: Date,
        travel: TravelEstimate?,
        extraBeforeMinutes: Int = 0,
        extraAfterMinutes: Int = 0,
        place: String,
        appointmentTitle: String,
        placement: DriveTimePlacement,
        existingDriveEventIdentifier: String? = nil,
        existingReturnDriveEventIdentifier: String? = nil,
        source: DriveTimeSource = .newScedraEvent,
        neighbors: DriveNeighborContext = DriveNeighborContext()
    ) -> DriveTimePlan {
        let inboundID = normalizedIdentifier(existingDriveEventIdentifier)
        let onwardID = normalizedIdentifier(existingReturnDriveEventIdentifier)
        switch source {
        case .existingCalendarEvent:
            return existingEventPlan(
                officialStart: officialStart,
                officialEnd: officialEnd,
                travel: travel,
                extraBeforeMinutes: extraBeforeMinutes,
                place: place,
                appointmentTitle: appointmentTitle,
                inboundID: inboundID,
                onwardID: onwardID,
                neighbors: neighbors
            )
        case .newScedraEvent:
            return newScedraPlan(
                officialStart: officialStart,
                officialEnd: officialEnd,
                travel: travel,
                extraBeforeMinutes: extraBeforeMinutes,
                extraAfterMinutes: extraAfterMinutes,
                place: place,
                appointmentTitle: appointmentTitle,
                placement: placement,
                inboundID: inboundID,
                onwardID: onwardID,
                neighbors: neighbors
            )
        }
    }

    /// Existing Apple Calendar events keep EventKit start/end exactly as they are.
    /// Settings padding applies only to new Scedra Confirm saves.
    static func writesOriginalTimes(source: DriveTimeSource) -> Bool {
        source == .newScedraEvent
    }

    /// Notes-only plus sibling drive events for existing calendar items.
    /// New Scedra events may still pad when Settings say “part of the event”.
    static func write(
        item: TodayItem,
        travel: TravelEstimate,
        neighbors: DriveNeighborContext = DriveNeighborContext(),
        placement: DriveTimePlacement = .partOfEvent,
        existingDriveEventIdentifier: String? = nil,
        existingReturnDriveEventIdentifier: String? = nil
    ) -> DriveTimeWrite {
        let source = source(for: item)
        let place = item.placeLabel ?? ""
        let timedStart = source == .existingCalendarEvent ? item.start : item.officialStart
        let timedEnd = source == .existingCalendarEvent ? item.end : item.officialEnd
        let travelLines = TravelEstimator.noteLines(
            appointmentStart: timedStart,
            appointmentEnd: timedEnd,
            travel: travel,
            place: place
        )
        let notes: String
        if source == .newScedraEvent {
            let original = item.originalText
                ?? (item.savedInfo.isScedraEvent
                    ? ""
                    : (item.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            notes = EventNotes.body(
                forOriginal: original,
                details: travelLines + item.savedInfo.extraLines
            )
        } else {
            notes = EventNotes.travelDetails(
                existingNotes: item.notes,
                details: travelLines,
                place: place
            )
        }
        let plan = plan(
            officialStart: timedStart,
            officialEnd: timedEnd,
            travel: travel,
            extraBeforeMinutes: 0,
            extraAfterMinutes: 0,
            place: place,
            appointmentTitle: item.title,
            placement: placement,
            existingDriveEventIdentifier: existingDriveEventIdentifier,
            existingReturnDriveEventIdentifier: existingReturnDriveEventIdentifier,
            source: source,
            neighbors: neighbors
        )
        let rewrite = writesOriginalTimes(source: source)
        return DriveTimeWrite(
            notes: notes,
            eventStart: rewrite ? plan.appointmentStart : item.start,
            eventEnd: rewrite ? plan.appointmentEnd : item.end,
            writesOriginalTimes: rewrite,
            plan: plan
        )
    }

    /// Skip when Maps returned zero minutes, the place is Home, or there is nothing to pin.
    static func shouldCreateDriveEvent(travel: TravelEstimate?, place: String) -> Bool {
        guard let travel, travel.minutes > 0 else { return false }
        let trimmed = place.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if HomeGapLogic.looksLikeHome(trimmed) { return false }
        return true
    }

    /// Minutes for the after block: explicit Maps figure, else the routed return.
    /// Never copies outbound minutes and never invents a 60-min block.
    static func reasonableReturnMinutes(
        travel: TravelEstimate?,
        neighbors: DriveNeighborContext = DriveNeighborContext()
    ) -> Int {
        let explicit = max(neighbors.onwardMinutes ?? 0, 0)
        if explicit > 0 { return explicit }
        if let back = travel?.routedReturnMinutes, back > 0 { return back }
        return 0
    }

    /// Neighbors for an existing Apple Calendar event: Home if set, else the next stop,
    /// else a Drive from [this place] return. Settings “part of the event” is ignored here.
    static func neighborsForExistingReturn(
        previousPlace: String?,
        homeIsSet: Bool,
        homeLabel: String,
        nextPlace: String?,
        travel: TravelEstimate? = nil
    ) -> DriveNeighborContext {
        let minutes = reasonableReturnMinutes(travel: travel)
        let home = homeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let homeDest = home.isEmpty ? ScedraString("Home") : home
        if homeIsSet {
            return DriveNeighborContext(
                previousPlace: previousPlace,
                onwardPlace: homeDest,
                onwardMinutes: minutes > 0 ? minutes : nil,
                onwardGoesHome: true
            )
        }
        let next = nextPlace?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !next.isEmpty {
            return DriveNeighborContext(
                previousPlace: previousPlace,
                onwardPlace: next,
                onwardMinutes: minutes > 0 ? minutes : nil,
                onwardGoesHome: false
            )
        }
        return DriveNeighborContext(
            previousPlace: previousPlace,
            onwardPlace: nil,
            onwardMinutes: minutes > 0 ? minutes : nil,
            onwardGoesHome: false
        )
    }

    static func driveEventTitle(place: String, appointmentTitle: String, mode: TravelMode = .drive) -> String {
        let title = appointmentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return inboundTitle(to: title, mode: mode)
        }
        let short = shortPlace(place)
        if !short.isEmpty {
            return inboundTitle(to: short, mode: mode)
        }
        return ScedraString("Leave for appointment")
    }

    /// Destination first: "Drive to Target from Boba".
    static func betweenEventTitle(from: String, to: String, mode: TravelMode = .drive) -> String {
        let origin = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = to.trimmingCharacters(in: .whitespacesAndNewlines)
        let left = origin.isEmpty ? ScedraString("appointment") : origin
        let right = destination.isEmpty ? ScedraString("appointment") : destination
        switch mode {
        case .transit: return ScedraString("Transit to \(right) from \(left)")
        case .walk: return ScedraString("Walk to \(right) from \(left)")
        case .drive: return ScedraString("Drive to \(right) from \(left)")
        }
    }

    static func onwardEventTitle(from place: String, goingHome: Bool, mode: TravelMode) -> String {
        if goingHome {
            switch mode {
            case .transit: return ScedraString("Transit home")
            case .walk: return ScedraString("Walk home")
            case .drive: return ScedraString("Drive home")
            }
        }
        let short = shortPlace(place)
        let label = short.isEmpty ? ScedraString("appointment") : short
        switch mode {
        case .transit: return ScedraString("Transit from \(label)")
        case .walk: return ScedraString("Walk from \(label)")
        case .drive: return ScedraString("Drive from \(label)")
        }
    }

    static func shortPlace(_ place: String) -> String {
        let trimmed = place.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(of: "·") else { return trimmed }
        return trimmed[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Skip Drive to when the appointment is already Home, the previous stop is
    /// the same place, or Maps did not return inbound minutes.
    static func shouldSkipInbound(
        appointmentPlace: String,
        previousPlace: String? = nil,
        travel: TravelEstimate?
    ) -> Bool {
        if !shouldCreateDriveEvent(travel: travel, place: appointmentPlace) { return true }
        if isSamePlace(appointmentPlace, previousPlace) { return true }
        return false
    }

    /// Skip the after block only when there is truly nowhere to go (already there,
    /// same next stop, Home, or no minutes). Never invent a duration.
    static func shouldSkipOnward(
        appointmentPlace: String,
        onwardPlace: String,
        goingHome: Bool,
        minutes: Int
    ) -> Bool {
        guard minutes > 0 else { return true }
        if !onwardPlace.isEmpty, isSamePlace(appointmentPlace, onwardPlace) { return true }
        if HomeGapLogic.looksLikeHome(appointmentPlace) { return true }
        if goingHome, HomeGapLogic.looksLikeHome(onwardPlace) && HomeGapLogic.looksLikeHome(appointmentPlace) {
            return true
        }
        return false
    }

    /// Same typed place, including "Clinic" vs "Clinic · address".
    static func isSamePlace(_ a: String?, _ b: String?) -> Bool {
        let left = (a ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let right = (b ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if HomeGapLogic.looksLikeHome(left) && HomeGapLogic.looksLikeHome(right) { return true }
        let leftName = HomeGapLogic.normalizedPlace(left)
        let rightName = HomeGapLogic.normalizedPlace(right)
        if leftName == rightName { return true }
        let leftShort = HomeGapLogic.normalizedPlace(shortPlace(left))
        let rightShort = HomeGapLogic.normalizedPlace(shortPlace(right))
        return !leftShort.isEmpty && leftShort == rightShort
    }

    static func isDriveEvent(title: String, notes: String?) -> Bool {
        if (notes ?? "").contains(driveMarker) { return true }
        let folded = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return folded.hasPrefix("drive to ")
            || folded.hasPrefix("drive from ")
            || folded.hasPrefix("drive home")
            || folded.hasPrefix("leave for ")
            || folded.hasPrefix("transit to ")
            || folded.hasPrefix("transit from ")
            || folded.hasPrefix("transit home")
            || folded.hasPrefix("walk to ")
            || folded.hasPrefix("walk from ")
            || folded.hasPrefix("walk home")
            || folded.hasPrefix("trajet vers ")
            || folded.hasPrefix("trajet depuis ")
            || folded.hasPrefix("trajet maison")
            || folded.hasPrefix("partir pour ")
            || folded.hasPrefix("trayecto a ")
            || folded.hasPrefix("trayecto desde ")
            || folded.hasPrefix("trayecto a casa")
            || folded.hasPrefix("salir hacia ")
            || folded.hasPrefix("fahrt zu ")
            || folded.hasPrefix("fahrt von ")
            || folded.hasPrefix("fahrt nach hause")
            || folded.hasPrefix("los zu ")
    }

    /// Scedra-created Drive to / Drive home / Drive from siblings, including old For:/Leg: notes.
    static func isScedraLinkedDrive(title: String, notes: String?, identifier: String = "") -> Bool {
        if !identifier.isEmpty, DriveEventLinkStore.allDriveIdentifiers().contains(identifier) {
            return true
        }
        let text = notes ?? ""
        if text.contains(driveMarker) { return true }
        if text.contains(forPrefix) || text.contains(keyPrefix) || text.contains(legPrefix) {
            return true
        }
        if text.contains(EventNotes.marker), isDriveEvent(title: title, notes: notes) {
            return true
        }
        return isDriveEvent(title: title, notes: notes)
    }

    static func driveNotes(forAppointment identifier: String, leg: DriveLeg = .inbound) -> String {
        let fromID = leg == .inbound ? nil : identifier
        let toID = leg == .onward ? nil : identifier
        return driveNotes(
            chainKey: DriveChainLogic.chainKey(from: fromID, to: toID),
            fromID: fromID,
            toID: toID,
            linkedAppointmentID: identifier,
            leg: leg
        )
    }

    static func driveNotes(
        chainKey: String,
        fromID: String?,
        toID: String?,
        linkedAppointmentID: String? = nil,
        leg: DriveLeg
    ) -> String {
        let linked = linkedAppointmentID
            ?? toID
            ?? fromID
            ?? ""
        return EventNotes.body(
            forOriginal: "",
            details: [
                driveMarker,
                "\(keyPrefix) \(chainKey)",
                "\(forPrefix) \(linked)",
                "\(fromPrefix) \(fromID ?? DriveChainLogic.homeSentinel)",
                "\(toPrefix) \(toID ?? DriveChainLogic.homeSentinel)",
                "\(legPrefix) \(leg.rawValue)",
            ]
        )
    }

    static func appointmentIdentifier(fromDriveNotes notes: String?) -> String? {
        guard let notes else { return nil }
        guard notes.contains(driveMarker) else { return nil }
        for line in notes.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(forPrefix) else { continue }
            let value = trimmed.dropFirst(forPrefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    static func driveLeg(fromNotes notes: String?) -> DriveLeg {
        guard let notes else { return .inbound }
        for line in notes.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(legPrefix) else { continue }
            let value = trimmed.dropFirst(legPrefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            if value == DriveLeg.between.rawValue { return .between }
            if value == DriveLeg.onward.rawValue { return .onward }
        }
        return .inbound
    }

    static func chainKey(fromNotes notes: String?) -> String? {
        guard let notes, notes.contains(driveMarker) else { return nil }
        for line in notes.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(keyPrefix) else { continue }
            let value = trimmed.dropFirst(keyPrefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        let ends = endpointIDs(fromNotes: notes)
        if ends.from != nil || ends.to != nil {
            return DriveChainLogic.chainKey(from: ends.from, to: ends.to)
        }
        guard let linked = appointmentIdentifier(fromDriveNotes: notes) else { return nil }
        switch driveLeg(fromNotes: notes) {
        case .inbound: return DriveChainLogic.chainKey(from: nil, to: linked)
        case .onward: return DriveChainLogic.chainKey(from: linked, to: nil)
        case .between: return DriveChainLogic.chainKey(from: ends.from ?? linked, to: ends.to)
        }
    }

    static func endpointIDs(fromNotes notes: String?) -> (from: String?, to: String?) {
        (noteValue(fromNotes: notes, prefix: fromPrefix), noteValue(fromNotes: notes, prefix: toPrefix))
    }

    private static func noteValue(fromNotes notes: String?, prefix: String) -> String? {
        guard let notes else { return nil }
        for line in notes.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty || value == DriveChainLogic.homeSentinel { return nil }
            return value
        }
        return nil
    }

    /// `Leg:` in notes wins. Title-only Drive home / Drive from is onward.
    /// "Drive to Target from Boba" (and the old "Drive from Boba to Target") is between, not inbound.
    static func inferredLeg(title: String, notes: String?) -> DriveLeg {
        if (notes ?? "").contains(driveMarker) {
            return driveLeg(fromNotes: notes)
        }
        let folded = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if looksLikeBetweenTitle(folded) { return .between }
        if folded.hasPrefix("drive home")
            || folded.hasPrefix("drive from ")
            || folded.hasPrefix("transit home")
            || folded.hasPrefix("transit from ")
            || folded.hasPrefix("walk home")
            || folded.hasPrefix("walk from ")
            || folded.hasPrefix("trajet maison")
            || folded.hasPrefix("trajet depuis ")
            || folded.hasPrefix("trayecto a casa")
            || folded.hasPrefix("trayecto desde ")
            || folded.hasPrefix("fahrt nach hause")
            || folded.hasPrefix("fahrt von ") {
            return .onward
        }
        return .inbound
    }

    static func looksLikeBetweenTitle(_ title: String) -> Bool {
        let folded = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let toFirst = ["drive to ", "transit to ", "walk to "]
        if toFirst.contains(where: { folded.hasPrefix($0) }) && folded.contains(" from ") {
            return true
        }
        let fromFirst = ["drive from ", "transit from ", "walk from "]
        guard let prefix = fromFirst.first(where: { folded.hasPrefix($0) }) else { return false }
        return folded.dropFirst(prefix.count).contains(" to ")
    }

    private static func newScedraPlan(
        officialStart: Date,
        officialEnd: Date,
        travel: TravelEstimate?,
        extraBeforeMinutes: Int,
        extraAfterMinutes: Int,
        place: String,
        appointmentTitle: String,
        placement: DriveTimePlacement,
        inboundID: String?,
        onwardID: String?,
        neighbors: DriveNeighborContext
    ) -> DriveTimePlan {
        switch placement {
        case .partOfEvent:
            // Inbound pad may wrap the appointment. The return is always its own
            // EventKit event after that block — never absorbed into the end.
            var inboundTravel = travel
            inboundTravel?.returnMinutes = nil
            let block = TravelEstimator.calendarBlock(
                start: officialStart,
                end: officialEnd,
                travel: inboundTravel,
                extraBeforeMinutes: extraBeforeMinutes,
                extraAfterMinutes: extraAfterMinutes
            )
            let onward = plannedOnward(
                leaveAt: block.end,
                travel: travel,
                place: place,
                neighbors: neighbors,
                onwardID: onwardID
            )
            return DriveTimePlan(
                appointmentStart: block.start,
                appointmentEnd: block.end,
                isAppointmentPadded: block.isPadded,
                driveEvent: nil,
                returnDriveEvent: onward,
                removeDriveEventIdentifier: inboundID,
                removeReturnDriveEventIdentifier: onward == nil ? onwardID : nil
            )
        case .separateEvent:
            let drive = inboundEvent(
                officialStart: officialStart,
                travel: travel,
                extraBeforeMinutes: extraBeforeMinutes,
                place: place,
                appointmentTitle: appointmentTitle,
                existingIdentifier: inboundID,
                previousPlace: neighbors.previousPlace
            )
            let leaveAt = officialEnd.addingTimeInterval(
                TimeInterval(max(extraAfterMinutes, 0) * 60)
            )
            let onward = plannedOnward(
                leaveAt: leaveAt,
                travel: travel,
                place: place,
                neighbors: neighbors,
                onwardID: onwardID
            )
            return DriveTimePlan(
                appointmentStart: officialStart,
                appointmentEnd: officialEnd,
                isAppointmentPadded: false,
                driveEvent: drive,
                returnDriveEvent: onward,
                removeDriveEventIdentifier: drive == nil ? inboundID : nil,
                removeReturnDriveEventIdentifier: onward == nil ? onwardID : nil
            )
        }
    }

    private static func existingEventPlan(
        officialStart: Date,
        officialEnd: Date,
        travel: TravelEstimate?,
        extraBeforeMinutes: Int,
        place: String,
        appointmentTitle: String,
        inboundID: String?,
        onwardID: String?,
        neighbors: DriveNeighborContext
    ) -> DriveTimePlan {
        let inbound = inboundEvent(
            officialStart: officialStart,
            travel: travel,
            extraBeforeMinutes: extraBeforeMinutes,
            place: place,
            appointmentTitle: appointmentTitle,
            existingIdentifier: inboundID,
            previousPlace: neighbors.previousPlace
        )

        let onward = plannedOnward(
            leaveAt: officialEnd,
            travel: travel,
            place: place,
            neighbors: neighbors,
            onwardID: onwardID
        )

        return DriveTimePlan(
            appointmentStart: officialStart,
            appointmentEnd: officialEnd,
            isAppointmentPadded: false,
            driveEvent: inbound,
            returnDriveEvent: onward,
            removeDriveEventIdentifier: inbound == nil ? inboundID : nil,
            removeReturnDriveEventIdentifier: onward == nil ? onwardID : nil
        )
    }

    private static func inboundEvent(
        officialStart: Date,
        travel: TravelEstimate?,
        extraBeforeMinutes: Int,
        place: String,
        appointmentTitle: String,
        existingIdentifier: String?,
        previousPlace: String? = nil
    ) -> PlannedDriveEvent? {
        guard !shouldSkipInbound(appointmentPlace: place, previousPlace: previousPlace, travel: travel),
              let travel else { return nil }
        let extra = extraBeforeMinutes > 0 ? extraBeforeMinutes : travel.extraBeforeMinutes
        let start = TravelEstimator.leaveBy(
            start: officialStart,
            travelMinutes: travel.minutes,
            bufferMinutes: travel.bufferMinutes,
            extraBeforeMinutes: extra
        )
        guard start < officialStart else { return nil }
        let location = place.trimmingCharacters(in: .whitespacesAndNewlines)
        return PlannedDriveEvent(
            title: driveEventTitle(
                place: location,
                appointmentTitle: appointmentTitle,
                mode: displayedMode(travel)
            ),
            start: start,
            end: officialStart,
            location: location,
            existingIdentifier: existingIdentifier,
            leg: .inbound
        )
    }

    private static func plannedOnward(
        leaveAt: Date,
        travel: TravelEstimate?,
        place: String,
        neighbors: DriveNeighborContext,
        onwardID: String?
    ) -> PlannedDriveEvent? {
        guard travel != nil else { return nil }
        let goingHome = neighbors.onwardGoesHome
        var onwardPlace = neighbors.onwardPlace?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if onwardPlace.isEmpty, goingHome {
            onwardPlace = ScedraString("Home")
        }
        let onwardMinutes = reasonableReturnMinutes(travel: travel, neighbors: neighbors)
        if shouldSkipOnward(
            appointmentPlace: place,
            onwardPlace: onwardPlace,
            goingHome: goingHome,
            minutes: onwardMinutes
        ) {
            return nil
        }
        return onwardEvent(
            officialEnd: leaveAt,
            minutes: onwardMinutes,
            fromPlace: place,
            onwardPlace: onwardPlace,
            goingHome: goingHome,
            mode: displayedMode(travel),
            existingIdentifier: onwardID
        )
    }

    private static func onwardEvent(
        officialEnd: Date,
        minutes: Int,
        fromPlace: String,
        onwardPlace: String,
        goingHome: Bool,
        mode: TravelMode,
        existingIdentifier: String?
    ) -> PlannedDriveEvent? {
        guard minutes > 0 else { return nil }
        let end = officialEnd.addingTimeInterval(TimeInterval(minutes * 60))
        guard end > officialEnd else { return nil }
        return PlannedDriveEvent(
            title: onwardEventTitle(from: fromPlace, goingHome: goingHome, mode: mode),
            start: officialEnd,
            end: end,
            location: onwardPlace,
            existingIdentifier: existingIdentifier,
            leg: .onward
        )
    }

    private static func inboundTitle(to place: String, mode: TravelMode) -> String {
        switch mode {
        case .transit: ScedraString("Transit to \(place)")
        case .walk: ScedraString("Walk to \(place)")
        case .drive: ScedraString("Drive to \(place)")
        }
    }

    private static func displayedMode(_ travel: TravelEstimate?) -> TravelMode {
        guard let travel else { return .drive }
        return TravelEstimator.displayedMode(for: travel)
    }

    private static func normalizedIdentifier(_ identifier: String?) -> String? {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Local map from chain key (from-event → to-event) → drive EventKit id.
/// Legacy inbound/onward maps still resolve so an old Drive home can be deleted.
enum DriveEventLinkStore {
    static let key = "scedra.driveEventByAppointmentID"
    static let onwardKey = "scedra.returnDriveEventByAppointmentID"
    static let chainMapKey = "scedra.driveEventByChainKey"

    static func identifier(
        for appointmentID: String,
        leg: DriveLeg = .inbound,
        defaults: UserDefaults = .standard
    ) -> String? {
        if let chain = identifier(forChainKey: DriveChainLogic.chainKey(from: leg == .inbound ? nil : appointmentID, to: leg == .onward ? nil : appointmentID), defaults: defaults) {
            return chain
        }
        guard !appointmentID.isEmpty, leg != .between else { return nil }
        let map = defaults.dictionary(forKey: storageKey(for: leg)) as? [String: String] ?? [:]
        let value = map[appointmentID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    static func identifier(forChainKey key: String, defaults: UserDefaults = .standard) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let map = defaults.dictionary(forKey: chainMapKey) as? [String: String] ?? [:]
        let value = map[trimmed]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    static func allChainEntries(defaults: UserDefaults = .standard) -> [String: String] {
        (defaults.dictionary(forKey: chainMapKey) as? [String: String] ?? [:]).filter {
            !$0.key.isEmpty && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Chain keys plus leftover inbound/onward maps from Confirm’s old per-event writes.
    static func allDriveIdentifiers(defaults: UserDefaults = .standard) -> Set<String> {
        var ids = Set(allChainEntries(defaults: defaults).values)
        for key in [self.key, onwardKey] {
            let map = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
            ids.formUnion(map.values)
        }
        return Set(ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    static func save(
        _ driveID: String,
        for appointmentID: String,
        leg: DriveLeg = .inbound,
        defaults: UserDefaults = .standard
    ) {
        guard !appointmentID.isEmpty, !driveID.isEmpty else { return }
        if leg != .between {
            var map = defaults.dictionary(forKey: storageKey(for: leg)) as? [String: String] ?? [:]
            map[appointmentID] = driveID
            defaults.set(map, forKey: storageKey(for: leg))
        }
        let chain = DriveChainLogic.chainKey(
            from: leg == .inbound ? nil : appointmentID,
            to: leg == .onward ? nil : appointmentID
        )
        save(driveID, forChainKey: chain, defaults: defaults)
    }

    static func save(
        _ driveID: String,
        forChainKey key: String,
        defaults: UserDefaults = .standard
    ) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedID = driveID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedID.isEmpty else { return }
        var map = defaults.dictionary(forKey: chainMapKey) as? [String: String] ?? [:]
        map[trimmedKey] = trimmedID
        defaults.set(map, forKey: chainMapKey)
    }

    static func remove(
        for appointmentID: String,
        leg: DriveLeg? = nil,
        defaults: UserDefaults = .standard
    ) {
        guard !appointmentID.isEmpty else { return }
        let legs: [DriveLeg] = leg.map { [$0] } ?? [.inbound, .onward, .between]
        for item in legs where item != .between {
            var map = defaults.dictionary(forKey: storageKey(for: item)) as? [String: String] ?? [:]
            map.removeValue(forKey: appointmentID)
            defaults.set(map, forKey: storageKey(for: item))
        }
        var chain = allChainEntries(defaults: defaults)
        for key in chain.keys where key.contains(appointmentID) {
            chain.removeValue(forKey: key)
        }
        defaults.set(chain, forKey: chainMapKey)
    }

    static func remove(chainKey key: String, defaults: UserDefaults = .standard) {
        var map = allChainEntries(defaults: defaults)
        map.removeValue(forKey: key)
        defaults.set(map, forKey: chainMapKey)
    }

    static func remove(driveID: String, defaults: UserDefaults = .standard) {
        let trimmed = driveID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var chain = allChainEntries(defaults: defaults)
        for key in chain.filter({ $0.value == trimmed }).map(\.key) {
            chain.removeValue(forKey: key)
        }
        defaults.set(chain, forKey: chainMapKey)
        for leg in [DriveLeg.inbound, DriveLeg.onward] {
            var map = defaults.dictionary(forKey: storageKey(for: leg)) as? [String: String] ?? [:]
            let stale = map.filter { $0.value == trimmed }.map(\.key)
            for key in stale { map.removeValue(forKey: key) }
            defaults.set(map, forKey: storageKey(for: leg))
        }
    }

    static func appointmentID(forDrive driveID: String, defaults: UserDefaults = .standard) -> String? {
        guard !driveID.isEmpty else { return nil }
        for (key, value) in allChainEntries(defaults: defaults) where value == driveID {
            if let id = appointmentID(fromChainKey: key) { return id }
        }
        for leg in [DriveLeg.inbound, DriveLeg.onward] {
            let map = defaults.dictionary(forKey: storageKey(for: leg)) as? [String: String] ?? [:]
            if let key = map.first(where: { $0.value == driveID })?.key {
                return key
            }
        }
        return nil
    }

    private static func appointmentID(fromChainKey key: String) -> String? {
        for part in key.split(separator: "|") {
            let value = part.split(separator: ":").last.map(String.init) ?? ""
            if !value.isEmpty, value != DriveChainLogic.homeSentinel { return value }
        }
        return nil
    }

    private static func storageKey(for leg: DriveLeg) -> String {
        switch leg {
        case .inbound: key
        case .onward: onwardKey
        case .between: chainMapKey
        }
    }
}
