import Foundation

enum DriveChainKind: String, Equatable {
    /// Home → first (or next) stop.
    case fromHome
    /// Direct A → B when there is not enough time at home.
    case between
    /// Away stop → Home.
    case toHome
}

struct DriveChainStop: Equatable {
    var id: String
    var title: String
    var place: String
    var start: Date
    var end: Date
    var usesHome: Bool
    /// New Scedra “part of the event” padding already covers inbound.
    var padsInbound: Bool = false
}

struct DriveChainEstimates: Equatable {
    /// Home → stop id.
    var fromHome: [String: Int] = [:]
    /// Stop id → Home.
    var toHome: [String: Int] = [:]
    /// `"fromID|toID"` → minutes.
    var between: [String: Int] = [:]

    func betweenMinutes(from: String, to: String) -> Int? {
        between["\(from)|\(to)"]
    }

    mutating func fillMissing(from other: DriveChainEstimates) {
        for (key, minutes) in other.fromHome where fromHome[key] == nil && minutes > 0 {
            fromHome[key] = minutes
        }
        for (key, minutes) in other.toHome where toHome[key] == nil && minutes > 0 {
            toHome[key] = minutes
        }
        for (key, minutes) in other.between where between[key] == nil && minutes > 0 {
            between[key] = minutes
        }
    }
}

struct DriveChainLeg: Equatable {
    var kind: DriveChainKind
    var fromID: String?
    var toID: String?
    var fromTitle: String
    var toTitle: String
    var start: Date
    var end: Date
    var location: String
    var minutes: Int
    var existingIdentifier: String? = nil

    var chainKey: String {
        DriveChainLogic.chainKey(from: fromID, to: toID)
    }

    var driveLeg: DriveLeg {
        switch kind {
        case .fromHome: .inbound
        case .toHome: .onward
        case .between: .between
        }
    }

    var title: String {
        DriveChainLogic.title(for: self)
    }
}

struct DriveChainPlan: Equatable {
    var legs: [DriveChainLeg]
    var removeIdentifiers: [String]
}

/// Whole-day drive legs. Consecutive away stops share one chain so a tight
/// Boba → Target gap is one "Drive to Target from Boba" — not Drive home plus
/// a second Drive to Target from Home.
enum DriveChainLogic {
    static let homeSentinel = "home"

    static func chainKey(from: String?, to: String?) -> String {
        "from:\(normalizedID(from))|to:\(normalizedID(to))"
    }

    static func isAway(_ stop: DriveChainStop) -> Bool {
        if stop.usesHome || HomeGapLogic.looksLikeHome(stop.place) { return false }
        return !stop.place.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func title(for leg: DriveChainLeg, mode: TravelMode = .drive) -> String {
        switch leg.kind {
        case .fromHome:
            return DriveTimeLogic.driveEventTitle(place: leg.location, appointmentTitle: leg.toTitle, mode: mode)
        case .toHome:
            return DriveTimeLogic.onwardEventTitle(from: leg.fromTitle, goingHome: true, mode: mode)
        case .between:
            return DriveTimeLogic.betweenEventTitle(from: leg.fromTitle, to: leg.toTitle, mode: mode)
        }
    }

    /// Full Maps duration, never clipped to the free gap. Fits after A: leave at
    /// `firstEnd`. Tight, zero, or negative gap: center on the A.end–B.start seam
    /// so leftover minutes cut into both appointments equally. Official A/B times
    /// stay put — only the drive sibling overlaps.
    static func connectingDriveWindow(
        firstEnd: Date,
        secondStart: Date,
        minutes: Int
    ) -> (start: Date, end: Date)? {
        guard minutes > 0 else { return nil }
        let duration = TimeInterval(minutes * 60)
        let gap = secondStart.timeIntervalSince(firstEnd)
        if gap >= duration {
            return (firstEnd, firstEnd.addingTimeInterval(duration))
        }
        let seam = firstEnd.addingTimeInterval(gap / 2)
        let start = seam.addingTimeInterval(-duration / 2)
        let end = start.addingTimeInterval(duration)
        guard end > start else { return nil }
        return (start, end)
    }

    static func plan(
        stops: [DriveChainStop],
        estimates: DriveChainEstimates,
        minHomeMinutes: Int,
        leavingHomeBuffer: Int = 0,
        existingIdentifiers: [String: String] = [:],
        staleIdentifiers: [String] = [],
        homeLabel: String = ScedraString("Home"),
        mode: TravelMode = .drive
    ) -> DriveChainPlan {
        let away = stops.filter(isAway).sorted { $0.start < $1.start }
        var legs: [DriveChainLeg] = []
        let buffer = max(leavingHomeBuffer, 0)
        let homeName = {
            let trimmed = homeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? ScedraString("Home") : trimmed
        }()

        func append(_ draft: DriveChainLeg) {
            guard draft.end > draft.start else { return }
            // Never drop a needed drive because it overlaps an appointment.
            // Back-to-back A→B straddles the seam; first-from-Home and last
            // Drive home still explain TO and FROM even when they overlap.
            var next = draft
            next.existingIdentifier = existingIdentifiers[draft.chainKey]
            legs.append(next)
        }

        if let first = away.first, !first.padsInbound {
            if let minutes = estimates.fromHome[first.id], minutes > 0 {
                let duration = minutes + buffer
                let end = first.start
                let start = end.addingTimeInterval(TimeInterval(-duration * 60))
                append(
                    DriveChainLeg(
                        kind: .fromHome,
                        fromID: nil,
                        toID: first.id,
                        fromTitle: homeName,
                        toTitle: first.title,
                        start: start,
                        end: end,
                        location: first.place,
                        minutes: duration
                    )
                )
            }
        }

        if away.count >= 2 {
            for index in 0..<(away.count - 1) {
                let first = away[index]
                let second = away[index + 1]
                if DriveTimeLogic.isSamePlace(first.place, second.place) { continue }

                let gap = Int(second.start.timeIntervalSince(first.end) / 60)
                let aToHome = estimates.toHome[first.id]
                let homeToB = estimates.fromHome[second.id]
                let aToB = estimates.betweenMinutes(from: first.id, to: second.id)
                // Missing Home minutes must not count as "fits" — stay on A→B.
                let goHome = HomeGapLogic.canGoHome(
                    gap: gap,
                    aToHome: aToHome,
                    homeToB: homeToB,
                    minHomeMinutes: minHomeMinutes,
                    buffer: buffer
                )

                if goHome {
                    if let aToHome, aToHome > 0 {
                        let start = first.end
                        let end = start.addingTimeInterval(TimeInterval(aToHome * 60))
                        append(
                            DriveChainLeg(
                                kind: .toHome,
                                fromID: first.id,
                                toID: nil,
                                fromTitle: first.title,
                                toTitle: homeName,
                                start: start,
                                end: end,
                                location: homeName,
                                minutes: aToHome
                            )
                        )
                    }
                    if let homeToB, homeToB > 0, !second.padsInbound {
                        let duration = homeToB + buffer
                        let end = second.start
                        let start = end.addingTimeInterval(TimeInterval(-duration * 60))
                        append(
                            DriveChainLeg(
                                kind: .fromHome,
                                fromID: nil,
                                toID: second.id,
                                fromTitle: homeName,
                                toTitle: second.title,
                                start: start,
                                end: end,
                                location: second.place,
                                minutes: duration
                            )
                        )
                    }
                } else if let aToB, aToB > 0 {
                    guard let window = connectingDriveWindow(
                        firstEnd: first.end,
                        secondStart: second.start,
                        minutes: aToB
                    ) else { continue }
                    append(
                        DriveChainLeg(
                            kind: .between,
                            fromID: first.id,
                            toID: second.id,
                            fromTitle: first.title,
                            toTitle: second.title,
                            start: window.start,
                            end: window.end,
                            location: second.place,
                            minutes: aToB
                        )
                    )
                }
            }
        }

        if let last = away.last {
            let alreadyHome = legs.contains { $0.kind == .toHome && $0.fromID == last.id }
            if !alreadyHome, let minutes = estimates.toHome[last.id], minutes > 0 {
                let start = last.end
                let end = start.addingTimeInterval(TimeInterval(minutes * 60))
                append(
                    DriveChainLeg(
                        kind: .toHome,
                        fromID: last.id,
                        toID: nil,
                        fromTitle: last.title,
                        toTitle: homeName,
                        start: start,
                        end: end,
                        location: homeName,
                        minutes: minutes
                    )
                )
            }
        }

        let used = Set(legs.compactMap(\.existingIdentifier))
        let usedKeys = Set(legs.map(\.chainKey))
        let awayIDs = Set(away.map(\.id))
        let remove = staleIdentifiers.filter { id in
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || used.contains(trimmed) { return false }
            if let key = existingIdentifiers.first(where: { $0.value == trimmed })?.key {
                if isPlausibleChainKey(key, awayIDs: awayIDs),
                   !usedKeys.contains(key),
                   !hasReplacementEstimate(key, estimates: estimates),
                   !pairAlreadyPlanned(key, usedKeys: usedKeys) {
                    return false
                }
            }
            return true
        }
        return DriveChainPlan(legs: legs, removeIdentifiers: remove)
    }

    /// `from:id|to:id` still belongs to today's away stops (or Home).
    static func isPlausibleChainKey(_ key: String, awayIDs: Set<String>) -> Bool {
        guard let ends = chainKeyEndpoints(key) else { return false }
        let fromOK = ends.from == homeSentinel || awayIDs.contains(ends.from)
        let toOK = ends.to == homeSentinel || awayIDs.contains(ends.to)
        return fromOK && toOK
    }

    /// True when Maps (or a seeded sibling duration) can replace this leg.
    static func hasReplacementEstimate(_ key: String, estimates: DriveChainEstimates) -> Bool {
        guard let ends = chainKeyEndpoints(key) else { return false }
        if ends.from == homeSentinel {
            return (estimates.fromHome[ends.to] ?? 0) > 0
        }
        if ends.to == homeSentinel {
            return (estimates.toHome[ends.from] ?? 0) > 0
        }
        if let between = estimates.betweenMinutes(from: ends.from, to: ends.to), between > 0 {
            return true
        }
        let home = estimates.toHome[ends.from] ?? 0
        let back = estimates.fromHome[ends.to] ?? 0
        return home > 0 && back > 0
    }

    /// A successful A→B or Home leg for the same pair means this unused sibling is stale.
    static func pairAlreadyPlanned(_ key: String, usedKeys: Set<String>) -> Bool {
        guard let ends = chainKeyEndpoints(key) else { return false }
        if ends.from == homeSentinel {
            return usedKeys.contains { planned in
                planned.hasSuffix("|to:\(ends.to)") && planned != chainKey(from: nil, to: ends.to)
            }
        }
        if ends.to == homeSentinel {
            return usedKeys.contains { planned in
                planned.hasPrefix("from:\(ends.from)|") && planned != chainKey(from: ends.from, to: nil)
            }
        }
        return usedKeys.contains(chainKey(from: ends.from, to: nil))
            || usedKeys.contains(chainKey(from: nil, to: ends.to))
    }

    static func chainKeyEndpoints(_ key: String) -> (from: String, to: String)? {
        guard key.hasPrefix("from:"), let separator = key.range(of: "|to:") else { return nil }
        let from = String(key[key.index(key.startIndex, offsetBy: 5)..<separator.lowerBound])
        let to = String(key[separator.upperBound...])
        if from.isEmpty || to.isEmpty { return nil }
        return (from, to)
    }

    private static func normalizedID(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? homeSentinel : trimmed
    }
}
