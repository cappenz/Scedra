import Foundation

struct CalendarConflict: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
}

enum ConflictLogic {
    /// Timed events overlap when each starts before the other ends. Touching endpoints are fine.
    static func overlaps(start: Date, end: Date, otherStart: Date, otherEnd: Date) -> Bool {
        start < otherEnd && end > otherStart
    }
}

/// How Scedra decides an on-screen row is the same EventKit event.
/// Drive-time padding can move the saved block (5:35–9:25) while the row still
/// reads as the official 6:00–9:00 — a ±60s start match misses that on purpose.
enum EventMatchLogic {
    /// Wider than any realistic drive+buffer so a padded block still finds its row.
    static let paddingSlop: TimeInterval = 4 * 3600

    static func startsAlmostTogether(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) < 60
    }

    /// One interval is the other wrapped in travel (starts earlier, ends later).
    static func isTravelPaddedBlock(
        officialStart: Date,
        officialEnd: Date,
        blockStart: Date,
        blockEnd: Date
    ) -> Bool {
        blockStart <= officialStart.addingTimeInterval(60)
            && blockEnd >= officialEnd.addingTimeInterval(-60)
            && officialStart.timeIntervalSince(blockStart) >= 0
            && officialStart.timeIntervalSince(blockStart) <= paddingSlop
            && blockEnd.timeIntervalSince(officialEnd) >= 0
            && blockEnd.timeIntervalSince(officialEnd) <= paddingSlop
    }

    static func isSameEvent(
        itemTitle: String,
        itemStart: Date,
        itemEnd: Date,
        eventTitle: String,
        eventStart: Date,
        eventEnd: Date
    ) -> Bool {
        guard itemTitle == eventTitle else { return false }
        if startsAlmostTogether(itemStart, eventStart), startsAlmostTogether(itemEnd, eventEnd) {
            return true
        }
        if startsAlmostTogether(itemStart, eventStart) {
            return true
        }
        // Row at official 6–9, EventKit at padded 5:35–9:25 (or the reverse).
        if isTravelPaddedBlock(
            officialStart: itemStart, officialEnd: itemEnd,
            blockStart: eventStart, blockEnd: eventEnd
        ) { return true }
        if isTravelPaddedBlock(
            officialStart: eventStart, officialEnd: eventEnd,
            blockStart: itemStart, blockEnd: itemEnd
        ) { return true }
        return false
    }

    /// Recurring events share one identifier. Only accept the occurrence she tapped.
    static func isShownOccurrence(
        eventStart: Date,
        itemStart: Date,
        isRecurring: Bool,
        calendar: Calendar = .current
    ) -> Bool {
        if !isRecurring { return true }
        if startsAlmostTogether(eventStart, itemStart) { return true }
        if calendar.isDate(eventStart, inSameDayAs: itemStart) { return true }
        // Padded start can fall on the previous calendar day.
        return eventStart < itemStart && itemStart.timeIntervalSince(eventStart) <= paddingSlop
    }
}
