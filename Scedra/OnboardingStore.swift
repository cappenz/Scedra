import Foundation
import SwiftUI

protocol OnboardingStore: AnyObject {
    var hasSavedProgress: Bool { get }
    func load() -> OnboardingProgress
    func save(_ progress: OnboardingProgress)
}

final class UserDefaultsOnboardingStore: OnboardingStore {
    static let key = "scedra.onboarding"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasSavedProgress: Bool {
        defaults.data(forKey: Self.key) != nil
    }

    func load() -> OnboardingProgress {
        guard let data = defaults.data(forKey: Self.key) else {
            return OnboardingProgress()
        }
        return (try? Self.decoder.decode(OnboardingProgress.self, from: data)) ?? OnboardingProgress()
    }

    func save(_ progress: OnboardingProgress) {
        guard let data = try? Self.encoder.encode(progress) else { return }
        defaults.set(data, forKey: Self.key)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder = JSONDecoder()
}

final class MemoryOnboardingStore: OnboardingStore {
    private var progress: OnboardingProgress?
    var hasSavedProgress: Bool { progress != nil }

    init(progress: OnboardingProgress? = nil) {
        self.progress = progress
    }

    func load() -> OnboardingProgress {
        progress ?? OnboardingProgress()
    }

    func save(_ progress: OnboardingProgress) {
        self.progress = progress
    }
}

enum OnboardingTabRequest: Equatable {
    case capture
    case tasks
}

enum OnboardingEventWalkthrough: Equatable {
    /// Pulse Voice / Photo / Type on the real Capture card.
    case captureModes
    /// Pulse the chosen mic, photo picker, or type field (then Review once there is text).
    case captureInput
    case review
    case saved
}

@MainActor
@Observable
final class OnboardingGuide {
    private let store: any OnboardingStore

    private(set) var progress: OnboardingProgress
    var showsWelcome = false
    var showsYoureSet = false
    var pendingTaskCreate = false
    var pendingOpenSettings = false
    var pendingFocusHome = false
    var eventWalkthrough: OnboardingEventWalkthrough?
    /// Bumps every time the event coach starts so Capture always scrolls and redraws, even if the phase was already `.captureModes`.
    private(set) var eventCoachEpoch = 0
    var tabRequest: OnboardingTabRequest?

    init(store: any OnboardingStore = UserDefaultsOnboardingStore()) {
        self.store = store
        self.progress = store.load()
    }

    var showsChecklist: Bool {
        progress.welcomeSeen && !progress.dismissed
    }

    /// One-shot: existing users skip the auto welcome/checklist; new users see welcome.
    func seedIfNeeded(
        homeIsSet: Bool,
        hasScedraCreatedEvent: @autoclosure () -> Bool,
        hasTasks: Bool
    ) {
        if store.hasSavedProgress {
            syncHome(isSet: homeIsSet)
            showsWelcome = !progress.welcomeSeen && !progress.dismissed
            return
        }
        let scedraEvent = hasScedraCreatedEvent()
        if OnboardingExistingUser.isExisting(
            homeIsSet: homeIsSet,
            hasScedraCreatedEvent: scedraEvent,
            hasTasks: hasTasks
        ) {
            var seeded = OnboardingProgress()
            seeded.welcomeSeen = true
            seeded.dismissed = true
            seeded.homeDone = homeIsSet
            seeded.eventDone = scedraEvent
            seeded.taskDone = hasTasks
            persist(seeded, animated: false)
            showsWelcome = false
            return
        }
        persist(OnboardingProgress(), animated: false)
        showsWelcome = true
    }

    func acknowledgeWelcome() {
        var next = progress
        next.welcomeSeen = true
        persist(next)
        showsWelcome = false
    }

    func dismissAll() {
        var next = progress
        next.dismissed = true
        persist(next)
        showsYoureSet = false
        pendingOpenSettings = false
        pendingFocusHome = false
        eventWalkthrough = nil
    }

    func skip(_ step: OnboardingStep) {
        if step == .event {
            eventWalkthrough = nil
        }
        markDone(step)
    }

    func reopenFromSettings() {
        var next = progress
        next.welcomeSeen = true
        next.dismissed = false
        persist(next)
        showsWelcome = false
        showsYoureSet = next.allDone
        tabRequest = .capture
    }

    func start(_ step: OnboardingStep) {
        switch step {
        case .home:
            // Real Settings sheet on Capture — same SettingsView as the gear.
            pendingOpenSettings = true
            pendingFocusHome = true
            tabRequest = .capture
        case .event:
            withAnimation(.easeInOut(duration: 0.28)) {
                eventWalkthrough = .captureModes
                eventCoachEpoch += 1
            }
            tabRequest = .capture
        case .task:
            pendingTaskCreate = true
            tabRequest = .tasks
        }
    }

    func consumeTabRequest() {
        tabRequest = nil
    }

    func consumePendingTaskCreate() {
        pendingTaskCreate = false
    }

    func consumePendingOpenSettings() {
        pendingOpenSettings = false
    }

    func consumePendingFocusHome() {
        pendingFocusHome = false
    }

    func skipEventWalkthrough() {
        eventWalkthrough = nil
    }

    func noteCaptureModePicked() {
        guard eventWalkthrough == .captureModes else { return }
        withAnimation(.easeInOut(duration: 0.28)) {
            eventWalkthrough = .captureInput
        }
    }

    func advanceEventWalkthroughToReview() {
        guard eventWalkthrough == .captureModes || eventWalkthrough == .captureInput else { return }
        eventWalkthrough = .review
    }

    func retreatEventWalkthroughToCapture() {
        guard eventWalkthrough == .review else { return }
        eventWalkthrough = .captureInput
    }

    func advanceEventWalkthroughToSaved() {
        guard eventWalkthrough == .review else { return }
        eventWalkthrough = .saved
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(2800))
            guard eventWalkthrough == .saved else { return }
            eventWalkthrough = nil
        }
    }

    func syncHome(isSet: Bool) {
        guard isSet else { return }
        markDone(.home)
    }

    func markEventDone() {
        markDone(.event)
    }

    func markTaskDone() {
        markDone(.task)
    }

    private func markDone(_ step: OnboardingStep) {
        guard !progress.isDone(step) else { return }
        let wasAllDone = progress.allDone
        var next = progress
        next.markDone(step)
        persist(next)
        if next.allDone, !wasAllDone, next.welcomeSeen, !next.dismissed {
            showYoureSetThenHide()
        }
    }

    private func showYoureSetThenHide() {
        showsYoureSet = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1600))
            guard progress.allDone, !progress.dismissed else { return }
            var next = progress
            next.dismissed = true
            persist(next)
            showsYoureSet = false
        }
    }

    private func persist(_ next: OnboardingProgress, animated: Bool = true) {
        if animated {
            withAnimation(.easeInOut(duration: 0.28)) {
                progress = next
            }
        } else {
            progress = next
        }
        store.save(next)
    }
}
