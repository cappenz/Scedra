import Foundation

/// Places a task into free time using `TaskAvailability`. No travel legs this pass.
protocol TaskAutoScheduler: Sendable {
    func proposedStart(
        for task: ScedraTask,
        busy: [TaskBusyBlock],
        now: Date
    ) -> Date?
}

struct DefaultTaskAutoScheduler: TaskAutoScheduler {
    static let horizonDays = 14
    static let maxDeadlineDays = 30
    static let stepMinutes = 5

    var calendar: Calendar = .current

    func proposedStart(
        for task: ScedraTask,
        busy: [TaskBusyBlock],
        now: Date
    ) -> Date? {
        let duration = task.scheduledDuration
        guard duration > 0 else { return nil }
        let earliest = TaskPlacementLeadTime.earliestStart(from: now)
        if let deadline = task.deadline, deadline <= now || earliest.addingTimeInterval(duration) > deadline {
            return nil
        }

        let latestEnd = task.deadline ?? calendar.date(
            byAdding: .day,
            value: Self.horizonDays,
            to: calendar.startOfDay(for: now)
        ) ?? now.addingTimeInterval(TimeInterval(Self.horizonDays * 86_400))

        for pass in passes(hasDeadline: task.deadline != nil) {
            if let start = firstSlot(
                duration: duration,
                allowedOverlaps: task.allowedOverlaps,
                busy: busy,
                now: earliest,
                latestEnd: latestEnd,
                extendedHours: pass.extended,
                bufferMinutes: pass.buffer
            ) {
                return start
            }
        }
        return nil
    }

    static func dayCount(for task: ScedraTask, now: Date, calendar: Calendar = .current) -> Int {
        if let deadline = task.deadline {
            let start = calendar.startOfDay(for: now)
            let end = calendar.startOfDay(for: deadline)
            let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
            return min(maxDeadlineDays, max(1, days + 1))
        }
        return horizonDays
    }

    private struct Pass {
        var extended: Bool
        var buffer: Int
    }

    /// Prefer in-hours + 10-minute buffer. Shrink to 5 minutes, then slightly extend hours,
    /// only for a deadline. Never drop below 5 — touching without buffer does not fit.
    private func passes(hasDeadline: Bool) -> [Pass] {
        var result = [Pass(extended: false, buffer: TaskPlacementBuffer.minutes)]
        guard hasDeadline else { return result }
        result.append(Pass(extended: false, buffer: TaskPlacementBuffer.reducedMinutes))
        result.append(Pass(extended: true, buffer: TaskPlacementBuffer.minutes))
        result.append(Pass(extended: true, buffer: TaskPlacementBuffer.reducedMinutes))
        return result
    }

    private func firstSlot(
        duration: TimeInterval,
        allowedOverlaps: Set<TaskOverlapKind>,
        busy: [TaskBusyBlock],
        now: Date,
        latestEnd: Date,
        extendedHours: Bool,
        bufferMinutes: Int
    ) -> Date? {
        let cursor0 = stepped(from: now)
        var day = calendar.startOfDay(for: now)
        let lastDay = calendar.startOfDay(for: latestEnd)
        while day <= lastDay {
            if let window = TaskWakingHours.window(on: day, calendar: calendar, extended: extendedHours) {
                var cursor = max(cursor0, window.start)
                let dayLimit = min(window.end, latestEnd)
                while cursor.addingTimeInterval(duration) <= dayLimit {
                    if cursor >= now {
                        let end = cursor.addingTimeInterval(duration)
                        let fit = TaskAvailability.evaluatePlacement(
                            start: cursor,
                            end: end,
                            allowedOverlaps: allowedOverlaps,
                            busy: busy,
                            bufferMinutes: TaskPlacementBuffer.atLeastReduced(bufferMinutes)
                        )
                        if fit != .doesNotFit,
                           TaskAvailability.stackingRestAllows(
                            start: cursor,
                            end: end,
                            allowedOverlaps: allowedOverlaps,
                            busy: busy
                           ) {
                            return cursor
                        }
                    }
                    cursor = cursor.addingTimeInterval(TimeInterval(Self.stepMinutes * 60))
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return nil
    }

    private func stepped(from date: Date) -> Date {
        let interval = TimeInterval(Self.stepMinutes * 60)
        let t = date.timeIntervalSinceReferenceDate
        let stepped = (t / interval).rounded(.up) * interval
        return Date(timeIntervalSinceReferenceDate: stepped)
    }
}

enum TaskPlacement {
    /// Keep a still-valid slot. Otherwise ask the scheduler. Never invent a 3am placeholder.
    static func refreshed(
        _ task: ScedraTask,
        busy: [TaskBusyBlock],
        now: Date,
        scheduler: any TaskAutoScheduler = DefaultTaskAutoScheduler()
    ) -> ScedraTask {
        var next = task
        if next.isCompleted { return next }
        if placementStillValid(next, busy: busy, now: now) { return next }
        if let start = scheduler.proposedStart(for: next, busy: busy, now: now) {
            next.applyPlacement(start: start)
        } else {
            next.clearSchedule()
        }
        return next
    }

    static func placementStillValid(
        _ task: ScedraTask,
        busy: [TaskBusyBlock],
        now: Date
    ) -> Bool {
        guard let start = task.scheduledStart, let end = task.scheduledEnd else { return false }
        if abs(end.timeIntervalSince(start) - task.scheduledDuration) > 1 { return false }
        if let deadline = task.deadline, end > deadline { return false }
        if end < now { return true }

        if TaskAvailability.evaluatePlacement(task: task, start: start, busy: busy) != .doesNotFit {
            // Keep a still-fitting slot, including one she parked after 8pm.
            // Auto-placement is what stays inside waking hours — never silently move her edit.
            return true
        }
        if task.deadline != nil,
           TaskAvailability.evaluatePlacement(
            task: task,
            start: start,
            busy: busy,
            bufferMinutes: TaskPlacementBuffer.reducedMinutes
           ) != .doesNotFit {
            return true
        }
        return false
    }

    /// Manual park. Same exclusive buffer as auto-placement. Does not move neighbors.
    static func manualSlotFits(_ task: ScedraTask, start: Date, busy: [TaskBusyBlock]) -> Bool {
        TaskAvailability.evaluatePlacement(task: task, start: start, busy: busy) != .doesNotFit
    }
}
