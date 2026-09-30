import Foundation

/// Persistence for tasks. JSON/`UserDefaults` today; SwiftData can adopt this later
/// without rewriting the tab or the fit-check.
protocol TaskStore: AnyObject {
    func load() -> [ScedraTask]
    func save(_ tasks: [ScedraTask])
}

final class UserDefaultsTaskStore: TaskStore {
    static let key = "scedra.tasks"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [ScedraTask] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? Self.decoder.decode([ScedraTask].self, from: data)) ?? []
    }

    func save(_ tasks: [ScedraTask]) {
        guard let data = try? Self.encoder.encode(tasks) else { return }
        defaults.set(data, forKey: Self.key)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

final class MemoryTaskStore: TaskStore {
    private var tasks: [ScedraTask]

    init(tasks: [ScedraTask] = []) {
        self.tasks = tasks
    }

    func load() -> [ScedraTask] {
        tasks
    }

    func save(_ tasks: [ScedraTask]) {
        self.tasks = tasks
    }
}

@MainActor
@Observable
final class TaskRepository {
    private let store: any TaskStore
    private(set) var tasks: [ScedraTask]

    init(store: any TaskStore = UserDefaultsTaskStore()) {
        self.store = store
        self.tasks = store.load()
        reconcile()
    }

    var openTasks: [ScedraTask] {
        tasks
            .filter { !$0.isCompleted }
            .sorted(by: Self.openOrder)
    }

    var completedTasks: [ScedraTask] {
        completedTasks(at: Date())
    }

    func completedTasks(at now: Date) -> [ScedraTask] {
        tasks
            .filter(\.isCompleted)
            .filter { $0.shouldRetainCompleted(at: now) }
            .sorted { ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) }
    }

    func upsert(_ task: ScedraTask) {
        var next = task
        next.title = next.title.trimmingCharacters(in: .whitespacesAndNewlines)
        next.notes = next.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        next.location = next.location.trimmingCharacters(in: .whitespacesAndNewlines)
        next.category = next.category.trimmingCharacters(in: .whitespacesAndNewlines)
        next.updatedAt = Date()
        if next.isCompleted {
            next.completedAt = next.completedAt ?? Date()
        } else {
            next.completedAt = nil
        }
        if let index = tasks.firstIndex(where: { $0.id == next.id }) {
            tasks[index] = next
        } else {
            tasks.append(next)
        }
        persist()
    }

    /// Places an open task, writes the EventKit block, then persists.
    /// `honorSchedule` keeps times she picked in the editor — no auto-move, no 3am invent.
    func placeAndSave(
        _ task: ScedraTask,
        writer: any TaskCalendarWriter,
        busy: [TaskBusyBlock],
        now: Date = Date(),
        scheduler: any TaskAutoScheduler = DefaultTaskAutoScheduler(),
        honorSchedule: Bool = false
    ) async {
        var next = task
        if honorSchedule, next.isPlaced, let start = next.scheduledStart {
            if TaskPlacement.manualSlotFits(next, start: start, busy: busy) {
                next.applyPlacement(start: start)
            } else if let existing = tasks.first(where: { $0.id == next.id }),
                      existing.isPlaced,
                      let previousStart = existing.scheduledStart,
                      TaskPlacement.manualSlotFits(existing, start: previousStart, busy: busy) {
                next.scheduledStart = existing.scheduledStart
                next.scheduledEnd = existing.scheduledEnd
            } else {
                next.clearPlacementTimes()
            }
        } else {
            next = TaskPlacement.refreshed(task, busy: busy, now: now, scheduler: scheduler)
        }
        next.applyAutomaticCompletion(at: now)
        let previousEventID = next.calendarEventIdentifier
        if next.isCompleted {
            upsert(next)
            reconcile(now: now)
            return
        }

        if !next.isPlaced {
            next.calendarEventIdentifier = nil
        }
        upsert(next)

        if let start = next.scheduledStart, let end = next.scheduledEnd {
            do {
                let identifier = try await writer.upsertTaskEvent(
                    existingIdentifier: previousEventID,
                    title: next.title,
                    start: start,
                    end: end,
                    location: next.location,
                    notes: next.notes
                )
                if let index = tasks.firstIndex(where: { $0.id == next.id }) {
                    tasks[index].calendarEventIdentifier = identifier
                    persist()
                }
            } catch {
                // Keep the local slot. Identifier stays as the previous EventKit id if we had one.
            }
        } else if let previousEventID, !previousEventID.isEmpty {
            try? await writer.deleteTaskEvent(identifier: previousEventID)
        }
        reconcile(now: now)
    }

    func placeAndSave(
        _ task: ScedraTask,
        calendar: CalendarStore,
        now: Date = Date(),
        scheduler: any TaskAutoScheduler = DefaultTaskAutoScheduler(),
        honorSchedule: Bool = false
    ) async {
        await placeAndSave(
            task,
            writer: calendar,
            busy: occupancy(excluding: task, calendar: calendar, now: now),
            now: now,
            scheduler: scheduler,
            honorSchedule: honorSchedule
        )
    }

    /// She picked a day and clock. Updates the existing EventKit event when one exists.
    func rescheduleAndSave(
        _ task: ScedraTask,
        start: Date?,
        writer: any TaskCalendarWriter,
        busy: [TaskBusyBlock],
        now: Date = Date(),
        scheduler: any TaskAutoScheduler = DefaultTaskAutoScheduler()
    ) async {
        var next = task
        if let start {
            next.applyPlacement(start: start)
            await placeAndSave(
                next,
                writer: writer,
                busy: busy,
                now: now,
                scheduler: scheduler,
                honorSchedule: true
            )
        } else {
            next.clearPlacementTimes()
            await placeAndSave(next, writer: writer, busy: busy, now: now, scheduler: scheduler)
        }
    }

    func delete(_ task: ScedraTask) {
        tasks.removeAll { $0.id == task.id }
        persist()
    }

    func delete(_ task: ScedraTask, from writer: any TaskCalendarWriter) async {
        if let identifier = task.calendarEventIdentifier, !identifier.isEmpty {
            try? await writer.deleteTaskEvent(identifier: identifier)
        }
        delete(task)
    }

    func occupancy(
        excluding task: ScedraTask,
        calendar: CalendarStore,
        now: Date = Date()
    ) -> [TaskBusyBlock] {
        busyBlocks(from: calendar, excluding: task, now: now)
    }

    private func busyBlocks(
        from calendar: CalendarStore,
        excluding task: ScedraTask,
        now: Date
    ) -> [TaskBusyBlock] {
        let days = DefaultTaskAutoScheduler.dayCount(for: task, now: now)
        let day0 = Calendar.current.startOfDay(for: now)
        var items: [TodayItem] = []
        for offset in 0..<days {
            guard let day = Calendar.current.date(byAdding: .day, value: offset, to: day0) else { continue }
            items.append(contentsOf: calendar.events(on: day))
        }
        if let identifier = task.calendarEventIdentifier, !identifier.isEmpty {
            items.removeAll { $0.id == identifier }
        }
        var blocks = TaskAvailability.busyBlocks(from: items)
        for other in tasks where other.id != task.id && !other.isCompleted {
            if let start = other.scheduledStart, let end = other.scheduledEnd {
                blocks.append(
                    TaskBusyBlock(
                        start: start,
                        end: end,
                        kind: .focusedWork,
                        title: other.title,
                        isExclusiveTaskPlacement: other.allowedOverlaps.isEmpty,
                        isTaskPlacement: true
                    )
                )
            }
        }
        return blocks
    }

    func setCompleted(_ task: ScedraTask, isCompleted: Bool, at now: Date = Date()) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].setCompleted(isCompleted, at: now)
        persist()
        reconcile(now: now)
    }

    func reload() {
        tasks = store.load()
        reconcile()
    }

    /// Auto-completes elapsed placements and drops completed rows past the retain window.
    func reconcile(now: Date = Date()) {
        var next = tasks
        var changed = false
        for index in next.indices {
            if next[index].applyAutomaticCompletion(at: now) {
                changed = true
            }
        }
        let kept = next.filter { $0.shouldRetainCompleted(at: now) }
        if kept.count != next.count {
            changed = true
            next = kept
        }
        guard changed else { return }
        tasks = next
        persist()
    }

    private func persist() {
        store.save(tasks)
    }

    private static func openOrder(_ lhs: ScedraTask, _ rhs: ScedraTask) -> Bool {
        switch (lhs.deadline, rhs.deadline) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            if lhs.hasScheduledTimePassed != rhs.hasScheduledTimePassed {
                return lhs.hasScheduledTimePassed
            }
            return lhs.createdAt < rhs.createdAt
        }
    }
}
