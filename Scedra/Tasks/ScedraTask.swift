import Foundation

/// Progress of a to-do. A past `scheduledEnd` is written to `isCompleted` by the store.
enum TaskProgressStatus: String, Equatable, Sendable {
    case open
    case completed
    case scheduledTimePassed
}

/// How long a completed task stays in the Completed list. Settings can tune later.
enum TaskRetention {
    static let completedVisibleFor: TimeInterval = 24 * 60 * 60
}

/// Something to finish. Calendar events occupy time; a task is placed in free time.
struct ScedraTask: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var title: String
    var notes: String
    var estimatedDurationMinutes: Int
    var deadline: Date?
    var isCompleted: Bool
    /// When it was checked off or auto-completed. Starts the Completed retain window.
    var completedAt: Date?
    var location: String
    /// Travel legs use the existing `TravelEstimator` / `PlaceResolver` later — not a second Maps stack.
    var requiresTravel: Bool
    var allowedOverlaps: Set<TaskOverlapKind>
    var category: String
    /// Internal placement. Not a user-facing start-time picker.
    var scheduledStart: Date?
    var scheduledEnd: Date?
    /// EventKit event this placement wrote. Empty when the task is not on the calendar.
    var calendarEventIdentifier: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        estimatedDurationMinutes: Int = 30,
        deadline: Date? = nil,
        isCompleted: Bool = false,
        completedAt: Date? = nil,
        location: String = "",
        requiresTravel: Bool = false,
        allowedOverlaps: Set<TaskOverlapKind> = [],
        category: String = "",
        scheduledStart: Date? = nil,
        scheduledEnd: Date? = nil,
        calendarEventIdentifier: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.estimatedDurationMinutes = max(estimatedDurationMinutes, 1)
        self.deadline = deadline
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.location = location
        self.requiresTravel = requiresTravel
        self.allowedOverlaps = allowedOverlaps
        self.category = category
        self.scheduledStart = scheduledStart
        self.scheduledEnd = scheduledEnd
        self.calendarEventIdentifier = calendarEventIdentifier
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func progressStatus(at now: Date = Date()) -> TaskProgressStatus {
        if isCompleted { return .completed }
        if let scheduledEnd, scheduledEnd < now { return .scheduledTimePassed }
        return .open
    }

    var hasScheduledTimePassed: Bool {
        progressStatus() == .scheduledTimePassed
    }

    var isPlaced: Bool {
        scheduledStart != nil && scheduledEnd != nil
    }

    var scheduledDuration: TimeInterval {
        TimeInterval(max(estimatedDurationMinutes, 1) * 60)
    }

    /// Internal placement. Duration fills the end. Does not mark the task complete.
    mutating func applyPlacement(start: Date) {
        scheduledStart = start
        scheduledEnd = start.addingTimeInterval(scheduledDuration)
        updatedAt = Date()
    }

    mutating func clearSchedule() {
        clearPlacementTimes()
        calendarEventIdentifier = nil
        updatedAt = Date()
    }

    /// Drops parked times but keeps the EventKit id so a later upsert is not a duplicate.
    mutating func clearPlacementTimes() {
        scheduledStart = nil
        scheduledEnd = nil
        updatedAt = Date()
    }

    mutating func setCompleted(_ completed: Bool, at date: Date = Date()) {
        isCompleted = completed
        completedAt = completed ? (completedAt ?? date) : nil
        updatedAt = date
    }

    /// Writes completion when the placed window has ended. Leaves the calendar event alone.
    @discardableResult
    mutating func applyAutomaticCompletion(at now: Date) -> Bool {
        guard !isCompleted, let scheduledEnd, scheduledEnd < now else { return false }
        isCompleted = true
        completedAt = scheduledEnd
        updatedAt = now
        return true
    }

    func shouldRetainCompleted(at now: Date) -> Bool {
        guard isCompleted else { return true }
        let anchor = completedAt ?? scheduledEnd ?? updatedAt
        return now < anchor.addingTimeInterval(TaskRetention.completedVisibleFor)
    }
}
