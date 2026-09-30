import Foundation

/// Calendar-block kinds a task may (or may not) share time with.
/// This is a set of kinds — never a single global “can multitask” flag.
enum TaskOverlapKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case driving
    case walking
    case waiting
    case transit
    /// `class` is a Swift keyword; the stored value is still `"class"`.
    case classSession = "class"
    case meeting
    case focusedWork

    var id: String { rawValue }

    /// Kinds that can host a task if the task lists them in `allowedOverlaps`.
    static let compatibleHosts: [TaskOverlapKind] = [.driving, .walking, .waiting, .transit]

    /// Class, meeting, and focused work never host a task, even if listed.
    var canHostOverlappingTask: Bool {
        switch self {
        case .driving, .walking, .waiting, .transit:
            return true
        case .classSession, .meeting, .focusedWork:
            return false
        }
    }

    var title: String {
        switch self {
        case .driving: ScedraString("Driving")
        case .walking: ScedraString("Walking")
        case .waiting: ScedraString("Waiting")
        case .transit: ScedraString("Transit")
        case .classSession: ScedraString("Class")
        case .meeting: ScedraString("Meeting")
        case .focusedWork: ScedraString("Focused work")
        }
    }

    /// Conservative read of a calendar title. Unknown titles are focused work.
    static func inferred(fromTitle title: String) -> TaskOverlapKind {
        let hay = title.lowercased()
        if matches(hay, ["transit", "bus", "train", "bart", "metro"]) { return .transit }
        if matches(hay, ["walk", "walking"]) { return .walking }
        if matches(hay, ["wait", "waiting"]) { return .waiting }
        if matches(hay, ["drive", "driving", "commute"]) { return .driving }
        if matches(hay, ["class", "lecture", "seminar"]) { return .classSession }
        if matches(hay, ["meeting"]) { return .meeting }
        return .focusedWork
    }

    private static func matches(_ hay: String, _ needles: [String]) -> Bool {
        needles.contains { hay.contains($0) }
    }
}

enum TaskOverlap {
    /// Whether this task may share time with a busy block of `kind`.
    static func canOverlap(_ task: ScedraTask, with kind: TaskOverlapKind) -> Bool {
        canOverlap(allowed: task.allowedOverlaps, with: kind)
    }

    static func canOverlap(allowed: Set<TaskOverlapKind>, with kind: TaskOverlapKind) -> Bool {
        kind.canHostOverlappingTask && allowed.contains(kind)
    }
}
