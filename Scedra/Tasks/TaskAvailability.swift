import Foundation

/// Default waking hours. Settings can point at these later — no Settings UI this pass.
enum TaskWakingHours {
    static let startHour = 8
    /// Finish by 8pm when an in-hours slot exists. Not 9pm as a casual default.
    static let endHour = 20
    /// Slightly outside waking hours when a deadline cannot be met in-hours.
    /// Deadline-only — never a reason to casually park at 9pm, and never 3am.
    static let extendedStartHour = 7
    static let extendedEndHour = 21

    static func contains(
        start: Date,
        end: Date,
        calendar: Calendar = .current,
        extended: Bool = false
    ) -> Bool {
        let open = (extended ? extendedStartHour : startHour) * 60
        let close = (extended ? extendedEndHour : endHour) * 60
        return minutes(start, calendar: calendar) >= open
            && minutes(end, calendar: calendar) <= close
            && calendar.isDate(start, inSameDayAs: end)
    }

    static func window(
        on day: Date,
        calendar: Calendar = .current,
        extended: Bool = false
    ) -> (start: Date, end: Date)? {
        let open = extended ? extendedStartHour : startHour
        let close = extended ? extendedEndHour : endHour
        guard
            let start = calendar.date(bySettingHour: open, minute: 0, second: 0, of: day),
            let end = calendar.date(bySettingHour: close, minute: 0, second: 0, of: day)
        else { return nil }
        return (start, end)
    }

    private static func minutes(_ date: Date, calendar: Calendar) -> Int {
        calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }
}

/// Wiggle room between exclusive blocks. Settings can tune later — no Settings UI this pass.
/// Prefer 10 minutes. Never auto-place or manually park with less than 5.
enum TaskPlacementBuffer {
    static let minutes = 10
    static let reducedMinutes = 5

    static var interval: TimeInterval { TimeInterval(minutes * 60) }

    static func atLeastReduced(_ minutes: Int) -> Int {
        max(minutes, reducedMinutes)
    }
}

/// Auto-placement must not chain too many exclusive tasks back-to-back.
/// Calendar appointments still use `TaskPlacementBuffer` only. Overlap-allowed
/// tasks sitting inside driving/walking/waiting/transit are not stacking.
enum TaskPlacementStacking {
    /// After this many consecutive exclusive tasks, require a rest before the next.
    static let consecutiveExclusiveTaskLimit = 2
    /// Or after this much consecutive exclusive task time.
    static let consecutiveExclusiveMinutesLimit = 75
    /// Rest after hitting the stacking cap. Longer than the 10-minute neighbor buffer.
    static let restMinutes = 25

    static var restInterval: TimeInterval { TimeInterval(restMinutes * 60) }
}

/// Do not park a newly saved task in the next few minutes. Auto-placement still
/// writes a later in-hours slot to Apple Calendar when one exists.
enum TaskPlacementLeadTime {
    static let minutes = 30

    static var interval: TimeInterval { TimeInterval(minutes * 60) }

    static func earliestStart(from now: Date) -> Date {
        now.addingTimeInterval(interval)
    }
}

/// A timed busy block the fit-check can reason about. Views map `TodayItem` here;
/// they do not do interval math themselves.
struct TaskBusyBlock: Equatable, Sendable {
    var start: Date
    var end: Date
    var kind: TaskOverlapKind
    var title: String
    /// Any other Scedra task. Never a compatible overlap host — two tasks cannot share a slot,
    /// even when both list driving/walking chips. Calendar events stay `false`.
    var isTaskPlacement: Bool
    /// Exclusive Scedra tasks only. Calendar appointments stay `false` so stacking rest
    /// does not apply to class / meetings — those keep the 10-minute buffer.
    var isExclusiveTaskPlacement: Bool

    init(
        start: Date,
        end: Date,
        kind: TaskOverlapKind,
        title: String = "",
        isExclusiveTaskPlacement: Bool = false,
        isTaskPlacement: Bool = false
    ) {
        self.start = start
        self.end = end
        self.kind = kind
        self.title = title
        self.isTaskPlacement = isTaskPlacement || isExclusiveTaskPlacement
        self.isExclusiveTaskPlacement = isExclusiveTaskPlacement
    }

    init(_ item: TodayItem) {
        start = item.start
        end = item.end
        kind = TaskOverlapKind.inferred(fromTitle: item.title)
        title = item.title
        isTaskPlacement = false
        isExclusiveTaskPlacement = false
    }

    func overlaps(start: Date, end: Date) -> Bool {
        self.start < end && start < self.end
    }
}

/// Result of asking whether a task window can sit on the calendar as-is.
enum TaskFit: Equatable, Sendable {
    /// No busy block overlaps the window.
    case fits
    /// Every overlapping block is a kind this task is allowed to share.
    case overlapOK
    /// At least one overlapping block cannot host this task.
    case doesNotFit
}

/// Pure fit-check. No Maps, no auto-placement.
enum TaskAvailability {
    static func evaluate(
        start: Date,
        durationMinutes: Int,
        allowedOverlaps: Set<TaskOverlapKind>,
        busy: [TaskBusyBlock]
    ) -> TaskFit {
        let minutes = max(durationMinutes, 0)
        guard minutes > 0 else { return .doesNotFit }
        let end = start.addingTimeInterval(TimeInterval(minutes * 60))
        return evaluate(start: start, end: end, allowedOverlaps: allowedOverlaps, busy: busy)
    }

    static func evaluate(
        start: Date,
        end: Date,
        allowedOverlaps: Set<TaskOverlapKind>,
        busy: [TaskBusyBlock]
    ) -> TaskFit {
        evaluatePlacement(
            start: start,
            end: end,
            allowedOverlaps: allowedOverlaps,
            busy: busy,
            bufferMinutes: 0
        )
    }

    static func evaluate(task: ScedraTask, start: Date, busy: [TaskBusyBlock]) -> TaskFit {
        evaluate(
            start: start,
            durationMinutes: task.estimatedDurationMinutes,
            allowedOverlaps: task.allowedOverlaps,
            busy: busy
        )
    }

    /// Exclusive neighbors need wiggle room. Allowed overlaps (drive / walk / wait / transit)
    /// may share time with a calendar host of that kind — never with another task, and
    /// never with class / meeting / focused work. Touching without buffer does not fit.
    static func evaluatePlacement(
        start: Date,
        end: Date,
        allowedOverlaps: Set<TaskOverlapKind>,
        busy: [TaskBusyBlock],
        bufferMinutes: Int = TaskPlacementBuffer.minutes
    ) -> TaskFit {
        guard end > start else { return .doesNotFit }
        let buffer = TimeInterval(max(bufferMinutes, 0) * 60)
        var sawCompatibleOverlap = false
        for block in busy {
            let canShare = !block.isTaskPlacement
                && TaskOverlap.canOverlap(allowed: allowedOverlaps, with: block.kind)
            if block.overlaps(start: start, end: end) {
                if canShare {
                    sawCompatibleOverlap = true
                } else {
                    return .doesNotFit
                }
                continue
            }
            if canShare { continue }
            if buffer > 0 {
                if block.end <= start, start < block.end.addingTimeInterval(buffer) {
                    return .doesNotFit
                }
                if end <= block.start, block.start < end.addingTimeInterval(buffer) {
                    return .doesNotFit
                }
            }
        }
        return sawCompatibleOverlap ? .overlapOK : .fits
    }

    /// Exclusive auto-placement only. A call during a drive is not stacking.
    static func stackingRestAllows(
        start: Date,
        end: Date,
        allowedOverlaps: Set<TaskOverlapKind>,
        busy: [TaskBusyBlock]
    ) -> Bool {
        let sharesHost = busy.contains { block in
            block.overlaps(start: start, end: end)
                && TaskOverlap.canOverlap(allowed: allowedOverlaps, with: block.kind)
        }
        if sharesHost { return true }
        guard allowedOverlaps.isEmpty else { return true }

        let chain = consecutiveExclusiveTaskChain(endingBefore: start, busy: busy)
        guard !chain.isEmpty else { return true }
        let minutes = chain.reduce(0) { partial, block in
            partial + Int(block.end.timeIntervalSince(block.start) / 60)
        }
        let needsRest = chain.count >= TaskPlacementStacking.consecutiveExclusiveTaskLimit
            || minutes >= TaskPlacementStacking.consecutiveExclusiveMinutesLimit
        guard needsRest, let lastEnd = chain.map(\.end).max() else { return true }
        return start >= lastEnd.addingTimeInterval(TaskPlacementStacking.restInterval)
    }

    /// Exclusive tasks packed with only the neighbor buffer, immediately before `start`.
    static func consecutiveExclusiveTaskChain(
        endingBefore start: Date,
        busy: [TaskBusyBlock]
    ) -> [TaskBusyBlock] {
        let linkGap = TaskPlacementBuffer.interval
        let prior = busy
            .filter(\.isExclusiveTaskPlacement)
            .filter { $0.end <= start.addingTimeInterval(0.5) }
            .sorted { $0.start < $1.start }
        guard let last = prior.last else { return [] }

        var chain = [last]
        for block in prior.dropLast().reversed() {
            let next = chain[0]
            if next.start.timeIntervalSince(block.end) <= linkGap + 0.5 {
                chain.insert(block, at: 0)
            } else {
                break
            }
        }
        return chain
    }

    static func evaluatePlacement(
        task: ScedraTask,
        start: Date,
        busy: [TaskBusyBlock],
        bufferMinutes: Int = TaskPlacementBuffer.minutes
    ) -> TaskFit {
        let end = start.addingTimeInterval(task.scheduledDuration)
        return evaluatePlacement(
            start: start,
            end: end,
            allowedOverlaps: task.allowedOverlaps,
            busy: busy,
            bufferMinutes: bufferMinutes
        )
    }

    /// Timed calendar items only. All-day rows are presence, not a clock block.
    static func busyBlocks(from items: [TodayItem]) -> [TaskBusyBlock] {
        items.filter { !$0.isAllDay }.map(TaskBusyBlock.init)
    }
}
