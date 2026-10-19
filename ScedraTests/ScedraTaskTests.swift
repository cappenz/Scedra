import XCTest
@testable import Scedra

final class ScedraTaskTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private lazy var day: Date = calendar.date(
        from: DateComponents(year: 2026, month: 6, day: 10)
    )!
    private lazy var scheduler = DefaultTaskAutoScheduler(calendar: calendar)

    private func time(_ hour: Int, _ minute: Int = 0, on day: Date? = nil) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day ?? self.day)!
    }

    private func nextDay(_ hour: Int, _ minute: Int = 0) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!
        return time(hour, minute, on: tomorrow)
    }

    // MARK: - Overlap

    func testCallCanOverlapDriving() {
        let call = ScedraTask(
            title: "Call dentist",
            estimatedDurationMinutes: 10,
            allowedOverlaps: [.driving, .transit, .walking, .waiting]
        )
        XCTAssertTrue(TaskOverlap.canOverlap(call, with: .driving))
        XCTAssertTrue(TaskOverlap.canOverlap(call, with: .transit))
        XCTAssertTrue(TaskOverlap.canOverlap(call, with: .walking))
        XCTAssertTrue(TaskOverlap.canOverlap(call, with: .waiting))
        XCTAssertFalse(TaskOverlap.canOverlap(call, with: .classSession))
        XCTAssertFalse(TaskOverlap.canOverlap(call, with: .meeting))
        XCTAssertFalse(TaskOverlap.canOverlap(call, with: .focusedWork))
    }

    func testHomeworkCannotOverlapClass() {
        let homework = ScedraTask(
            title: "Finish chemistry homework",
            estimatedDurationMinutes: 45,
            allowedOverlaps: []
        )
        XCTAssertFalse(TaskOverlap.canOverlap(homework, with: .classSession))
        XCTAssertFalse(TaskOverlap.canOverlap(homework, with: .meeting))
        XCTAssertFalse(TaskOverlap.canOverlap(homework, with: .focusedWork))
        XCTAssertFalse(TaskOverlap.canOverlap(homework, with: .driving))
    }

    func testClassCannotHostEvenWhenListed() {
        var homework = ScedraTask(title: "Essay", estimatedDurationMinutes: 20)
        homework.allowedOverlaps = [.classSession, .meeting, .focusedWork]
        XCTAssertFalse(
            TaskOverlap.canOverlap(homework, with: .classSession),
            "class / meeting / focused work are never compatible hosts"
        )
        XCTAssertFalse(TaskOverlap.canOverlap(homework, with: .meeting))
        XCTAssertFalse(TaskOverlap.canOverlap(homework, with: .focusedWork))
    }

    // MARK: - Fit

    func testFitsInFreeThirtyMinuteWindow() {
        let busy = [
            TaskBusyBlock(start: time(9), end: time(10), kind: .meeting, title: "Standup"),
            TaskBusyBlock(start: time(10, 30), end: time(11), kind: .classSession, title: "Chem"),
        ]
        let fit = TaskAvailability.evaluate(
            start: time(10),
            durationMinutes: 30,
            allowedOverlaps: [],
            busy: busy
        )
        XCTAssertEqual(fit, .fits)
    }

    func testOverlapOKDuringDriving() {
        let call = ScedraTask(
            title: "Call dentist",
            estimatedDurationMinutes: 10,
            allowedOverlaps: [.driving, .transit, .walking, .waiting]
        )
        let busy = [
            TaskBusyBlock(start: time(10), end: time(10, 30), kind: .driving, title: "Commute"),
        ]
        XCTAssertEqual(
            TaskAvailability.evaluate(task: call, start: time(10, 5), busy: busy),
            .overlapOK
        )
    }

    func testHomeworkDoesNotFitDuringClass() {
        let homework = ScedraTask(
            title: "Finish chemistry homework",
            estimatedDurationMinutes: 45,
            allowedOverlaps: []
        )
        let busy = [
            TaskBusyBlock(start: time(10), end: time(11), kind: .classSession, title: "Chem"),
        ]
        XCTAssertEqual(
            TaskAvailability.evaluate(task: homework, start: time(10), busy: busy),
            .doesNotFit
        )
    }

    func testAdjacentBusyDoesNotCountAsOverlap() {
        let busy = [
            TaskBusyBlock(start: time(9), end: time(10), kind: .focusedWork, title: "Lab"),
        ]
        XCTAssertEqual(
            TaskAvailability.evaluate(
                start: time(10),
                durationMinutes: 30,
                allowedOverlaps: [],
                busy: busy
            ),
            .fits
        )
        XCTAssertEqual(
            TaskAvailability.evaluatePlacement(
                start: time(10),
                end: time(10, 30),
                allowedOverlaps: [],
                busy: busy
            ),
            .doesNotFit,
            "touching without the 10-minute buffer does not fit"
        )
    }

    // MARK: - Buffer

    func testExclusiveTaskWaitsForBufferAfterEvent() {
        XCTAssertEqual(TaskPlacementBuffer.minutes, 10)
        XCTAssertEqual(TaskPlacementBuffer.reducedMinutes, 5)
        let task = ScedraTask(title: "Homework", estimatedDurationMinutes: 30)
        let busy = [
            TaskBusyBlock(start: time(10), end: time(11), kind: .meeting, title: "Standup"),
        ]
        let start = scheduler.proposedStart(for: task, busy: busy, now: time(10))
        XCTAssertEqual(start, time(11, 10), "10-minute buffer after 11:00 → earliest 11:10")
        XCTAssertEqual(
            TaskAvailability.evaluatePlacement(task: task, start: time(11), busy: busy),
            .doesNotFit
        )
    }

    func testTwoExclusiveTasksCannotShareThreeOClock() {
        let occupied = TaskBusyBlock(
            start: time(15),
            end: time(15, 30),
            kind: .focusedWork,
            title: "Essay",
            isExclusiveTaskPlacement: true,
            isTaskPlacement: true
        )
        let homework = ScedraTask(title: "Homework", estimatedDurationMinutes: 30)
        XCTAssertEqual(
            TaskAvailability.evaluatePlacement(task: homework, start: time(15), busy: [occupied]),
            .doesNotFit
        )
        XCTAssertEqual(
            TaskAvailability.evaluate(task: homework, start: time(15), busy: [occupied]),
            .doesNotFit
        )
        XCTAssertNotEqual(
            scheduler.proposedStart(for: homework, busy: [occupied], now: time(14, 30)),
            time(15)
        )
        XCTAssertEqual(
            scheduler.proposedStart(for: homework, busy: [occupied], now: time(14, 30)),
            time(15, 40),
            "10-minute buffer after 3:30"
        )
    }

    func testOverlapChipsDoNotLetTwoTasksShareASlot() {
        let otherCall = TaskBusyBlock(
            start: time(15),
            end: time(15, 15),
            kind: .driving,
            title: "Call grandma",
            isTaskPlacement: true
        )
        let call = ScedraTask(
            title: "Call dentist",
            estimatedDurationMinutes: 10,
            allowedOverlaps: [.driving]
        )
        XCTAssertEqual(
            TaskAvailability.evaluatePlacement(task: call, start: time(15), busy: [otherCall]),
            .doesNotFit,
            "overlap chips never let two tasks sit on each other"
        )
    }

    func testBufferedGapCannotFitFortyFiveMinuteExclusiveTask() {
        let task = ScedraTask(title: "Homework", estimatedDurationMinutes: 45)
        let busy = [
            TaskBusyBlock(start: time(10), end: time(11), kind: .meeting, title: "Standup"),
            TaskBusyBlock(start: time(11, 50), end: time(13), kind: .classSession, title: "Chem"),
        ]
        let start = scheduler.proposedStart(for: task, busy: busy, now: time(11))
        XCTAssertEqual(start, time(13, 10))
        XCTAssertNotEqual(start, time(11))
        XCTAssertEqual(
            TaskAvailability.evaluatePlacement(task: task, start: time(11, 5), busy: busy),
            .doesNotFit
        )
    }

    func testOverlapAllowedTaskSitsInsideDrivingWithoutBuffer() {
        let call = ScedraTask(
            title: "Call grandma",
            estimatedDurationMinutes: 10,
            allowedOverlaps: [.driving]
        )
        let busy = [
            TaskBusyBlock(start: time(10), end: time(11), kind: .driving, title: "Commute"),
        ]
        XCTAssertEqual(
            TaskAvailability.evaluatePlacement(task: call, start: time(10), busy: busy),
            .overlapOK
        )
        XCTAssertEqual(
            scheduler.proposedStart(for: call, busy: busy, now: time(9, 30)),
            time(10)
        )
    }

    // MARK: - Waking hours

    func testThirtyMinuteTaskIsNotPlacedAtFiveAMWhenWakingSlotExists() {
        let task = ScedraTask(title: "Call dentist", estimatedDurationMinutes: 30)
        let start = scheduler.proposedStart(for: task, busy: [], now: time(5))
        XCTAssertEqual(start, time(8))
        XCTAssertNotEqual(start, time(5))
    }

    func testThirtyMinuteTaskIsNotPlacedAtElevenPMWhenWakingSlotExists() {
        let task = ScedraTask(title: "Call dentist", estimatedDurationMinutes: 30)
        let start = scheduler.proposedStart(for: task, busy: [], now: time(23))
        XCTAssertEqual(start, nextDay(8))
        XCTAssertNotEqual(start, time(23))
    }

    func testDeadlineCanPlaceSlightlyOutsideWakingHours() {
        var task = ScedraTask(title: "Submit form", estimatedDurationMinutes: 30)
        task.deadline = nextDay(8)
        let start = scheduler.proposedStart(for: task, busy: [], now: time(23))
        XCTAssertEqual(start, nextDay(7), "8:00 waking start misses an 8:00 deadline; 7:00 is the first extended-hours slot")
        XCTAssertTrue(TaskWakingHours.contains(start: start!, end: start!.addingTimeInterval(30 * 60), extended: true))
        XCTAssertFalse(TaskWakingHours.contains(start: start!, end: start!.addingTimeInterval(30 * 60)))
    }

    func testNoThreeAMSlotWhenDeadlineCannotBeMet() {
        var task = ScedraTask(title: "Impossible", estimatedDurationMinutes: 30)
        task.deadline = nextDay(5)
        XCTAssertNil(
            scheduler.proposedStart(for: task, busy: [], now: time(23)),
            "leave unscheduled rather than invent a 3am slot"
        )
    }

    func testTaskSavedAtTwoPMIsNotScheduledImmediately() {
        XCTAssertEqual(TaskPlacementLeadTime.minutes, 30)
        let task = ScedraTask(title: "Homework", estimatedDurationMinutes: 30)
        let now = time(14)
        let start = scheduler.proposedStart(for: task, busy: [], now: now)
        XCTAssertEqual(start, time(14, 30))
        XCTAssertNotEqual(start, now)
        XCTAssertGreaterThanOrEqual(
            start!.timeIntervalSince(now),
            TaskPlacementLeadTime.interval
        )
        XCTAssertTrue(TaskWakingHours.contains(start: start!, end: start!.addingTimeInterval(30 * 60)))
    }

    func testLeadTimeSkipsImmediateSlotWhenLaterInHoursGapExists() {
        let task = ScedraTask(title: "Homework", estimatedDurationMinutes: 30)
        let now = time(14)
        let busy = [
            TaskBusyBlock(start: time(14, 30), end: time(15), kind: .meeting, title: "Standup"),
        ]
        let start = scheduler.proposedStart(for: task, busy: busy, now: now)
        XCTAssertEqual(start, time(15, 10), "buffer after the 15:00 meeting, not 14:00 or 14:30")
        XCTAssertNotEqual(start, now)
        XCTAssertGreaterThan(start!.timeIntervalSince(now), TaskPlacementLeadTime.interval)
    }

    func testDeadlineInsideLeadWindowLeavesTaskUnscheduled() {
        var task = ScedraTask(title: "Submit form", estimatedDurationMinutes: 15)
        task.deadline = time(14, 20)
        XCTAssertNil(
            scheduler.proposedStart(for: task, busy: [], now: time(14)),
            "do not squeeze a slot into the next few minutes to hit a deadline"
        )
    }

    func testPreferredWindowIsGone() {
        let task = ScedraTask(title: "Call dentist")
        let mirrors = Mirror(reflecting: task).children.compactMap(\.label)
        XCTAssertFalse(mirrors.contains { $0.contains("preferredWindow") })
    }

    func testTaskIsNotPlacedToEndAfterEightWhenEarlierInHoursSlotExists() {
        XCTAssertEqual(TaskWakingHours.endHour, 20)
        XCTAssertEqual(TaskWakingHours.extendedEndHour, 21)
        let task = ScedraTask(title: "Homework", estimatedDurationMinutes: 30)
        let start = scheduler.proposedStart(for: task, busy: [], now: time(19, 45))
        XCTAssertEqual(start, nextDay(8), "lead time would end after 8pm; tomorrow 8:00 is still in hours")
        XCTAssertNotEqual(start, time(20, 15))
        let end = start!.addingTimeInterval(30 * 60)
        XCTAssertTrue(TaskWakingHours.contains(start: start!, end: end))
        XCTAssertLessThanOrEqual(calendar.component(.hour, from: end) * 60 + calendar.component(.minute, from: end), 20 * 60)
    }

    func testDeadlineMayPlaceAfterEightOnlyWhenNoInHoursSlotRemains() {
        var task = ScedraTask(title: "Submit form", estimatedDurationMinutes: 30)
        task.deadline = time(21)
        let start = scheduler.proposedStart(for: task, busy: [], now: time(19, 45))
        XCTAssertEqual(start, time(20, 15), "deadline is the only reason to finish after 8pm")
        XCTAssertTrue(TaskWakingHours.contains(start: start!, end: start!.addingTimeInterval(30 * 60), extended: true))
        XCTAssertFalse(TaskWakingHours.contains(start: start!, end: start!.addingTimeInterval(30 * 60)))
    }

    func testThirdExclusiveTaskWaitsForStackingRest() {
        XCTAssertEqual(TaskPlacementStacking.consecutiveExclusiveTaskLimit, 2)
        XCTAssertEqual(TaskPlacementStacking.consecutiveExclusiveMinutesLimit, 75)
        XCTAssertEqual(TaskPlacementStacking.restMinutes, 25)
        let task = ScedraTask(title: "Essay", estimatedDurationMinutes: 30)
        let busy = [
            TaskBusyBlock(
                start: time(14),
                end: time(14, 30),
                kind: .focusedWork,
                title: "Homework",
                isExclusiveTaskPlacement: true
            ),
            TaskBusyBlock(
                start: time(14, 40),
                end: time(15, 10),
                kind: .focusedWork,
                title: "Reading",
                isExclusiveTaskPlacement: true
            ),
        ]
        let start = scheduler.proposedStart(for: task, busy: busy, now: time(13, 30))
        XCTAssertNotEqual(start, time(15, 20), "must not pack 2:00 / 2:40 / 3:20")
        XCTAssertEqual(start, time(15, 35), "25-minute rest after two exclusive 30-min tasks")
    }

    func testCalendarMeetingsStillUseTenMinuteNeighborBuffer() {
        let task = ScedraTask(title: "Essay", estimatedDurationMinutes: 30)
        let busy = [
            TaskBusyBlock(start: time(14), end: time(14, 30), kind: .meeting, title: "Standup"),
            TaskBusyBlock(start: time(14, 40), end: time(15, 10), kind: .meeting, title: "1:1"),
        ]
        XCTAssertEqual(
            scheduler.proposedStart(for: task, busy: busy, now: time(13, 30)),
            time(15, 20),
            "calendar appointments keep the 10-minute buffer; stacking rest is for exclusive tasks"
        )
    }

    // MARK: - Auto-complete + prune

    func testScheduledEndInThePastCompletesTheTask() {
        var task = ScedraTask(title: "Call dentist", estimatedDurationMinutes: 10)
        task.applyPlacement(start: time(10))
        XCTAssertEqual(task.scheduledEnd, time(10, 10))
        XCTAssertFalse(task.isCompleted)
        XCTAssertEqual(task.progressStatus(at: time(12)), .scheduledTimePassed)

        XCTAssertTrue(task.applyAutomaticCompletion(at: time(12)))
        XCTAssertTrue(task.isCompleted)
        XCTAssertEqual(task.completedAt, time(10, 10))
        XCTAssertEqual(task.progressStatus(at: time(12)), .completed)
        XCTAssertEqual(task.calendarEventIdentifier, nil, "completion does not invent or clear a calendar id")
        XCTAssertTrue(task.shouldRetainCompleted(at: time(12)), "still visible the same day")
        XCTAssertTrue(
            task.shouldRetainCompleted(at: time(10, 10).addingTimeInterval(23 * 3600)),
            "visible for 24 hours after completedAt"
        )
        XCTAssertFalse(
            task.shouldRetainCompleted(at: time(10, 10).addingTimeInterval(TaskRetention.completedVisibleFor + 1)),
            "pruned after 24 hours"
        )
        XCTAssertEqual(TaskRetention.completedVisibleFor, 24 * 3600)
    }

    @MainActor
    func testRepositoryKeepsElapsedCompletedTaskUntilRetentionWindow() {
        let repository = TaskRepository(store: MemoryTaskStore())
        var task = ScedraTask(title: "Call dentist", estimatedDurationMinutes: 10)
        task.applyPlacement(start: time(8))
        repository.upsert(task)
        repository.reconcile(now: time(12))

        XCTAssertTrue(repository.openTasks.isEmpty)
        XCTAssertEqual(repository.completedTasks(at: time(12)).count, 1)
        XCTAssertEqual(repository.tasks.count, 1, "completed after scheduledEnd stays until the 24h prune")
        XCTAssertEqual(repository.tasks[0].completedAt, time(8, 10))
    }

    @MainActor
    func testManualCompleteBeforeScheduledEndPrunes24hAfterCompletedAt() {
        let repository = TaskRepository(store: MemoryTaskStore())
        var task = ScedraTask(title: "Call dentist", estimatedDurationMinutes: 30)
        task.applyPlacement(start: time(10))
        repository.upsert(task)
        repository.setCompleted(repository.tasks[0], isCompleted: true, at: time(10, 5))

        XCTAssertEqual(repository.completedTasks(at: time(10, 5)).count, 1)
        XCTAssertEqual(repository.completedTasks(at: time(10, 31)).count, 1, "past scheduledEnd is still completed, not deleted")
        XCTAssertEqual(
            repository.completedTasks(at: time(10, 5).addingTimeInterval(23 * 3600)).count,
            1
        )
        XCTAssertTrue(
            repository.completedTasks(at: time(10, 5).addingTimeInterval(TaskRetention.completedVisibleFor + 1)).isEmpty
        )
        _ = repository.reconcile(now: time(10, 5).addingTimeInterval(TaskRetention.completedVisibleFor + 1))
        XCTAssertTrue(repository.tasks.isEmpty)
    }

    @MainActor
    func testCompletedOlderThan24HoursIsGoneFromStore() {
        let old = ScedraTask(
            title: "Stale",
            isCompleted: true,
            completedAt: time(9),
            scheduledStart: time(8),
            scheduledEnd: time(8, 30)
        )
        let stored = MemoryTaskStore(tasks: [old])
        let loaded = TaskRepository(store: stored)
        loaded.reconcile(now: time(9).addingTimeInterval(TaskRetention.completedVisibleFor + 60))
        XCTAssertTrue(loaded.completedTasks(at: time(9).addingTimeInterval(TaskRetention.completedVisibleFor + 60)).isEmpty)
        XCTAssertTrue(loaded.tasks.isEmpty)
        XCTAssertTrue(stored.load().isEmpty, "pruned rows are dropped from persistence")
    }

    @MainActor
    func testUnscheduledCompletedTaskStaysFor24Hours() {
        let repository = TaskRepository(store: MemoryTaskStore())
        repository.upsert(ScedraTask(title: "Call dentist", estimatedDurationMinutes: 10))
        repository.setCompleted(repository.openTasks[0], isCompleted: true, at: time(10))
        XCTAssertEqual(repository.completedTasks(at: time(10)).count, 1)
        XCTAssertEqual(repository.tasks.count, 1)
        _ = repository.reconcile(now: time(10).addingTimeInterval(TaskRetention.completedVisibleFor + 1))
        XCTAssertTrue(repository.tasks.isEmpty)
    }

    // MARK: - Store

    func testStoreRoundTripWithoutPreferredWindow() throws {
        let suite = "scedra.tasks.round-trip"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("could not create isolated defaults")
        }
        defaults.removePersistentDomain(forName: suite)

        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let deadline = Date(timeIntervalSince1970: 1_800_086_400)
        let scheduledStart = Date(timeIntervalSince1970: 1_800_010_800)
        var task = ScedraTask(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            title: "Buy groceries",
            notes: "Milk and eggs",
            estimatedDurationMinutes: 30,
            deadline: deadline,
            isCompleted: false,
            location: "grocery",
            requiresTravel: true,
            allowedOverlaps: [.walking, .waiting],
            category: "errand",
            createdAt: created,
            updatedAt: created
        )
        task.applyPlacement(start: scheduledStart)
        task.updatedAt = created
        task.calendarEventIdentifier = "ek-groceries"

        let store = UserDefaultsTaskStore(defaults: defaults)
        store.save([task])
        let loaded = store.load()
        XCTAssertEqual(loaded, [task])
        XCTAssertEqual(loaded[0].allowedOverlaps, [.walking, .waiting])
        XCTAssertTrue(loaded[0].requiresTravel)
        XCTAssertEqual(loaded[0].location, "grocery")
        XCTAssertEqual(loaded[0].scheduledStart, scheduledStart)
        XCTAssertEqual(loaded[0].scheduledEnd, scheduledStart.addingTimeInterval(30 * 60))
        XCTAssertEqual(loaded[0].calendarEventIdentifier, "ek-groceries")

        let json = String(data: try UserDefaultsTaskStore.encoder.encode(loaded), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("preferredWindow"))
    }

    func testStoreIgnoresOldPreferredWindowOnDecode() throws {
        let json = """
        [{"allowedOverlaps":[],"category":"","createdAt":"2026-06-10T16:00:00Z","estimatedDurationMinutes":30,"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","isCompleted":false,"location":"","notes":"","preferredWindowEnd":"2026-06-10T18:00:00Z","preferredWindowStart":"2026-06-10T17:00:00Z","requiresTravel":false,"title":"Old task","updatedAt":"2026-06-10T16:00:00Z"}]
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let loaded = try UserDefaultsTaskStore.decoder.decode([ScedraTask].self, from: data)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].title, "Old task")
        XCTAssertNil(loaded[0].scheduledStart)
        let mirrors = Mirror(reflecting: loaded[0]).children.compactMap(\.label)
        XCTAssertFalse(mirrors.contains { $0.contains("preferredWindow") })
    }

    @MainActor
    func testSuccessfulPlacementWritesCalendarEvent() async {
        let writer = MemoryTaskCalendarWriter()
        let repository = TaskRepository(store: MemoryTaskStore())
        let task = ScedraTask(title: "Call dentist", estimatedDurationMinutes: 30)
        await repository.placeAndSave(task, writer: writer, busy: [], now: time(9), scheduler: scheduler)

        XCTAssertEqual(writer.upserts.count, 1)
        XCTAssertEqual(writer.upserts[0].title, "Call dentist")
        XCTAssertEqual(writer.upserts[0].start, time(9, 30))
        XCTAssertEqual(writer.upserts[0].end, time(10))
        XCTAssertEqual(repository.openTasks[0].calendarEventIdentifier, writer.upserts[0].identifier)
        XCTAssertTrue(writer.deletedIdentifiers.isEmpty)
    }

    @MainActor
    func testFailedPlacementDoesNotWriteCalendar() async {
        let writer = MemoryTaskCalendarWriter()
        let repository = TaskRepository(store: MemoryTaskStore())
        let task = ScedraTask(
            title: "Homework",
            estimatedDurationMinutes: 30,
            deadline: time(21)
        )
        let busy = [
            TaskBusyBlock(start: time(8), end: time(21), kind: .focusedWork, title: "Packed"),
        ]
        await repository.placeAndSave(task, writer: writer, busy: busy, now: time(9), scheduler: scheduler)

        XCTAssertTrue(writer.upserts.isEmpty)
        XCTAssertNil(repository.openTasks[0].scheduledStart)
        XCTAssertNil(repository.openTasks[0].calendarEventIdentifier)
    }

    @MainActor
    func testCompletingATaskKeepsCalendarEventUntilRetentionPrune() async {
        let writer = MemoryTaskCalendarWriter()
        let repository = TaskRepository(store: MemoryTaskStore())
        let task = ScedraTask(title: "Call dentist", estimatedDurationMinutes: 30)
        await repository.placeAndSave(task, writer: writer, busy: [], now: time(9), scheduler: scheduler)
        let placed = repository.openTasks[0]
        XCTAssertEqual(placed.calendarEventIdentifier, writer.upserts[0].identifier)
        XCTAssertEqual(placed.scheduledEnd, time(10))

        await repository.setCompleted(placed, isCompleted: true, from: writer, at: time(9, 5))

        XCTAssertTrue(writer.deletedIdentifiers.isEmpty, "checking off keeps the calendar block until prune")
        XCTAssertEqual(
            repository.completedTasks(at: time(9, 5)).first?.calendarEventIdentifier,
            placed.calendarEventIdentifier
        )

        await repository.pruneCompleted(
            writer: writer,
            now: time(9, 5).addingTimeInterval(23 * 3600)
        )
        XCTAssertTrue(writer.deletedIdentifiers.isEmpty)
        XCTAssertEqual(repository.tasks.count, 1)

        await repository.pruneCompleted(
            writer: writer,
            now: time(9, 5).addingTimeInterval(TaskRetention.completedVisibleFor + 1)
        )
        XCTAssertEqual(writer.deletedIdentifiers, [placed.calendarEventIdentifier ?? ""])
        XCTAssertTrue(repository.tasks.isEmpty)
    }

    @MainActor
    func testManualRescheduleUpdatesExistingCalendarEvent() async {
        let writer = MemoryTaskCalendarWriter()
        let repository = TaskRepository(store: MemoryTaskStore())
        let task = ScedraTask(title: "Homework", estimatedDurationMinutes: 30)
        await repository.placeAndSave(task, writer: writer, busy: [], now: time(9), scheduler: scheduler)

        let placed = repository.openTasks[0]
        XCTAssertEqual(placed.scheduledStart, time(9, 30))
        let identifier = placed.calendarEventIdentifier
        XCTAssertEqual(identifier, "task-event-1")

        await repository.rescheduleAndSave(
            placed,
            start: time(11),
            writer: writer,
            busy: [],
            now: time(9),
            scheduler: scheduler
        )

        XCTAssertEqual(repository.openTasks[0].scheduledStart, time(11))
        XCTAssertEqual(repository.openTasks[0].scheduledEnd, time(11, 30))
        XCTAssertEqual(repository.openTasks[0].calendarEventIdentifier, identifier)
        XCTAssertEqual(writer.upserts.count, 2)
        XCTAssertEqual(writer.upserts[1].existingIdentifier, identifier)
        XCTAssertEqual(writer.upserts[1].start, time(11))
        XCTAssertEqual(writer.upserts[1].end, time(11, 30))
        XCTAssertEqual(writer.deletedIdentifiers, [])
    }

    @MainActor
    func testManualRescheduleRefusesOverlapWithoutMovingTheOtherTask() async {
        let writer = MemoryTaskCalendarWriter()
        let repository = TaskRepository(store: MemoryTaskStore())
        let first = ScedraTask(title: "Essay", estimatedDurationMinutes: 30)
        await repository.placeAndSave(first, writer: writer, busy: [], now: time(14, 30), scheduler: scheduler)
        let placedFirst = repository.openTasks[0]
        XCTAssertEqual(placedFirst.scheduledStart, time(15))

        var second = ScedraTask(title: "Homework", estimatedDurationMinutes: 30)
        second.applyPlacement(start: time(16))
        await repository.placeAndSave(
            second,
            writer: writer,
            busy: [
                TaskBusyBlock(
                    start: time(15),
                    end: time(15, 30),
                    kind: .focusedWork,
                    title: "Essay",
                    isExclusiveTaskPlacement: true,
                    isTaskPlacement: true
                ),
            ],
            now: time(14, 30),
            scheduler: scheduler,
            honorSchedule: true
        )
        let placedSecond = repository.openTasks.first { $0.title == "Homework" }!
        XCTAssertEqual(placedSecond.scheduledStart, time(16))

        await repository.rescheduleAndSave(
            placedSecond,
            start: time(15),
            writer: writer,
            busy: [
                TaskBusyBlock(
                    start: time(15),
                    end: time(15, 30),
                    kind: .focusedWork,
                    title: "Essay",
                    isExclusiveTaskPlacement: true,
                    isTaskPlacement: true
                ),
            ],
            now: time(14, 30),
            scheduler: scheduler
        )

        XCTAssertEqual(repository.openTasks.first { $0.title == "Essay" }?.scheduledStart, time(15))
        XCTAssertEqual(repository.openTasks.first { $0.title == "Homework" }?.scheduledStart, time(16))
        XCTAssertFalse(writer.upserts.contains { $0.title == "Homework" && $0.start == time(15) })
    }

    @MainActor
    func testClearingASlotDoesNotInventThreeAM() async {
        let writer = MemoryTaskCalendarWriter()
        let repository = TaskRepository(store: MemoryTaskStore())
        let task = ScedraTask(title: "Homework", estimatedDurationMinutes: 30)
        await repository.placeAndSave(task, writer: writer, busy: [], now: time(9), scheduler: scheduler)
        let placed = repository.openTasks[0]

        await repository.rescheduleAndSave(
            placed,
            start: nil,
            writer: writer,
            busy: [],
            now: time(23),
            scheduler: scheduler
        )

        XCTAssertEqual(repository.openTasks[0].scheduledStart, nextDay(8))
        XCTAssertNotEqual(repository.openTasks[0].scheduledStart, time(3))
        XCTAssertEqual(writer.upserts.last?.existingIdentifier, placed.calendarEventIdentifier)
    }

    @MainActor
    func testDeleteRemovesLinkedCalendarEventOnly() async {
        let writer = MemoryTaskCalendarWriter()
        let repository = TaskRepository(store: MemoryTaskStore())
        let task = ScedraTask(title: "Call dentist", estimatedDurationMinutes: 30)
        await repository.placeAndSave(task, writer: writer, busy: [], now: time(9), scheduler: scheduler)
        let placed = repository.openTasks[0]
        await repository.delete(placed, from: writer)
        XCTAssertEqual(writer.deletedIdentifiers, [placed.calendarEventIdentifier ?? ""])
        XCTAssertTrue(repository.tasks.isEmpty)
    }

    @MainActor
    func testImportantTaskBumpsANormalTaskOffTheNextSlot() async throws {
        let writer = MemoryTaskCalendarWriter()
        let repository = TaskRepository(store: MemoryTaskStore())
        let meeting = TaskBusyBlock(
            start: time(16),
            end: time(17),
            kind: .meeting,
            title: "Standup"
        )
        let normal = ScedraTask(title: "Homework", estimatedDurationMinutes: 30, importance: .normal)
        await repository.placeAndSave(
            normal,
            writer: writer,
            busy: [meeting],
            now: time(9),
            scheduler: scheduler
        )
        let placedNormal = repository.openTasks[0]
        XCTAssertEqual(placedNormal.scheduledStart, time(9, 30))

        let important = ScedraTask(title: "Call dentist", estimatedDurationMinutes: 30, importance: .important)
        await repository.placeAndSave(
            important,
            writer: writer,
            busy: [meeting],
            now: time(9),
            scheduler: scheduler
        )

        let call = try XCTUnwrap(repository.openTasks.first { $0.title == "Call dentist" })
        let homework = try XCTUnwrap(repository.openTasks.first { $0.title == "Homework" })
        XCTAssertEqual(call.scheduledStart, time(9, 30), "important takes the next good slot")
        XCTAssertEqual(homework.scheduledStart, time(10, 10), "normal is re-placed later")
        XCTAssertNotEqual(homework.scheduledStart, time(16), "do not displace onto a meeting")
        XCTAssertLessThan(homework.scheduledEnd ?? time(20), time(16))
        XCTAssertEqual(meeting.start, time(16), "calendar appointments never move")
    }

    func testImportantTakesAnEarlierSlotHeldByANormalTask() throws {
        var homework = ScedraTask(title: "Homework", estimatedDurationMinutes: 30, importance: .normal)
        homework.applyPlacement(start: time(9, 30))
        var call = ScedraTask(title: "Call dentist", estimatedDurationMinutes: 30, importance: .important)
        call.applyPlacement(start: time(11))
        let meeting = TaskBusyBlock(
            start: time(16),
            end: time(17),
            kind: .meeting,
            title: "Standup"
        )

        let result = TaskPlacement.schedulePrioritized(
            [homework, call],
            calendarBusy: [meeting],
            now: time(9),
            scheduler: scheduler
        )
        let placedCall = try XCTUnwrap(result.first { $0.title == "Call dentist" })
        let placedHomework = try XCTUnwrap(result.first { $0.title == "Homework" })
        XCTAssertEqual(placedCall.scheduledStart, time(9, 30), "important wins the earlier slot")
        XCTAssertEqual(placedHomework.scheduledStart, time(10, 10), "normal is re-placed later")
        XCTAssertEqual(meeting.start, time(16), "calendar appointments never move")
    }

    func testCloserDeadlineTakesTheEarlierSlotAmongSameImportance() throws {
        var later = ScedraTask(title: "Later", estimatedDurationMinutes: 30, deadline: time(18))
        later.applyPlacement(start: time(9, 30))
        let sooner = ScedraTask(title: "Sooner", estimatedDurationMinutes: 30, deadline: time(12))

        let result = TaskPlacement.schedulePrioritized(
            [later, sooner],
            calendarBusy: [],
            now: time(9),
            scheduler: scheduler
        )
        XCTAssertEqual(result.first { $0.title == "Sooner" }?.scheduledStart, time(9, 30))
        XCTAssertEqual(result.first { $0.title == "Later" }?.scheduledStart, time(10, 10))
    }

    @MainActor
    func testReconcilePlacementsRunsPriorityBumpForAnImportantTask() async throws {
        let writer = MemoryTaskCalendarWriter()
        let repository = TaskRepository(store: MemoryTaskStore())
        let meeting = TaskBusyBlock(
            start: time(16),
            end: time(17),
            kind: .meeting,
            title: "Standup"
        )
        var homework = ScedraTask(title: "Homework", estimatedDurationMinutes: 30)
        homework.applyPlacement(start: time(9, 30))
        repository.upsert(homework)
        var call = ScedraTask(title: "Call dentist", estimatedDurationMinutes: 30, importance: .important)
        call.applyPlacement(start: time(11))
        repository.upsert(call)

        await repository.reconcilePlacements(
            writer: writer,
            busy: [meeting],
            now: time(9),
            scheduler: scheduler
        )

        let placedCall = try XCTUnwrap(repository.openTasks.first { $0.title == "Call dentist" })
        let placedHomework = try XCTUnwrap(repository.openTasks.first { $0.title == "Homework" })
        XCTAssertEqual(placedCall.scheduledStart, time(9, 30), "reconcile is not a stub — important takes the slot")
        XCTAssertEqual(placedHomework.scheduledStart, time(10, 10))
        XCTAssertNotEqual(placedHomework.scheduledStart, time(16))
        XCTAssertEqual(meeting.start, time(16))
        XCTAssertTrue(writer.upserts.contains { $0.title == "Call dentist" && $0.start == time(9, 30) })
        XCTAssertTrue(writer.upserts.contains { $0.title == "Homework" && $0.start == time(10, 10) })
    }

    // MARK: - Occupancy from calendar items (real placeAndSave wiring)

    func testOccupancyFromCalendarItemsMarksAppointmentsNotTasks() {
        let dentist = TodayItem(
            id: "ek-dentist",
            title: "Dentist",
            start: time(10),
            end: time(11),
            isAllDay: false,
            location: "Clinic"
        )
        let homework = ScedraTask(title: "Homework", estimatedDurationMinutes: 30)
        let busy = TaskAvailability.occupancy(
            calendarItems: [dentist],
            tasks: [],
            excluding: homework
        )
        XCTAssertEqual(busy.count, 1)
        XCTAssertEqual(busy[0].title, "Dentist")
        XCTAssertEqual(busy[0].kind, .focusedWork, "a normal appointment is never a drive/walk host")
        XCTAssertFalse(busy[0].isTaskPlacement)
        XCTAssertEqual(
            TaskAvailability.evaluatePlacement(task: homework, start: time(10), busy: busy),
            .doesNotFit
        )
        XCTAssertEqual(
            TaskAvailability.evaluatePlacement(task: homework, start: time(11), busy: busy),
            .doesNotFit,
            "10-minute buffer after the appointment"
        )
    }

    func testOverlapChipsDoNotSitOnANormalAppointment() {
        let dentist = TodayItem(
            id: "ek-dentist",
            title: "Dentist",
            start: time(10),
            end: time(11),
            isAllDay: false,
            location: "Clinic"
        )
        let call = ScedraTask(
            title: "Call dentist",
            estimatedDurationMinutes: 10,
            allowedOverlaps: [.driving, .walking, .waiting, .transit]
        )
        let busy = TaskAvailability.occupancy(
            calendarItems: [dentist],
            tasks: [],
            excluding: call
        )
        XCTAssertEqual(
            TaskAvailability.evaluatePlacement(task: call, start: time(10), busy: busy),
            .doesNotFit,
            "driving chips may sit on a commute, not on a dentist appointment"
        )
    }

    func testOccupancyKeepsOtherPlacedTasksAsOccupants() {
        var homework = ScedraTask(title: "Homework", estimatedDurationMinutes: 30)
        homework.applyPlacement(start: time(9, 30))
        homework.calendarEventIdentifier = "ek-homework"
        let important = ScedraTask(title: "Call dentist", estimatedDurationMinutes: 30, importance: .important)
        let standup = TodayItem(
            id: "ek-standup",
            title: "Standup",
            start: time(16),
            end: time(17),
            isAllDay: false,
            location: nil
        )
        let homeworkEvent = TodayItem(
            id: "ek-homework",
            title: "Homework",
            start: time(9, 30),
            end: time(10),
            isAllDay: false,
            location: nil
        )
        let busy = TaskAvailability.occupancy(
            calendarItems: [standup, homeworkEvent],
            tasks: [homework],
            excluding: important
        )
        XCTAssertTrue(busy.contains { $0.title == "Standup" && !$0.isTaskPlacement })
        XCTAssertTrue(
            busy.contains { $0.title == "Homework" && $0.isTaskPlacement },
            "other Scedra tasks stay occupants after their EventKit row is stripped"
        )
        XCTAssertFalse(
            busy.contains { $0.title == "Homework" && !$0.isTaskPlacement },
            "the task's own EventKit row must not also count as a calendar appointment"
        )
    }

    @MainActor
    func testPlaceAndSaveUsesOccupancySoExclusiveTaskMissesTheAppointment() async {
        let writer = MemoryTaskCalendarWriter()
        let repository = TaskRepository(store: MemoryTaskStore())
        let dentist = TodayItem(
            id: "ek-dentist",
            title: "Dentist",
            start: time(10),
            end: time(11),
            isAllDay: false,
            location: "Clinic"
        )
        let homework = ScedraTask(title: "Homework", estimatedDurationMinutes: 30)
        let busy = TaskAvailability.occupancy(
            calendarItems: [dentist],
            tasks: repository.tasks,
            excluding: homework
        )
        await repository.placeAndSave(
            homework,
            writer: writer,
            busy: busy,
            now: time(9),
            scheduler: scheduler
        )
        XCTAssertEqual(
            repository.openTasks[0].scheduledStart,
            time(11, 10),
            "placeAndSave must keep the 10-minute buffer after the EventKit event"
        )
        XCTAssertNotEqual(repository.openTasks[0].scheduledStart, time(9, 30))
        XCTAssertEqual(dentist.start, time(10), "calendar appointments never move")
    }

    @MainActor
    func testPlaceAndSaveOccupancyBumpsNormalTaskOffTheEarlierSlot() async throws {
        let writer = MemoryTaskCalendarWriter()
        let repository = TaskRepository(store: MemoryTaskStore())
        let standup = TodayItem(
            id: "ek-standup",
            title: "Standup",
            start: time(16),
            end: time(17),
            isAllDay: false,
            location: nil
        )
        let meetingBusy = TaskAvailability.occupancy(
            calendarItems: [standup],
            tasks: [],
            excluding: ScedraTask(title: "Homework", estimatedDurationMinutes: 30)
        )
        await repository.placeAndSave(
            ScedraTask(title: "Homework", estimatedDurationMinutes: 30, importance: .normal),
            writer: writer,
            busy: meetingBusy,
            now: time(9),
            scheduler: scheduler
        )
        XCTAssertEqual(repository.openTasks[0].scheduledStart, time(9, 30))

        let important = ScedraTask(title: "Call dentist", estimatedDurationMinutes: 30, importance: .important)
        let busy = TaskAvailability.occupancy(
            calendarItems: [standup],
            tasks: repository.tasks,
            excluding: important
        )
        XCTAssertTrue(busy.contains { $0.isTaskPlacement && $0.title == "Homework" })
        await repository.placeAndSave(
            important,
            writer: writer,
            busy: busy,
            now: time(9),
            scheduler: scheduler
        )

        let call = try XCTUnwrap(repository.openTasks.first { $0.title == "Call dentist" })
        let homework = try XCTUnwrap(repository.openTasks.first { $0.title == "Homework" })
        XCTAssertEqual(call.scheduledStart, time(9, 30), "important takes the next good slot")
        XCTAssertEqual(homework.scheduledStart, time(10, 10), "normal is re-placed later")
        XCTAssertNotEqual(homework.scheduledStart, time(16), "do not displace onto a meeting")
        XCTAssertEqual(standup.start, time(16), "calendar appointments never move")
    }

    @MainActor
    func testHonoredImportantSaveStillTakesTheEarlierSlot() async throws {
        let writer = MemoryTaskCalendarWriter()
        let repository = TaskRepository(store: MemoryTaskStore())
        await repository.placeAndSave(
            ScedraTask(title: "Homework", estimatedDurationMinutes: 30),
            writer: writer,
            busy: [],
            now: time(9),
            scheduler: scheduler
        )
        var call = ScedraTask(title: "Call dentist", estimatedDurationMinutes: 30, importance: .important)
        call.applyPlacement(start: time(11))
        await repository.placeAndSave(
            call,
            writer: writer,
            busy: TaskAvailability.occupancy(
                calendarItems: [],
                tasks: repository.tasks,
                excluding: call
            ),
            now: time(9),
            scheduler: scheduler,
            honorSchedule: true
        )
        XCTAssertEqual(
            repository.openTasks.first { $0.title == "Call dentist" }?.scheduledStart,
            time(9, 30)
        )
        XCTAssertEqual(
            repository.openTasks.first { $0.title == "Homework" }?.scheduledStart,
            time(10, 10)
        )
    }

    // MARK: - Calendar event deletion removes the ScedraTask

    @MainActor
    func testDeletingCalendarIdRemovesTaskFromTheStore() {
        let repository = TaskRepository(store: MemoryTaskStore())
        var task = ScedraTask(title: "Call dentist", estimatedDurationMinutes: 10)
        task.calendarEventIdentifier = "ek-task-1"
        repository.upsert(task)
        var completed = ScedraTask(title: "Done", estimatedDurationMinutes: 10, isCompleted: true)
        completed.calendarEventIdentifier = "ek-task-done"
        completed.completedAt = time(9)
        repository.upsert(completed)
        var other = ScedraTask(title: "Homework", estimatedDurationMinutes: 30)
        other.calendarEventIdentifier = "ek-task-2"
        repository.upsert(other)
        let appointmentless = ScedraTask(title: "Unscheduled")
        repository.upsert(appointmentless)

        repository.removeMatchingCalendarEvents(["ek-task-1", "ek-task-done"])

        XCTAssertNil(repository.tasks.first { $0.calendarEventIdentifier == "ek-task-1" })
        XCTAssertNil(repository.tasks.first { $0.title == "Call dentist" })
        XCTAssertNil(repository.tasks.first { $0.title == "Done" }, "completed list is cleared too")
        XCTAssertEqual(repository.tasks.first { $0.title == "Homework" }?.calendarEventIdentifier, "ek-task-2")
        XCTAssertNotNil(repository.tasks.first { $0.title == "Unscheduled" })
    }

    @MainActor
    func testMissingCalendarEventRemovesOnlyMatchingTasks() {
        let repository = TaskRepository(store: MemoryTaskStore())
        var task = ScedraTask(title: "Call dentist")
        task.calendarEventIdentifier = "ek-task-1"
        repository.upsert(task)
        var leftover = ScedraTask(title: "Homework")
        leftover.calendarEventIdentifier = "ek-task-2"
        repository.upsert(leftover)

        repository.removeTasksMissingFromCalendar { id in
            if id == "ek-task-1" { return false }
            if id == "ek-task-2" { return true }
            return nil
        }

        XCTAssertNil(repository.tasks.first { $0.title == "Call dentist" })
        XCTAssertEqual(repository.tasks.first { $0.title == "Homework" }?.calendarEventIdentifier, "ek-task-2")
    }

    func testNewTaskEditorHidesCompletedToggle() {
        let draft = ScedraTask(title: "Call dentist", estimatedDurationMinutes: 10)
        XCTAssertTrue(TaskEditorSession.create(draft).isNew)
        XCTAssertFalse(TaskEditorSession.create(draft).showsCompletedToggle)
        XCTAssertFalse(TaskEditorSession.edit(draft).isNew)
        XCTAssertTrue(TaskEditorSession.edit(draft).showsCompletedToggle)
    }
}
