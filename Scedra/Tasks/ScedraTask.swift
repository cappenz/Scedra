import Foundation

/// Progress of a to-do. A past `scheduledEnd` is written to `isCompleted` by the store.
enum TaskProgressStatus: String, Equatable, Sendable {
    case open
    case completed
    case scheduledTimePassed
}

/// Normal vs important. Important tasks take the next good slot first and may bump a normal task.
enum TaskImportance: String, Equatable, Codable, Sendable {
    case normal
    case important
}

/// Something to finish. Calendar events occupy time; a task is placed in free time.
struct ScedraTask: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var title: String
    var notes: String
    var estimatedDurationMinutes: Int
    var deadline: Date?
    var isCompleted: Bool
    /// When it was checked off or auto-completed.
    var completedAt: Date?
    var location: String
    /// Travel legs use the existing `TravelEstimator` / `PlaceResolver` later — not a second Maps stack.
    var requiresTravel: Bool
    var allowedOverlaps: Set<TaskOverlapKind>
    var category: String
    var importance: TaskImportance
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
        importance: TaskImportance = .normal,
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
        self.importance = importance
        self.scheduledStart = scheduledStart
        self.scheduledEnd = scheduledEnd
        self.calendarEventIdentifier = calendarEventIdentifier
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, title, notes, estimatedDurationMinutes, deadline, isCompleted
        case completedAt, location, requiresTravel, allowedOverlaps, category, importance
        case scheduledStart, scheduledEnd, calendarEventIdentifier, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        estimatedDurationMinutes = max(try c.decodeIfPresent(Int.self, forKey: .estimatedDurationMinutes) ?? 30, 1)
        deadline = try c.decodeIfPresent(Date.self, forKey: .deadline)
        isCompleted = try c.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        location = try c.decodeIfPresent(String.self, forKey: .location) ?? ""
        requiresTravel = try c.decodeIfPresent(Bool.self, forKey: .requiresTravel) ?? false
        allowedOverlaps = try c.decodeIfPresent(Set<TaskOverlapKind>.self, forKey: .allowedOverlaps) ?? []
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        importance = try c.decodeIfPresent(TaskImportance.self, forKey: .importance) ?? .normal
        scheduledStart = try c.decodeIfPresent(Date.self, forKey: .scheduledStart)
        scheduledEnd = try c.decodeIfPresent(Date.self, forKey: .scheduledEnd)
        calendarEventIdentifier = try c.decodeIfPresent(String.self, forKey: .calendarEventIdentifier)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(notes, forKey: .notes)
        try c.encode(estimatedDurationMinutes, forKey: .estimatedDurationMinutes)
        try c.encodeIfPresent(deadline, forKey: .deadline)
        try c.encode(isCompleted, forKey: .isCompleted)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encode(location, forKey: .location)
        try c.encode(requiresTravel, forKey: .requiresTravel)
        try c.encode(allowedOverlaps, forKey: .allowedOverlaps)
        try c.encode(category, forKey: .category)
        try c.encode(importance, forKey: .importance)
        try c.encodeIfPresent(scheduledStart, forKey: .scheduledStart)
        try c.encodeIfPresent(scheduledEnd, forKey: .scheduledEnd)
        try c.encodeIfPresent(calendarEventIdentifier, forKey: .calendarEventIdentifier)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
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

    /// Keep a completed row for a day after it was checked off (or auto-completed).
    func shouldRetainCompleted(at now: Date) -> Bool {
        guard isCompleted else { return true }
        let anchor = completedAt ?? scheduledEnd ?? updatedAt
        return now < anchor.addingTimeInterval(TaskRetention.completedVisibleFor)
    }
}

enum TaskRetention {
    /// Completed tasks stay on the list until this long after `completedAt`.
    static let completedVisibleFor: TimeInterval = 24 * 3600
}
