import XCTest
@testable import Scedra

final class ScedraOnboardingTests: XCTestCase {
    func testExistingUserIsAnyoneWithHomeEventOrTask() {
        XCTAssertFalse(OnboardingExistingUser.isExisting(
            homeIsSet: false, hasScedraCreatedEvent: false, hasTasks: false
        ))
        XCTAssertTrue(OnboardingExistingUser.isExisting(
            homeIsSet: true, hasScedraCreatedEvent: false, hasTasks: false
        ))
        XCTAssertTrue(OnboardingExistingUser.isExisting(
            homeIsSet: false, hasScedraCreatedEvent: true, hasTasks: false
        ))
        XCTAssertTrue(OnboardingExistingUser.isExisting(
            homeIsSet: false, hasScedraCreatedEvent: false, hasTasks: true
        ))
    }

    func testStoreRoundTrip() throws {
        let suite = "scedra.onboarding.round-trip.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("could not create isolated defaults")
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = UserDefaultsOnboardingStore(defaults: defaults)
        XCTAssertFalse(store.hasSavedProgress)

        var progress = OnboardingProgress()
        progress.welcomeSeen = true
        progress.homeDone = true
        store.save(progress)

        XCTAssertTrue(store.hasSavedProgress)
        let loaded = store.load()
        XCTAssertEqual(loaded, progress)
        XCTAssertFalse(loaded.dismissed)
        XCTAssertFalse(loaded.eventDone)
        XCTAssertEqual(loaded.completedCount, 1)

        let json = String(data: try UserDefaultsOnboardingStore.encoder.encode(loaded), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("welcomeSeen"))
        XCTAssertTrue(json.contains("homeDone"))
    }

    @MainActor
    func testNewUserSeesWelcomeAndChecklist() {
        let store = MemoryOnboardingStore()
        let guide = OnboardingGuide(store: store)
        guide.seedIfNeeded(homeIsSet: false, hasScedraCreatedEvent: false, hasTasks: false)
        XCTAssertTrue(guide.showsWelcome)
        XCTAssertFalse(guide.showsChecklist)
        XCTAssertTrue(store.hasSavedProgress)

        guide.acknowledgeWelcome()
        XCTAssertFalse(guide.showsWelcome)
        XCTAssertTrue(guide.showsChecklist)
        XCTAssertTrue(guide.progress.welcomeSeen)
    }

    @MainActor
    func testExistingUserDoesNotAutoShowWelcomeOrChecklist() {
        let store = MemoryOnboardingStore()
        let guide = OnboardingGuide(store: store)
        guide.seedIfNeeded(homeIsSet: true, hasScedraCreatedEvent: false, hasTasks: true)
        XCTAssertFalse(guide.showsWelcome)
        XCTAssertFalse(guide.showsChecklist)
        XCTAssertTrue(guide.progress.welcomeSeen)
        XCTAssertTrue(guide.progress.dismissed)
        XCTAssertTrue(guide.progress.homeDone)
        XCTAssertTrue(guide.progress.taskDone)
        XCTAssertFalse(guide.progress.eventDone)
    }

    @MainActor
    func testExistingScedraEventSkipsAutoOnboarding() {
        let store = MemoryOnboardingStore()
        let guide = OnboardingGuide(store: store)
        guide.seedIfNeeded(homeIsSet: false, hasScedraCreatedEvent: true, hasTasks: false)
        XCTAssertFalse(guide.showsWelcome)
        XCTAssertFalse(guide.showsChecklist)
        XCTAssertTrue(guide.progress.eventDone)
        XCTAssertTrue(guide.progress.dismissed)
    }

    @MainActor
    func testSkipAndDismissPersist() {
        let store = MemoryOnboardingStore()
        let guide = OnboardingGuide(store: store)
        guide.seedIfNeeded(homeIsSet: false, hasScedraCreatedEvent: false, hasTasks: false)
        guide.acknowledgeWelcome()
        guide.skip(.home)
        XCTAssertTrue(guide.progress.homeDone)
        XCTAssertEqual(guide.progress.completedCount, 1)
        guide.dismissAll()
        XCTAssertFalse(guide.showsChecklist)
        XCTAssertTrue(store.load().dismissed)
        XCTAssertTrue(store.load().homeDone)
    }

    @MainActor
    func testHomeSavedLaterAutoCompletes() {
        let store = MemoryOnboardingStore()
        let guide = OnboardingGuide(store: store)
        guide.seedIfNeeded(homeIsSet: false, hasScedraCreatedEvent: false, hasTasks: false)
        guide.acknowledgeWelcome()
        XCTAssertFalse(guide.progress.homeDone)
        guide.syncHome(isSet: true)
        XCTAssertTrue(guide.progress.homeDone)
        XCTAssertTrue(store.load().homeDone)
    }

    @MainActor
    func testEventAndTaskHooksMarkComplete() {
        let store = MemoryOnboardingStore()
        let guide = OnboardingGuide(store: store)
        guide.seedIfNeeded(homeIsSet: false, hasScedraCreatedEvent: false, hasTasks: false)
        guide.acknowledgeWelcome()
        guide.markEventDone()
        guide.markTaskDone()
        XCTAssertTrue(guide.progress.eventDone)
        XCTAssertTrue(guide.progress.taskDone)
        XCTAssertEqual(guide.progress.completedCount, 2)
    }

    @MainActor
    func testSkippingLastStepShowsYoureSet() {
        let store = MemoryOnboardingStore()
        let guide = OnboardingGuide(store: store)
        guide.seedIfNeeded(homeIsSet: false, hasScedraCreatedEvent: false, hasTasks: false)
        guide.acknowledgeWelcome()
        guide.skip(.home)
        guide.skip(.event)
        guide.skip(.task)
        XCTAssertTrue(guide.progress.allDone)
        XCTAssertTrue(guide.showsYoureSet)
    }

    @MainActor
    func testSettingsReopensRemainingOrAllDone() {
        let store = MemoryOnboardingStore()
        let guide = OnboardingGuide(store: store)
        guide.seedIfNeeded(homeIsSet: true, hasScedraCreatedEvent: true, hasTasks: true)
        XCTAssertFalse(guide.showsChecklist)
        XCTAssertTrue(guide.progress.allDone)

        guide.reopenFromSettings()
        XCTAssertTrue(guide.showsChecklist)
        XCTAssertFalse(guide.progress.dismissed)
        XCTAssertTrue(guide.progress.allDone)
        XCTAssertTrue(guide.showsYoureSet)
        XCTAssertEqual(guide.tabRequest, .capture)
    }

    @MainActor
    func testUnfinishedWelcomeShowsAgain() {
        let store = MemoryOnboardingStore()
        let first = OnboardingGuide(store: store)
        first.seedIfNeeded(homeIsSet: false, hasScedraCreatedEvent: false, hasTasks: false)
        XCTAssertTrue(first.showsWelcome)
        XCTAssertFalse(store.load().welcomeSeen)

        let second = OnboardingGuide(store: store)
        second.seedIfNeeded(homeIsSet: false, hasScedraCreatedEvent: false, hasTasks: false)
        XCTAssertTrue(second.showsWelcome)
        XCTAssertFalse(second.showsChecklist)
    }

    @MainActor
    func testSeedDoesNotRerunForLaterLaunches() {
        let store = MemoryOnboardingStore()
        let guide = OnboardingGuide(store: store)
        guide.seedIfNeeded(homeIsSet: false, hasScedraCreatedEvent: false, hasTasks: false)
        guide.acknowledgeWelcome()
        XCTAssertTrue(guide.showsChecklist)

        let again = OnboardingGuide(store: store)
        again.seedIfNeeded(homeIsSet: false, hasScedraCreatedEvent: true, hasTasks: true)
        XCTAssertFalse(again.showsWelcome)
        XCTAssertTrue(again.showsChecklist)
        XCTAssertFalse(again.progress.eventDone)
        XCTAssertFalse(again.progress.taskDone)
    }

    @MainActor
    func testStartHomeOpensSettingsNotADedicatedSheet() {
        let store = MemoryOnboardingStore()
        let guide = OnboardingGuide(store: store)
        guide.seedIfNeeded(homeIsSet: false, hasScedraCreatedEvent: false, hasTasks: false)
        guide.acknowledgeWelcome()
        guide.start(.home)
        XCTAssertTrue(guide.pendingOpenSettings)
        XCTAssertTrue(guide.pendingFocusHome)
        XCTAssertEqual(guide.tabRequest, .capture)
        XCTAssertNil(guide.eventWalkthrough)
        guide.consumePendingOpenSettings()
        XCTAssertFalse(guide.pendingOpenSettings)
        XCTAssertTrue(guide.pendingFocusHome)
        guide.consumePendingFocusHome()
        XCTAssertFalse(guide.pendingFocusHome)
    }

    @MainActor
    func testStartEventWalksCaptureThenReviewThenSaved() {
        let store = MemoryOnboardingStore()
        let guide = OnboardingGuide(store: store)
        guide.seedIfNeeded(homeIsSet: false, hasScedraCreatedEvent: false, hasTasks: false)
        guide.acknowledgeWelcome()
        guide.start(.event)
        XCTAssertEqual(guide.eventWalkthrough, .captureModes)
        XCTAssertEqual(guide.eventCoachEpoch, 1)
        XCTAssertEqual(guide.tabRequest, .capture)
        XCTAssertFalse(guide.progress.eventDone)
        guide.start(.event)
        XCTAssertEqual(guide.eventWalkthrough, .captureModes)
        XCTAssertEqual(guide.eventCoachEpoch, 2)

        guide.noteCaptureModePicked()
        XCTAssertEqual(guide.eventWalkthrough, .captureInput)
        guide.noteCaptureModePicked()
        XCTAssertEqual(guide.eventWalkthrough, .captureInput)

        guide.advanceEventWalkthroughToReview()
        XCTAssertEqual(guide.eventWalkthrough, .review)

        guide.retreatEventWalkthroughToCapture()
        XCTAssertEqual(guide.eventWalkthrough, .captureInput)
        guide.advanceEventWalkthroughToReview()

        guide.advanceEventWalkthroughToSaved()
        XCTAssertEqual(guide.eventWalkthrough, .saved)
        XCTAssertFalse(guide.progress.eventDone)

        guide.markEventDone()
        XCTAssertTrue(guide.progress.eventDone)
    }

    @MainActor
    func testReviewCanAdvanceFromModesWithoutPicking() {
        let store = MemoryOnboardingStore()
        let guide = OnboardingGuide(store: store)
        guide.seedIfNeeded(homeIsSet: false, hasScedraCreatedEvent: false, hasTasks: false)
        guide.acknowledgeWelcome()
        guide.start(.event)
        guide.advanceEventWalkthroughToReview()
        XCTAssertEqual(guide.eventWalkthrough, .review)
    }

    func testCaptureCoachHighlightFollowsModeThenInput() {
        XCTAssertEqual(
            OnboardingCaptureCoach.highlight(phase: .captureModes, mode: .voice),
            .modes
        )
        XCTAssertEqual(
            OnboardingCaptureCoach.highlight(phase: .captureInput, mode: .voice),
            .voice
        )
        XCTAssertEqual(
            OnboardingCaptureCoach.highlight(phase: .captureInput, mode: .photo),
            .photo
        )
        XCTAssertEqual(
            OnboardingCaptureCoach.highlight(phase: .captureInput, mode: .type),
            .typeField
        )
        XCTAssertNil(OnboardingCaptureCoach.highlight(phase: .review, mode: .voice))
        XCTAssertNil(OnboardingCaptureCoach.highlight(phase: .saved, mode: .voice))
        XCTAssertNil(OnboardingCaptureCoach.highlight(phase: nil, mode: .photo))
    }

    @MainActor
    func testSkipEventWalkthroughDoesNotMarkEventDone() {
        let store = MemoryOnboardingStore()
        let guide = OnboardingGuide(store: store)
        guide.seedIfNeeded(homeIsSet: false, hasScedraCreatedEvent: false, hasTasks: false)
        guide.acknowledgeWelcome()
        guide.start(.event)
        guide.advanceEventWalkthroughToReview()
        guide.skipEventWalkthrough()
        XCTAssertNil(guide.eventWalkthrough)
        XCTAssertFalse(guide.progress.eventDone)
        guide.advanceEventWalkthroughToSaved()
        XCTAssertNil(guide.eventWalkthrough)
    }

    @MainActor
    func testSkipEventStepClearsWalkthrough() {
        let store = MemoryOnboardingStore()
        let guide = OnboardingGuide(store: store)
        guide.seedIfNeeded(homeIsSet: false, hasScedraCreatedEvent: false, hasTasks: false)
        guide.acknowledgeWelcome()
        guide.start(.event)
        guide.skip(.event)
        XCTAssertNil(guide.eventWalkthrough)
        XCTAssertTrue(guide.progress.eventDone)
    }

    @MainActor
    func testDismissAllClearsSettingsAndWalkthrough() {
        let store = MemoryOnboardingStore()
        let guide = OnboardingGuide(store: store)
        guide.seedIfNeeded(homeIsSet: false, hasScedraCreatedEvent: false, hasTasks: false)
        guide.acknowledgeWelcome()
        guide.start(.home)
        guide.start(.event)
        guide.dismissAll()
        XCTAssertFalse(guide.pendingOpenSettings)
        XCTAssertFalse(guide.pendingFocusHome)
        XCTAssertNil(guide.eventWalkthrough)
        XCTAssertFalse(guide.showsChecklist)
    }
}
