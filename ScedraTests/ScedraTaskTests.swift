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

    // MARK: - Auto-complete + retain

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
    }

    @MainActor
    func testRepositoryAutoCompletesElapsedPlacement() {
        let repository = TaskRepository(store: MemoryTaskStore())
        var task = ScedraTask(title: "Call dentist", estimatedDurationMinutes: 10)
        task.applyPlacement(start: time(8))
        repository.upsert(task)
        repository.reconcile(now: time(12))

        XCTAssertTrue(repository.openTasks.isEmpty)
        XCTAssertEqual(repository.completedTasks(at: time(12)).count, 1)
        XCTAssertTrue(repository.completedTasks(at: time(12))[0].isCompleted)
        XCTAssertEqual(repository.completedTasks(at: time(12))[0].scheduledStart, time(8))
    }

    @MainActor
    func testRecentlyCompletedTaskStaysVisible() {
        let repository = TaskRepository(store: MemoryTaskStore())
        let now = Date()
        var task = ScedraTask(title: "Call dentist", estimatedDurationMinutes: 10)
        task.applyPlacement(start: now.addingTimeInterval(-20 * 60))
        repository.upsert(task)
        repository.setCompleted(repository.tasks[0], isCompleted: true, at: now)

        XCTAssertEqual(repository.completedTasks(at: now).count, 1)
        XCTAssertEqual(repository.completedTasks(at: now.addingTimeInterval(2 * 60 * 60)).count, 1)
    }

    @MainActor
    func testCompletedTaskOlderThanRetainWindowIsPruned() {
        XCTAssertEqual(TaskRetention.completedVisibleFor, 24 * 60 * 60)
        let old = ScedraTask(
            title: "Stale",
            isCompleted: true,
            completedAt: Date().addingTimeInterval(-25 * 60 * 60)
        )
        let stored = MemoryTaskStore(tasks: [old])
        let loaded = TaskRepository(store: stored)
        XCTAssertTrue(loaded.completedTasks.isEmpty)
        XCTAssertTrue(loaded.tasks.isEmpty)
        XCTAssertTrue(stored.load().isEmpty, "pruned rows are dropped from persistence")
    }

    @MainActor
    func testManualCompleteStartsRetainWindow() {
        let repository = TaskRepository(store: MemoryTaskStore())
        let now = Date()
        repository.upsert(ScedraTask(title: "Call dentist", estimatedDurationMinutes: 10))
        repository.setCompleted(repository.openTasks[0], isCompleted: true, at: now)
        XCTAssertEqual(repository.completedTasks(at: now).first?.completedAt, now)
        XCTAssertTrue(repository.completedTasks(at: now.addingTimeInterval(25 * 60 * 60)).isEmpty)
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
    func testCompletingATaskDoesNotDeleteCalendarEvent() async {
        let writer = MemoryTaskCalendarWriter()
        let repository = TaskRepository(store: MemoryTaskStore())
        let task = ScedraTask(title: "Call dentist", estimatedDurationMinutes: 30)
        await repository.placeAndSave(task, writer: writer, busy: [], now: time(9), scheduler: scheduler)
        let placed = repository.openTasks[0]
        XCTAssertEqual(placed.calendarEventIdentifier, writer.upserts[0].identifier)

        repository.setCompleted(placed, isCompleted: true, at: time(9, 5))

        XCTAssertTrue(writer.deletedIdentifiers.isEmpty, "checking a task off leaves the calendar block")
        XCTAssertEqual(
            repository.completedTasks(at: time(9, 5)).first?.calendarEventIdentifier,
            placed.calendarEventIdentifier
        )
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
}
