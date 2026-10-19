import Foundation

/// Setup checklist persisted as JSON in UserDefaults, same idea as `TaskStore`.
struct OnboardingProgress: Codable, Equatable {
    var welcomeSeen = false
    var dismissed = false
    var homeDone = false
    var eventDone = false
    var taskDone = false

    var completedCount: Int {
        [homeDone, eventDone, taskDone].filter(\.self).count
    }

    var allDone: Bool {
        homeDone && eventDone && taskDone
    }

    func isDone(_ step: OnboardingStep) -> Bool {
        switch step {
        case .home: homeDone
        case .event: eventDone
        case .task: taskDone
        }
    }

    mutating func markDone(_ step: OnboardingStep) {
        switch step {
        case .home: homeDone = true
        case .event: eventDone = true
        case .task: taskDone = true
        }
    }
}

enum OnboardingStep: String, CaseIterable, Identifiable {
    case home
    case event
    case task

    var id: String { rawValue }
}

/// First launch of this feature: anyone who already used Scedra is not a brand-new user.
enum OnboardingExistingUser {
    static func isExisting(homeIsSet: Bool, hasScedraCreatedEvent: Bool, hasTasks: Bool) -> Bool {
        homeIsSet || hasScedraCreatedEvent || hasTasks
    }
}
