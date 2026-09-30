import CoreLocation
import Foundation

/// One timed stop in a day, using the official appointment — never a travel-padded
/// calendar block. Missing coordinates fall back to Home when the place is empty
/// or literally "home".
struct HomeGapStop: Equatable, Identifiable {
    var id: String
    var title: String
    var place: String
    var officialStart: Date
    var officialEnd: Date
    var extraBeforeMinutes: Int
    var extraAfterMinutes: Int
    var latitude: Double? = nil
    var longitude: Double? = nil
    var usesHome: Bool
    /// Original wording or portal notes — standing / what-to-bring can read these.
    var notes: String = ""

    /// She is free to drive after the appointment plus typed After extra.
    var leaveAt: Date {
        officialEnd.addingTimeInterval(TimeInterval(max(extraAfterMinutes, 0) * 60))
    }

    var displayPlace: String {
        let trimmed = place.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return usesHome ? ScedraString("Home") : title
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        let pin = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(pin) ? pin : nil
    }
}

/// Apple Maps minutes for the three legs. Home legs are optional so a
/// missing Home pin can still flag impossible A→B travel. Transit is a
/// consideration, never a guessed number — nil means Maps had no transit route.
struct HomeGapMinutes: Equatable {
    var aToHome: Int?
    var homeToB: Int?
    var aToB: Int
    var aToBTransit: Int?
    var aToHomeTransit: Int?
    var homeToBTransit: Int?
}

enum HomeGapKind: Equatable {
    case cannotBeLived
    case goHome
    case stayOut
    /// Driving misses B, but transit at the planned leave time fits.
    case takeTransit
}

enum HomeGapWait: Equatable {
    /// Spare time after the direct drive is short — sit tight until leave-by.
    case stayAtA
    /// Enough leftover to start toward B and wait there.
    case headTowardB
}

struct HomeGapSuggestion: Equatable, Identifiable {
    var id: String
    var kind: HomeGapKind
    var headline: String
    var detail: String
    var bringItems: [String]
    var walkingNote: String?
    var transitNote: String?
    var firstTitle: String
    var secondTitle: String
    /// Local notification time — 15 minutes before the first appointment ends.
    var notifyAt: Date
    /// Next stop pin, when we have one — so Navigate can open Maps from the card.
    var destinationLatitude: Double? = nil
    var destinationLongitude: Double? = nil
    /// Nearest public-transport stop at B, when Maps knows one.
    var nearbyTransitLine: String? = nil

    /// Short title while the card is collapsed.
    var collapsedHeadline: String {
        switch kind {
        case .cannotBeLived:
            headline
        case .stayOut:
            ScedraString("Don’t go home")
        case .takeTransit:
            ScedraString("Take transit")
        case .goHome:
            headline
        }
    }

    /// Second collapsed line. Event titles stay raw — never translated.
    var collapsedSubtitle: String? {
        switch kind {
        case .cannotBeLived:
            guard headline == ScedraString("These overlap") else { return nil }
            return Self.pairLine(firstTitle, secondTitle)
        case .stayOut:
            let destination = secondTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return destination.isEmpty ? nil : ScedraString("Go to \(destination)")
        case .takeTransit, .goHome:
            return nil
        }
    }

    /// Both appointment names as stored. Slash is punctuation, not a translated word.
    static func pairLine(_ first: String, _ second: String) -> String {
        "\(first) / \(second)"
    }
}

/// Fit / no-fit arithmetic for “can she go home between A and B?”
/// Fake minutes in tests. Live MKDirections stay in `HomeGapRouter`.
enum HomeGapLogic {
    /// Spare minutes after A→B that still count as “short” — stay put.
    static let shortLeftoverMinutes = 15
    /// How far before A ends we remind her of the plan.
    static let notifyLeadMinutes = 15
    /// Same saved pin / address — close enough that going home is not the question.
    static let samePlaceMeters: CLLocationDistance = 80

    /// Two timed events on the same clock. Places and drive minutes are irrelevant.
    static func overlapSuggestion(
        first: HomeGapStop,
        second: HomeGapStop,
        standingBring: [String] = [],
        calendar: Calendar = .current
    ) -> HomeGapSuggestion? {
        guard calendar.isDate(first.officialStart, inSameDayAs: second.officialStart) else { return nil }
        guard ConflictLogic.overlaps(
            start: first.officialStart,
            end: first.officialEnd,
            otherStart: second.officialStart,
            otherEnd: second.officialEnd
        ) else { return nil }
        return make(
            first: first,
            second: second,
            kind: .cannotBeLived,
            headline: ScedraString("These overlap"),
            detail: HomeGapSuggestion.pairLine(first.title, second.title),
            bring: WhatToBring.pack(for: second, kind: .cannotBeLived, standing: standingBring),
            walkingNote: nil,
            transitNote: nil
        )
    }

    static func consecutivePairs(
        from stops: [HomeGapStop],
        calendar: Calendar = .current
    ) -> [(HomeGapStop, HomeGapStop)] {
        let timed = stops.sorted { $0.officialStart < $1.officialStart }
        var pairs: [(HomeGapStop, HomeGapStop)] = []
        let grouped = Dictionary(grouping: timed) { calendar.startOfDay(for: $0.officialStart) }
        for day in grouped.values {
            let ordered = day.sorted { lhs, rhs in
                if lhs.officialStart != rhs.officialStart { return lhs.officialStart < rhs.officialStart }
                return lhs.officialEnd < rhs.officialEnd
            }
            guard ordered.count >= 2 else { continue }
            for index in 0..<(ordered.count - 1) {
                pairs.append((ordered[index], ordered[index + 1]))
            }
        }
        return pairs.sorted { $0.0.officialStart < $1.0.officialStart }
    }

    static func suggestion(
        first: HomeGapStop,
        second: HomeGapStop,
        minutes: HomeGapMinutes,
        leavingHomeBuffer: Int,
        walkMinutes: Int,
        preferTransit: Bool = false,
        minHomeMinutes: Int = 0,
        standingBring: [String] = [],
        calendar: Calendar = .current
    ) -> HomeGapSuggestion? {
        if let overlap = overlapSuggestion(
            first: first,
            second: second,
            standingBring: standingBring,
            calendar: calendar
        ) {
            return overlap
        }
        guard minutes.aToB >= 0 else { return nil }

        let leaveA = first.leaveAt
        let gap = Int(second.officialStart.timeIntervalSince(leaveA) / 60)
        let before = max(second.extraBeforeMinutes, 0)
        let buffer = max(leavingHomeBuffer, 0)
        let leftover = gap - (minutes.aToB + before)
        let transitFits = minutes.aToBTransit.map { gap - ($0 + before) >= 0 } ?? false
        let transit = transitNote(
            drive: minutes.aToB,
            transit: minutes.aToBTransit,
            preferTransit: preferTransit
        )

        if leftover < 0 {
            if let transitMinutes = minutes.aToBTransit, transitFits {
                return make(
                    first: first,
                    second: second,
                    kind: .takeTransit,
                    headline: ScedraString("Take transit to \(second.title)"),
                    detail: ScedraString("~\(minutes.aToB) min drive won’t make it. Transit is ~\(transitMinutes) min and fits."),
                    bring: WhatToBring.pack(for: second, kind: .takeTransit, standing: standingBring),
                    walkingNote: walkingNote(aToB: minutes.aToB, walkMinutes: walkMinutes),
                    transitNote: nil
                )
            }
            let gapWord = gap <= 0
                ? ScedraString("no time")
                : ScedraString("only \(gap) min")
            return make(
                first: first,
                second: second,
                kind: .cannotBeLived,
                headline: ScedraString("Conflict"),
                detail: ScedraString("~\(minutes.aToB) min drive, \(gapWord) between \(first.title) and \(second.title)."),
                bring: WhatToBring.pack(for: second, kind: .cannotBeLived, standing: standingBring),
                walkingNote: walkingNote(aToB: minutes.aToB, walkMinutes: walkMinutes),
                transitNote: transit
            )
        }

        // Same office / same pin: she can stay there. Don’t-go-home is only for two places.
        if isSamePlace(first, second) {
            return nil
        }

        if let aToHome = minutes.aToHome, let homeToB = minutes.homeToB {
            let viaHomeNeeded = aToHome + homeToB + buffer + before
            let atHome = minutesAtHome(
                gap: gap,
                aToHome: aToHome,
                homeToB: homeToB,
                buffer: buffer,
                before: before
            )
            if viaHomeNeeded <= gap, atHome >= max(minHomeMinutes, 0) {
                // Going home is the default. Don't narrate it.
                return nil
            }
            if viaHomeNeeded <= gap, atHome < max(minHomeMinutes, 0) {
                return stayOut(
                    first: first,
                    second: second,
                    leftover: leftover,
                    minutes: minutes,
                    walkMinutes: walkMinutes,
                    transit: transit,
                    standing: standingBring,
                    reason: tooLittleHomeReason(atHome: atHome, minHome: minHomeMinutes)
                )
            }

            if let transitHome = minutes.aToHomeTransit, let transitBack = minutes.homeToBTransit {
                let viaHomeTransit = transitHome + transitBack + buffer + before
                let transitAtHome = minutesAtHome(
                    gap: gap,
                    aToHome: transitHome,
                    homeToB: transitBack,
                    buffer: buffer,
                    before: before
                )
                if viaHomeTransit <= gap, transitAtHome >= max(minHomeMinutes, 0) {
                    // Transit makes the home stop work. Still assumed — not a card.
                    return nil
                }
                if viaHomeTransit <= gap, transitAtHome < max(minHomeMinutes, 0) {
                    return stayOut(
                        first: first,
                        second: second,
                        leftover: leftover,
                        minutes: minutes,
                        walkMinutes: walkMinutes,
                        transit: transit,
                        standing: standingBring,
                        reason: tooLittleHomeReason(atHome: transitAtHome, minHome: minHomeMinutes)
                    )
                }
            }

            return stayOut(
                first: first,
                second: second,
                leftover: leftover,
                minutes: minutes,
                walkMinutes: walkMinutes,
                transit: transit,
                standing: standingBring
            )
        }

        // No Home legs — still say stay out / what to bring when A→B itself fits.
        return stayOut(
            first: first,
            second: second,
            leftover: leftover,
            minutes: minutes,
            walkMinutes: walkMinutes,
            transit: transit,
            standing: standingBring
        )
    }

    private static func tooLittleHomeReason(atHome: Int, minHome: Int) -> String {
        ScedraString("Only \(max(atHome, 0)) min at home (need \(max(minHome, 0))).")
    }

    /// Minutes actually sitting at home if she takes the drive-home path.
    static func minutesAtHome(
        gap: Int,
        aToHome: Int,
        homeToB: Int,
        buffer: Int,
        before: Int
    ) -> Int {
        gap - aToHome - homeToB - max(buffer, 0) - max(before, 0)
    }

    static func notifyDate(before first: HomeGapStop) -> Date {
        let beforeEnd = first.officialEnd.addingTimeInterval(TimeInterval(-notifyLeadMinutes * 60))
        let beforeLeave = first.leaveAt.addingTimeInterval(-5 * 60)
        return min(beforeEnd, beforeLeave)
    }

    private static func stayOut(
        first: HomeGapStop,
        second: HomeGapStop,
        leftover: Int,
        minutes: HomeGapMinutes,
        walkMinutes: Int,
        transit: String?,
        standing: [String],
        reason: String? = nil
    ) -> HomeGapSuggestion {
        let wait: HomeGapWait = leftover < shortLeftoverMinutes ? .stayAtA : .headTowardB
        let waitLine: String = {
            switch wait {
            case .stayAtA:
                return ScedraString("Stay at \(first.title) — \(max(leftover, 0)) min to spare.")
            case .headTowardB:
                return ScedraString("Head to \(second.title) — \(leftover) min to spare.")
            }
        }()
        var detail = ScedraString("~\(minutes.aToB) min drive from \(first.title). \(waitLine)")
        if let reason, !reason.isEmpty {
            detail += " \(reason)"
        }
        return make(
            first: first,
            second: second,
            kind: .stayOut,
            headline: ScedraString("Don’t go home — go to \(second.title)"),
            detail: detail,
            bring: WhatToBring.pack(for: second, kind: .stayOut, standing: standing),
            walkingNote: walkingNote(aToB: minutes.aToB, walkMinutes: walkMinutes),
            transitNote: transit
        )
    }

    /// Walking is an extra mention only. Car minutes stay the numbers on the card.
    static func walkingNote(aToB: Int, walkMinutes: Int) -> String? {
        let walk = max(walkMinutes, 0)
        guard walk > 0, aToB > 0, aToB <= walk else { return nil }
        return ScedraString("Also a \(walk) min walk.")
    }

    /// Public transit at the planned leave time — never last-bus, never a guess.
    static func transitNote(drive: Int, transit: Int?, preferTransit: Bool) -> String? {
        guard let transit, transit > 0 else { return nil }
        if preferTransit {
            if drive > 0, drive != transit {
                return ScedraString("Transit ~\(transit) min (preferred). Drive ~\(drive) min.")
            }
            return ScedraString("Transit ~\(transit) min (preferred).")
        }
        if drive <= 0 {
            return ScedraString("Transit ~\(transit) min.")
        }
        if transit < drive {
            return ScedraString("Transit ~\(transit) min, faster than ~\(drive) min drive.")
        }
        if transit > drive {
            return ScedraString("Transit ~\(transit) min (drive ~\(drive) min).")
        }
        return ScedraString("Transit ~\(transit) min, same as driving.")
    }

    static func transitHomeNote(minutes: HomeGapMinutes, preferTransit: Bool) -> String? {
        guard let home = minutes.aToHomeTransit, let out = minutes.homeToBTransit else {
            return transitNote(drive: minutes.aToB, transit: minutes.aToBTransit, preferTransit: preferTransit)
        }
        return ScedraString("Transit home and back ~\(home + out) min.")
    }

    /// Same address, both Home, or pins within `samePlaceMeters`.
    static func isSamePlace(
        _ first: HomeGapStop,
        _ second: HomeGapStop,
        home: CLLocation? = nil
    ) -> Bool {
        let firstHome = first.usesHome || looksLikeHome(first.place)
        let secondHome = second.usesHome || looksLikeHome(second.place)
        if firstHome && secondHome { return true }

        let leftName = normalizedPlace(first.place)
        let rightName = normalizedPlace(second.place)
        if !leftName.isEmpty, leftName == rightName { return true }

        guard let left = pin(for: first, home: home),
              let right = pin(for: second, home: home)
        else { return false }
        return pinsAreSamePlace(left, right)
    }

    static func pinsAreSamePlace(
        _ lhs: CLLocationCoordinate2D,
        _ rhs: CLLocationCoordinate2D
    ) -> Bool {
        let left = CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
        let right = CLLocation(latitude: rhs.latitude, longitude: rhs.longitude)
        return left.distance(from: right) < samePlaceMeters
    }

    static func normalizedPlace(_ place: String) -> String {
        place
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    static func pin(
        for stop: HomeGapStop,
        home: CLLocation?
    ) -> CLLocationCoordinate2D? {
        if stop.usesHome || looksLikeHome(stop.place) {
            return home?.coordinate
        }
        if let coordinate = stop.coordinate {
            return coordinate
        }
        if stop.place.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return home?.coordinate
        }
        return nil
    }

    static func looksLikeHome(_ place: String) -> Bool {
        let folded = place
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return folded == "home" || folded == "house" || folded.hasPrefix("home ·")
    }

    static func enrichFromMemory(_ stop: HomeGapStop) -> HomeGapStop {
        var stop = stop
        if stop.coordinate != nil { return stop }
        if let remembered = PlaceMemory.remembered(forTitle: stop.title)
            ?? PlaceMemory.remembered(matchingPlaceQuery: stop.place),
           let latitude = remembered.latitude,
           let longitude = remembered.longitude {
            stop.latitude = latitude
            stop.longitude = longitude
            if stop.place.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stop.place = remembered.location
            }
        }
        return stop
    }

    private static func make(
        first: HomeGapStop,
        second: HomeGapStop,
        kind: HomeGapKind,
        headline: String,
        detail: String,
        bring: [String],
        walkingNote: String?,
        transitNote: String?
    ) -> HomeGapSuggestion {
        HomeGapSuggestion(
            id: "\(first.id)|\(second.id)|\(kind)",
            kind: kind,
            headline: headline,
            detail: detail,
            bringItems: bring,
            walkingNote: walkingNote,
            transitNote: transitNote,
            firstTitle: first.title,
            secondTitle: second.title,
            notifyAt: notifyDate(before: first),
            destinationLatitude: second.latitude,
            destinationLongitude: second.longitude
        )
    }
}

/// Humble packing list from the next event's title and place. Not a shopping AI.
enum WhatToBring {
    static func pack(for stop: HomeGapStop, kind: HomeGapKind, standing: [String]) -> [String] {
        pack(title: stop.title, place: stop.displayPlace, kind: kind, standing: standing, notes: stop.notes)
    }

    static func items(title: String, place: String, notes: String = "") -> [String] {
        let mentioned = itemsMentioned(in: notes)
        if !mentioned.isEmpty { return mentioned }
        let hay = "\(title) \(place)".lowercased()
        if matches(hay, ["barn", "riding", "horse", "equestrian"]) {
            return [ScedraString("Riding stuff — helmet, boots")]
        }
        if matches(hay, ["dentist", "dental", "orthodont"]) {
            return [ScedraString("Dentist — insurance card, referral")]
        }
        if matches(hay, ["doctor", "clinic", "hospital", "medical", "physic"]) {
            return [ScedraString("ID, insurance card")]
        }
        if matches(hay, ["school", "class", "homework", "lecture"]) {
            return [ScedraString("School — laptop, charger")]
        }
        if matches(hay, ["work", "office", "meeting"]) {
            return [ScedraString("Work — laptop, charger")]
        }
        if matches(hay, ["gym", "workout", "yoga", "swim", "fitness"]) {
            return [ScedraString("Gym bag / change of clothes")]
        }
        return [ScedraString("Anything you need for \(readable(title, place: place))")]
    }

    private static func readable(_ title: String, place: String) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = place.trimmingCharacters(in: .whitespacesAndNewlines)
        if place.isEmpty || place.localizedCaseInsensitiveCompare(title) == .orderedSame {
            return title.isEmpty ? ScedraString("the next stop") : title
        }
        if title.isEmpty { return place }
        return ScedraString("\(title) at \(place)")
    }

    private static func matches(_ hay: String, _ needles: [String]) -> Bool {
        needles.contains { hay.contains($0) }
    }

    /// Stay-out / transit / can’t-be-lived: standing reminders plus the next-event guess.
    /// Go-home: standing “always bring” only — she can pick the rest up at home.
    static func pack(
        title: String,
        place: String,
        kind: HomeGapKind,
        standing: [String],
        notes: String = ""
    ) -> [String] {
        let always = standing
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        switch kind {
        case .goHome:
            return unique(always)
        case .stayOut, .takeTransit, .cannotBeLived:
            return unique(always + items(title: title, place: place, notes: notes))
        }
    }

    /// "Please bring your insurance card and photo ID."
    static func itemsMentioned(in notes: String) -> [String] {
        let pattern = #"(?i)\b(?:please\s+)?bring(?:\s+your)?\s+(.+?)(?:\.|\barrive\b|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = notes as NSString
        let full = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: notes, options: [], range: full),
              match.numberOfRanges >= 2
        else { return [] }
        let chunk = nsText.substring(with: match.range(at: 1))
        return chunk
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "&" })
            .flatMap { part -> [String] in
                let text = String(part)
                if let range = text.range(of: #"\band\b"#, options: [.regularExpression, .caseInsensitive]) {
                    return [String(text[..<range.lowerBound]), String(text[range.upperBound...])]
                }
                return [text]
            }
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            }
            .map { item in
                let lower = item.lowercased()
                if lower.contains("photo") && (lower.contains("id") || lower.contains("i.d")) {
                    return "photo ID"
                }
                if lower.contains("insurance") {
                    return "insurance card"
                }
                return item
            }
            .filter { item in
                let key = item.lowercased()
                return !key.isEmpty && !["your", "a", "an", "the", "my"].contains(key)
            }
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items {
            let key = item.lowercased()
            if seen.insert(key).inserted {
                result.append(item)
            }
        }
        return result
    }
}

/// Recovers the stated 6–9 from a notes line when the EventKit block was padded.
enum OfficialAppointmentWindow {
    static func parse(
        _ text: String?,
        around blockStart: Date,
        blockEnd: Date,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date)? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed
            .components(separatedBy: " – ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2 else { return nil }

        guard let startClock = clock(from: parts[0]) else { return nil }
        if let endClock = clock(from: parts[1]) {
            return aligned(
                start: startClock,
                end: endClock,
                blockStart: blockStart,
                blockEnd: blockEnd,
                calendar: calendar
            )
        }
        return nil
    }

    private static func clock(from text: String) -> (hour: Int, minute: Int)? {
        guard case .clock(let hour, let minute, _) = ReviewTimeTyping.parseAppointment(text) else {
            return nil
        }
        return (hour, minute)
    }

    private static func aligned(
        start: (hour: Int, minute: Int),
        end: (hour: Int, minute: Int),
        blockStart: Date,
        blockEnd: Date,
        calendar: Calendar
    ) -> (start: Date, end: Date)? {
        let days = [blockStart, blockEnd].map { calendar.startOfDay(for: $0) }
        var uniqueDays: [Date] = []
        for day in days where !uniqueDays.contains(where: { calendar.isDate($0, inSameDayAs: day) }) {
            uniqueDays.append(day)
        }

        var candidates: [(Date, Date)] = []
        for day in uniqueDays {
            guard let officialStart = calendar.date(bySettingHour: start.hour, minute: start.minute, second: 0, of: day)
            else { continue }
            var officialEnd = calendar.date(bySettingHour: end.hour, minute: end.minute, second: 0, of: day)
                ?? officialStart
            if officialEnd <= officialStart {
                officialEnd = officialEnd.addingTimeInterval(24 * 3600)
            }
            candidates.append((officialStart, officialEnd))
        }
        return candidates.min {
            abs($0.0.timeIntervalSince(blockStart)) < abs($1.0.timeIntervalSince(blockStart))
        }
    }
}
