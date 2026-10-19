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
    /// Fired after `placeAndSave` persists. Onboarding observes this only.
    var placedTaskHandler: (() -> Void)?

    init(store: any TaskStore = UserDefaultsTaskStore()) {
        self.store = store
        self.tasks = store.load()
        reconcile()
    }

    var openTasks: [ScedraTask] {
        tasks
            .filter { !$0.isCompleted }
            .sorted(by: TaskPriority.compare)
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
    /// Important tasks may bump a less-important Scedra task; calendar events never move.
    func placeAndSave(
        _ task: ScedraTask,
        writer: any TaskCalendarWriter,
        busy: [TaskBusyBlock],
        now: Date = Date(),
        scheduler: any TaskAutoScheduler = DefaultTaskAutoScheduler(),
        honorSchedule: Bool = false
    ) async {
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
        }
        next.applyAutomaticCompletion(at: now)

        var working = tasks
        if let index = working.firstIndex(where: { $0.id == next.id }) {
            working[index] = next
        } else {
            working.append(next)
        }

        if next.isCompleted {
            tasks = working
            persist()
            placedTaskHandler?()
            await pruneCompleted(writer: writer, now: now)
            return
        }

        let previousIDs = Dictionary(
            uniqueKeysWithValues: working.map { ($0.id, $0.calendarEventIdentifier) }
        )
        let calendarBusy = busy.filter { !$0.isTaskPlacement }
        let open = working.filter { !$0.isCompleted }
        let scheduled = TaskPlacement.schedulePrioritized(
            open,
            calendarBusy: calendarBusy,
            now: now,
            scheduler: scheduler,
            honoring: honorSchedule ? next.id : nil
        )
        var byID = Dictionary(uniqueKeysWithValues: scheduled.map { ($0.id, $0) })
        working = working.map { byID[$0.id] ?? $0 }
        tasks = working
        persist()
        await syncPlacedEvents(scheduled, previousIDs: previousIDs, writer: writer)
        await pruneCompleted(writer: writer, now: now)
        placedTaskHandler?()
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

    /// The EventKit event for this task is gone (Calendar UI or Apple Calendar).
    /// Drop the matching open or completed ScedraTask — never a regular appointment.
    func removeMatchingCalendarEvents(_ identifiers: [String]) {
        let ids = Set(
            identifiers
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard !ids.isEmpty else { return }
        let before = tasks.count
        tasks.removeAll { task in
            let stored = task.calendarEventIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !stored.isEmpty && ids.contains(stored)
        }
        guard tasks.count != before else { return }
        persist()
    }

    /// Apple Calendar deletions that never went through Scedra's delete UI.
    /// `eventExists` returning nil means we cannot tell — leave the task.
    func removeTasksMissingFromCalendar(eventExists: (String) -> Bool?) {
        let vanished = tasks.compactMap { task -> String? in
            let stored = task.calendarEventIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !stored.isEmpty else { return nil }
            return eventExists(stored) == false ? stored : nil
        }
        removeMatchingCalendarEvents(vanished)
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
        return TaskAvailability.occupancy(
            calendarItems: calendar.occupancyItems(from: now, dayCount: days),
            tasks: tasks,
            excluding: task
        )
    }

    func setCompleted(_ task: ScedraTask, isCompleted: Bool, at now: Date = Date()) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].setCompleted(isCompleted, at: now)
        persist()
        _ = reconcile(now: now)
    }

    func setCompleted(
        _ task: ScedraTask,
        isCompleted: Bool,
        from writer: any TaskCalendarWriter,
        at now: Date = Date()
    ) async {
        setCompleted(task, isCompleted: isCompleted, at: now)
        await pruneCompleted(writer: writer, now: now)
    }

    func reload() {
        tasks = store.load()
        _ = reconcile()
    }

    /// Auto-completes elapsed placements and drops completed rows after the 24h window.
    @discardableResult
    func reconcile(now: Date = Date()) -> [String] {
        var next = tasks
        var changed = false
        for index in next.indices {
            if next[index].applyAutomaticCompletion(at: now) {
                changed = true
            }
        }
        var prunedIDs: [String] = []
        let kept = next.filter { task in
            if task.shouldRetainCompleted(at: now) { return true }
            if let id = task.calendarEventIdentifier, !id.isEmpty {
                prunedIDs.append(id)
            }
            changed = true
            return false
        }
        guard changed else { return prunedIDs }
        tasks = kept
        persist()
        return prunedIDs
    }

    func pruneCompleted(writer: any TaskCalendarWriter, now: Date = Date()) async {
        let ids = reconcile(now: now)
        for id in ids {
            try? await writer.deleteTaskEvent(identifier: id)
        }
    }

    /// Re-runs priority placement: important / closer deadline take the earlier slot,
    /// bumped Scedra tasks move later, Apple Calendar appointments stay put.
    func reconcilePlacements(
        writer: any TaskCalendarWriter,
        busy: [TaskBusyBlock],
        now: Date = Date(),
        scheduler: any TaskAutoScheduler = DefaultTaskAutoScheduler()
    ) async {
        _ = reconcile(now: now)
        let open = tasks.filter { !$0.isCompleted }
        guard !open.isEmpty else { return }
        let previousIDs = Dictionary(
            uniqueKeysWithValues: tasks.map { ($0.id, $0.calendarEventIdentifier) }
        )
        let calendarBusy = busy.filter { !$0.isTaskPlacement }
        let scheduled = TaskPlacement.schedulePrioritized(
            open,
            calendarBusy: calendarBusy,
            now: now,
            scheduler: scheduler
        )
        var byID = Dictionary(uniqueKeysWithValues: scheduled.map { ($0.id, $0) })
        tasks = tasks.map { byID[$0.id] ?? $0 }
        persist()
        await syncPlacedEvents(scheduled, previousIDs: previousIDs, writer: writer)
    }

    func reconcilePlacements(
        calendar: CalendarStore,
        now: Date = Date(),
        scheduler: any TaskAutoScheduler = DefaultTaskAutoScheduler()
    ) async {
        await reconcilePlacements(
            writer: calendar,
            busy: calendarOccupancy(from: calendar, now: now),
            now: now,
            scheduler: scheduler
        )
    }

    private func calendarOccupancy(from calendar: CalendarStore, now: Date) -> [TaskBusyBlock] {
        TaskAvailability.occupancy(
            calendarItems: calendar.occupancyItems(
                from: now,
                dayCount: DefaultTaskAutoScheduler.horizonDays
            ),
            tasks: tasks
        )
    }

    private func syncPlacedEvents(
        _ scheduled: [ScedraTask],
        previousIDs: [UUID: String?],
        writer: any TaskCalendarWriter
    ) async {
        for placed in scheduled {
            let previousEventID = placed.calendarEventIdentifier ?? previousIDs[placed.id] ?? nil
            if let start = placed.scheduledStart, let end = placed.scheduledEnd {
                do {
                    let identifier = try await writer.upsertTaskEvent(
                        existingIdentifier: previousEventID,
                        title: placed.title,
                        start: start,
                        end: end,
                        location: placed.location,
                        notes: placed.notes
                    )
                    if let index = tasks.firstIndex(where: { $0.id == placed.id }) {
                        tasks[index].calendarEventIdentifier = identifier
                    }
                } catch {
                    // Keep the local slot. Identifier stays as the previous EventKit id if we had one.
                }
            } else if let previousEventID, !previousEventID.isEmpty {
                try? await writer.deleteTaskEvent(identifier: previousEventID)
                if let index = tasks.firstIndex(where: { $0.id == placed.id }) {
                    tasks[index].calendarEventIdentifier = nil
                }
            }
        }
        persist()
    }

    private func persist() {
        store.save(tasks)
    }
}
