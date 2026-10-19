import CoreLocation
import MapKit
import XCTest
@testable import Scedra

final class ScedraDriveTimeTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private lazy var day: Date = calendar.date(
        from: DateComponents(year: 2026, month: 6, day: 10)
    )!

    private func time(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    private var dentistTravel: TravelEstimate {
        TravelEstimator.estimate(
            minutes: 25,
            mode: .drive,
            start: time(10),
            bufferMinutes: 5,
            returnMinutes: 20
        )
    }

    func testDefaultDriveTimePlacementIsPartOfEvent() {
        XCTAssertEqual(DriveTimePlacement.partOfEvent.rawValue, "partOfEvent")
        XCTAssertEqual(UserProfile.driveTimePlacementKey, "scedra.driveTimePlacement")
        let defaults = UserDefaults(suiteName: "scedra.driveTime.default")!
        defaults.removePersistentDomain(forName: "scedra.driveTime.default")
        XCTAssertEqual(DriveTimePlacement.resolved(defaults: defaults), .partOfEvent)
    }

    func testPartOfEventPadsInboundOnlyAndWritesDriveHomeAfter() throws {
        let plan = DriveTimeLogic.plan(
            officialStart: time(10),
            officialEnd: time(11),
            travel: dentistTravel,
            extraBeforeMinutes: 0,
            extraAfterMinutes: 0,
            place: "Clinic",
            appointmentTitle: "Dentist",
            placement: .partOfEvent,
            neighbors: DriveNeighborContext(
                onwardPlace: "12 Home Lane",
                onwardMinutes: 20,
                onwardGoesHome: true
            )
        )
        XCTAssertTrue(plan.isAppointmentPadded)
        XCTAssertEqual(plan.appointmentStart, time(9, 30), "leave-by = start − 25 − 5 buffer")
        XCTAssertEqual(plan.appointmentEnd, time(11), "return is not absorbed into the appointment")
        XCTAssertNil(plan.driveEvent, "inbound stays on the appointment when Settings is part-of-event")
        XCTAssertNil(plan.removeDriveEventIdentifier)
        let back = try XCTUnwrap(plan.returnDriveEvent, "Confirm still writes Drive home after")
        XCTAssertEqual(back.start, time(11))
        XCTAssertEqual(back.end, time(11, 20))
        XCTAssertEqual(back.title, ScedraString("Drive home"))
        XCTAssertEqual(back.location, "12 Home Lane")
        XCTAssertEqual(back.leg, .onward)

        let notes = TravelEstimator.noteLines(
            appointmentStart: time(10),
            appointmentEnd: time(11),
            travel: dentistTravel,
            place: "Clinic"
        )
        XCTAssertTrue(notes[0].hasPrefix("Appointment: "))
        XCTAssertTrue(notes.contains { $0.hasPrefix("Leave by ") })
    }

    func testSeparateEventKeepsOfficialTimesAndAddsDriveToAndDriveHome() throws {
        let plan = DriveTimeLogic.plan(
            officialStart: time(10),
            officialEnd: time(11),
            travel: dentistTravel,
            place: "Clinic",
            appointmentTitle: "Dentist",
            placement: .separateEvent,
            neighbors: DriveNeighborContext(
                onwardPlace: "12 Home Lane",
                onwardMinutes: 20,
                onwardGoesHome: true
            )
        )
        XCTAssertFalse(plan.isAppointmentPadded)
        XCTAssertEqual(plan.appointmentStart, time(10))
        XCTAssertEqual(plan.appointmentEnd, time(11))
        XCTAssertEqual(plan.driveEvent?.start, time(9, 30))
        XCTAssertEqual(plan.driveEvent?.end, time(10))
        XCTAssertEqual(plan.driveEvent?.title, ScedraString("Drive to Dentist"))
        XCTAssertEqual(plan.driveEvent?.location, "Clinic")
        XCTAssertNil(plan.driveEvent?.existingIdentifier)
        XCTAssertNil(plan.removeDriveEventIdentifier)
        let back = try XCTUnwrap(plan.returnDriveEvent)
        XCTAssertEqual(back.start, time(11))
        XCTAssertEqual(back.end, time(11, 20))
        XCTAssertEqual(back.title, ScedraString("Drive home"))
        XCTAssertEqual(back.leg, .onward)
    }

    func testExistingCalendarEventGetsDriveAboveAndBelow() {
        let plan = DriveTimeLogic.plan(
            officialStart: time(10),
            officialEnd: time(11),
            travel: dentistTravel,
            place: "Clinic",
            appointmentTitle: "Dentist",
            placement: .partOfEvent,
            source: .existingCalendarEvent,
            neighbors: DriveNeighborContext(
                onwardPlace: "12 Home Lane",
                onwardMinutes: 20,
                onwardGoesHome: true
            )
        )
        XCTAssertFalse(plan.isAppointmentPadded, "existing events keep official times")
        XCTAssertEqual(plan.appointmentStart, time(10))
        XCTAssertEqual(plan.appointmentEnd, time(11))
        XCTAssertEqual(plan.driveEvent?.start, time(9, 30))
        XCTAssertEqual(plan.driveEvent?.end, time(10))
        XCTAssertEqual(plan.driveEvent?.title, ScedraString("Drive to Dentist"))
        XCTAssertEqual(plan.driveEvent?.leg, .inbound)
        XCTAssertEqual(plan.returnDriveEvent?.start, time(11))
        XCTAssertEqual(plan.returnDriveEvent?.end, time(11, 20))
        XCTAssertEqual(plan.returnDriveEvent?.title, ScedraString("Drive home"))
        XCTAssertEqual(plan.returnDriveEvent?.location, "12 Home Lane")
        XCTAssertEqual(plan.returnDriveEvent?.leg, .onward)
        XCTAssertNil(plan.removeDriveEventIdentifier)
        XCTAssertNil(plan.removeReturnDriveEventIdentifier)
    }

    /// Backfill must not pad, shift, or lengthen the original EKEvent. Drive is two
    /// sibling events (before and after). Settings “part of the event” is ignored.
    func testExistingBackfillKeepsOriginalTimesAndAddsTwoSiblingEvents() throws {
        let originalStart = time(10)
        let originalEnd = time(11)
        let originalDuration = originalEnd.timeIntervalSince(originalStart)
        let item = TodayItem(
            id: "ek-apple-dentist",
            title: "Dentist",
            start: originalStart,
            end: originalEnd,
            isAllDay: false,
            location: "Clinic",
            notes: "Added in Apple Calendar"
        )
        XCTAssertEqual(DriveTimeLogic.source(for: item), .existingCalendarEvent)
        XCTAssertFalse(DriveTimeLogic.writesOriginalTimes(source: .existingCalendarEvent))

        let neighbors = DriveNeighborContext(
            onwardPlace: "12 Home Lane",
            onwardMinutes: 20,
            onwardGoesHome: true
        )
        let write = DriveTimeLogic.write(
            item: item,
            travel: dentistTravel,
            neighbors: neighbors,
            placement: .partOfEvent
        )

        XCTAssertFalse(write.writesOriginalTimes, "CalendarStore must not assign EKEvent start/end")
        XCTAssertEqual(write.eventStart, originalStart, "Apple Calendar start stays put")
        XCTAssertEqual(write.eventEnd, originalEnd, "Apple Calendar end stays put")
        XCTAssertEqual(
            write.eventEnd.timeIntervalSince(write.eventStart),
            originalDuration,
            "original duration must not change"
        )
        XCTAssertFalse(write.plan.isAppointmentPadded)
        XCTAssertEqual(write.plan.appointmentStart, originalStart)
        XCTAssertEqual(write.plan.appointmentEnd, originalEnd)

        let inbound = try XCTUnwrap(write.plan.driveEvent, "Drive to is its own EKEvent before the appointment")
        XCTAssertEqual(inbound.start, time(9, 30))
        XCTAssertEqual(inbound.end, originalStart)
        XCTAssertLessThan(inbound.start, write.eventStart)
        XCTAssertEqual(inbound.leg, .inbound)
        XCTAssertNil(inbound.existingIdentifier)

        let onward = try XCTUnwrap(write.plan.returnDriveEvent, "Drive home is its own EKEvent after the appointment")
        XCTAssertEqual(onward.start, originalEnd)
        XCTAssertEqual(onward.end, time(11, 20))
        XCTAssertGreaterThan(onward.end, write.eventEnd)
        XCTAssertEqual(onward.leg, .onward)
        XCTAssertNil(onward.existingIdentifier)

        XCTAssertTrue(write.notes.contains("Leave by"), "notes may mention leave-by")
        XCTAssertTrue(write.notes.contains("Appointment:"))
        XCTAssertFalse(write.notes.contains(EventNotes.marker))

        let again = DriveTimeLogic.write(
            item: TodayItem(
                id: item.id,
                title: item.title,
                start: originalStart,
                end: originalEnd,
                isAllDay: false,
                location: item.location,
                notes: write.notes
            ),
            travel: dentistTravel,
            neighbors: neighbors,
            placement: .partOfEvent,
            existingDriveEventIdentifier: "ek-drive-in",
            existingReturnDriveEventIdentifier: "ek-drive-out"
        )
        XCTAssertFalse(again.writesOriginalTimes)
        XCTAssertEqual(again.eventStart, originalStart)
        XCTAssertEqual(again.eventEnd, originalEnd)
        XCTAssertEqual(again.plan.driveEvent?.existingIdentifier, "ek-drive-in")
        XCTAssertEqual(again.plan.returnDriveEvent?.existingIdentifier, "ek-drive-out")
        XCTAssertNil(again.plan.removeDriveEventIdentifier)
        XCTAssertNil(again.plan.removeReturnDriveEventIdentifier)
        XCTAssertFalse(
            CalendarTravelBackfill.shouldEstimate(
                TodayItem(
                    id: item.id,
                    title: item.title,
                    start: originalStart,
                    end: originalEnd,
                    isAllDay: false,
                    location: item.location,
                    notes: write.notes
                )
            ),
            "refresh must not create a second pair of drive events"
        )
    }

    func testExistingBackfillDoesNotShiftEventKitTimesWhenNotesHaveOfficialWindow() {
        let window = TravelEstimator.appointmentWindow(from: time(10), to: time(11))
        let item = TodayItem(
            id: "ek-apple-legacy",
            title: "Dentist",
            start: time(9, 30),
            end: time(11, 20),
            isAllDay: false,
            location: "Clinic",
            notes: "Appointment: \(window)"
        )
        let write = DriveTimeLogic.write(
            item: item,
            travel: dentistTravel,
            neighbors: DriveNeighborContext(
                onwardPlace: "Home",
                onwardMinutes: 20,
                onwardGoesHome: true
            ),
            placement: .partOfEvent
        )
        XCTAssertFalse(write.writesOriginalTimes)
        XCTAssertEqual(write.eventStart, time(9, 30), "do not unpad or shift the Apple Calendar block")
        XCTAssertEqual(write.eventEnd, time(11, 20))
        XCTAssertEqual(write.eventEnd.timeIntervalSince(write.eventStart), 110 * 60)
    }

    /// Confirm / CalendarStore.save: Home is set, place is not Home → sibling after the appointment.
    func testConfirmStyleSaveWithHomeWritesDriveHomeAfterAppointment() throws {
        let plan = DriveTimeLogic.plan(
            officialStart: time(10),
            officialEnd: time(11),
            travel: dentistTravel,
            place: "Clinic",
            appointmentTitle: "Dentist",
            placement: .partOfEvent,
            source: .newScedraEvent,
            neighbors: DriveNeighborContext(
                onwardPlace: "12 Home Lane",
                onwardMinutes: 20,
                onwardGoesHome: true
            )
        )
        XCTAssertTrue(plan.isAppointmentPadded)
        XCTAssertEqual(plan.appointmentStart, time(9, 30), "inbound pad only")
        XCTAssertEqual(plan.appointmentEnd, time(11), "confirmed end stays; return is a sibling")
        XCTAssertNil(plan.driveEvent)
        let back = try XCTUnwrap(plan.returnDriveEvent, "CalendarStore.save must have a return to write")
        XCTAssertEqual(back.start, plan.appointmentEnd)
        XCTAssertGreaterThan(back.end, plan.appointmentEnd)
        XCTAssertEqual(back.title, ScedraString("Drive home"))
        XCTAssertEqual(back.leg, .onward)
        XCTAssertNil(back.existingIdentifier)
    }

    func testConfirmStyleSaveWithoutHomeWritesDriveFromPlace() throws {
        let plan = DriveTimeLogic.plan(
            officialStart: time(10),
            officialEnd: time(11),
            travel: dentistTravel,
            place: "Clinic",
            appointmentTitle: "Dentist",
            placement: .partOfEvent,
            source: .newScedraEvent
        )
        let back = try XCTUnwrap(plan.returnDriveEvent)
        XCTAssertEqual(back.title, ScedraString("Drive from Clinic"))
        XCTAssertEqual(back.start, time(11))
        XCTAssertEqual(back.end, time(11, 20), "Maps return minutes, not a guessed hour")
    }

    func testConfirmStyleSaveSkipsReturnWhenAlreadyHome() {
        let plan = DriveTimeLogic.plan(
            officialStart: time(10),
            officialEnd: time(11),
            travel: dentistTravel,
            place: "Home",
            appointmentTitle: "Lunch",
            placement: .partOfEvent,
            source: .newScedraEvent,
            neighbors: DriveNeighborContext(
                onwardPlace: "Home",
                onwardMinutes: 15,
                onwardGoesHome: true
            )
        )
        XCTAssertNil(plan.returnDriveEvent, "already home — nowhere to drive back to")
        XCTAssertEqual(plan.appointmentEnd, time(11))
    }

    func testExistingBackfillReusesLinkedIdentifiers() {
        let neighbors = DriveNeighborContext(
            onwardPlace: "Home",
            onwardMinutes: 20,
            onwardGoesHome: true
        )
        let first = DriveTimeLogic.plan(
            officialStart: time(10),
            officialEnd: time(11),
            travel: dentistTravel,
            place: "Clinic",
            appointmentTitle: "Dentist",
            placement: .separateEvent,
            source: .existingCalendarEvent,
            neighbors: neighbors
        )
        XCTAssertNil(first.driveEvent?.existingIdentifier)
        XCTAssertNil(first.returnDriveEvent?.existingIdentifier)

        let second = DriveTimeLogic.plan(
            officialStart: time(10),
            officialEnd: time(11),
            travel: dentistTravel,
            place: "Clinic",
            appointmentTitle: "Dentist",
            placement: .separateEvent,
            existingDriveEventIdentifier: "ek-drive-in",
            existingReturnDriveEventIdentifier: "ek-drive-out",
            source: .existingCalendarEvent,
            neighbors: neighbors
        )
        XCTAssertEqual(second.driveEvent?.existingIdentifier, "ek-drive-in")
        XCTAssertEqual(second.returnDriveEvent?.existingIdentifier, "ek-drive-out")
        XCTAssertEqual(second.driveEvent?.start, first.driveEvent?.start)
        XCTAssertEqual(second.returnDriveEvent?.end, first.returnDriveEvent?.end)
        XCTAssertNil(second.removeDriveEventIdentifier)
        XCTAssertNil(second.removeReturnDriveEventIdentifier)
        XCTAssertEqual(second.driveEvent?.start, time(9, 30))
        XCTAssertEqual(second.returnDriveEvent?.start, time(11))
    }

    func testExistingEventWithDriveLineIsNotEstimatedAgain() {
        let item = TodayItem(
            id: "apple-dentist",
            title: "Dentist",
            start: time(10),
            end: time(11),
            isAllDay: false,
            location: "Clinic",
            notes: "Drive: ~25 min there, ~20 min back (~45 min round trip)"
        )
        XCTAssertFalse(item.savedInfo.isScedraEvent)
        XCTAssertNotNil(item.savedInfo.driveLine)
        XCTAssertFalse(
            CalendarTravelBackfill.shouldEstimate(item),
            "second backfill pass must not create another pair of travel events"
        )
        XCTAssertTrue(
            CalendarTravelBackfill.needsTravelRetry(item, hasDriveSibling: false),
            "notes must not skip a day chain retry when the pin or sibling is still missing"
        )
        XCTAssertEqual(CalendarTravelBackfill.timedAppointments([item]).map(\.id), [item.id])
    }

    func testDestinationQueryUsesStreetAfterDotAndNotesAddress() {
        let dotted = TodayItem(
            id: "ek-barn",
            title: "Horse show",
            start: time(10),
            end: time(11),
            isAllDay: false,
            location: "Westwind Community Barn · 27210 Altamont Rd, Los Altos Hills"
        )
        XCTAssertEqual(
            CalendarTravelBackfill.destinationQuery(for: dotted),
            "Westwind Community Barn · 27210 Altamont Rd, Los Altos Hills"
        )

        let notesOnly = TodayItem(
            id: "ek-notes",
            title: "Lesson",
            start: time(10),
            end: time(11),
            isAllDay: false,
            location: nil,
            notes: "27210 Altamont Rd, Los Altos Hills"
        )
        XCTAssertEqual(
            CalendarTravelBackfill.destinationQuery(for: notesOnly),
            "27210 Altamont Rd, Los Altos Hills"
        )

        let namePlusNotes = TodayItem(
            id: "ek-name-notes",
            title: "Lesson",
            start: time(10),
            end: time(11),
            isAllDay: false,
            location: "Westwind Community Barn",
            notes: "27210 Altamont Rd, Los Altos Hills"
        )
        XCTAssertEqual(
            CalendarTravelBackfill.destinationQuery(for: namePlusNotes),
            "Westwind Community Barn · 27210 Altamont Rd, Los Altos Hills"
        )
    }

    func testRetryPrefersEventsWithoutDriveSibling() {
        let withSibling = TodayItem(
            id: "ek-clinic",
            title: "Dentist",
            start: time(10),
            end: time(11),
            isAllDay: false,
            location: "Clinic",
            latitude: 37.43,
            longitude: -122.17
        )
        let missing = TodayItem(
            id: "ek-barn",
            title: "Horse show",
            start: time(14),
            end: time(16),
            isAllDay: false,
            location: "Westwind Community Barn · 27210 Altamont Rd, Los Altos Hills"
        )
        XCTAssertEqual(
            CalendarTravelBackfill.prioritizedForRetry(
                [withSibling, missing],
                siblingIDs: ["ek-clinic"]
            ).map(\.id),
            ["ek-barn", "ek-clinic"]
        )
        XCTAssertTrue(CalendarTravelBackfill.needsTravelRetry(missing, hasDriveSibling: false))
        XCTAssertFalse(CalendarTravelBackfill.needsTravelRetry(withSibling, hasDriveSibling: true))
    }

    func testLiveDirectionsBudgetSkipsWhenEmptyAndCacheIsFree() async {
        TravelEstimator.resetMinutesCache()
        defer { TravelEstimator.resetMinutesCache() }
        let origin = CLLocationCoordinate2D(latitude: 37.3318, longitude: -122.0312)
        let destination = CLLocationCoordinate2D(latitude: 37.4419, longitude: -122.1430)
        let depart = time(15)
        var empty = 0
        let skipped = await CalendarTravelBackfill.mapsMinutesIfBudgeted(
            from: origin,
            to: destination,
            departingAt: depart,
            transportType: .automobile,
            budget: &empty
        )
        XCTAssertNil(skipped)
        XCTAssertEqual(empty, 0)

        TravelEstimator.rememberMinutes(
            from: origin,
            to: destination,
            departingAt: depart,
            transportType: .automobile,
            minutes: 12
        )
        var budget = 1
        let cached = await CalendarTravelBackfill.mapsMinutesIfBudgeted(
            from: origin,
            to: destination,
            departingAt: depart,
            transportType: .automobile,
            budget: &budget
        )
        XCTAssertEqual(cached, 12)
        XCTAssertEqual(budget, 1, "cached minutes must not spend a live Directions slot")
    }

    func testExistingSkipsSamePlaceNeighborLegs() {
        let plan = DriveTimeLogic.plan(
            officialStart: time(10),
            officialEnd: time(11),
            travel: dentistTravel,
            place: "Clinic",
            appointmentTitle: "Dentist",
            placement: .separateEvent,
            existingDriveEventIdentifier: "ek-in",
            existingReturnDriveEventIdentifier: "ek-out",
            source: .existingCalendarEvent,
            neighbors: DriveNeighborContext(
                previousPlace: "Clinic · 1 Main St",
                onwardPlace: "Clinic",
                onwardMinutes: 8,
                onwardGoesHome: false
            )
        )
        XCTAssertNil(plan.driveEvent)
        XCTAssertNil(plan.returnDriveEvent)
        XCTAssertEqual(plan.removeDriveEventIdentifier, "ek-in")
        XCTAssertEqual(plan.removeReturnDriveEventIdentifier, "ek-out")
        XCTAssertEqual(plan.appointmentStart, time(10))
        XCTAssertEqual(plan.appointmentEnd, time(11))
    }

    func testExistingHomeReturnUsesTravelMinutesWhenOnwardMinutesMissing() throws {
        let plan = DriveTimeLogic.plan(
            officialStart: time(10),
            officialEnd: time(11),
            travel: dentistTravel,
            place: "Clinic",
            appointmentTitle: "Dentist",
            placement: .partOfEvent,
            source: .existingCalendarEvent,
            neighbors: DriveNeighborContext(
                onwardPlace: "12 Home Lane",
                onwardGoesHome: true
            )
        )
        XCTAssertEqual(plan.driveEvent?.end, time(10))
        let homeward = try XCTUnwrap(plan.returnDriveEvent, "nil/zero onward minutes must not skip Drive home")
        XCTAssertEqual(homeward.title, ScedraString("Drive home"))
        XCTAssertEqual(homeward.start, time(11))
        XCTAssertEqual(homeward.end, time(11, 20), "Maps return minutes, not a guessed hour")
        XCTAssertEqual(homeward.leg, .onward)
        XCTAssertEqual(plan.appointmentStart, time(10))
        XCTAssertEqual(plan.appointmentEnd, time(11))
    }

    func testExistingCreatesDriveFromWhenHomeAndNextAreMissing() throws {
        let plan = DriveTimeLogic.plan(
            officialStart: time(10),
            officialEnd: time(11),
            travel: dentistTravel,
            place: "Clinic",
            appointmentTitle: "Dentist",
            placement: .partOfEvent,
            source: .existingCalendarEvent
        )
        let back = try XCTUnwrap(plan.returnDriveEvent, "still create Drive from this place when Home and next are unknown")
        XCTAssertEqual(back.title, ScedraString("Drive from Clinic"))
        XCTAssertEqual(back.start, time(11))
        XCTAssertEqual(back.end, time(11, 20))
        XCTAssertEqual(back.leg, .onward)
        XCTAssertFalse(plan.isAppointmentPadded)
    }

    func testExistingSkipsOnwardOnlyWhenAlreadyHome() {
        let plan = DriveTimeLogic.plan(
            officialStart: time(10),
            officialEnd: time(11),
            travel: dentistTravel,
            place: "Home",
            appointmentTitle: "Lunch",
            placement: .partOfEvent,
            source: .existingCalendarEvent,
            neighbors: DriveNeighborContext(
                onwardPlace: "Home",
                onwardMinutes: 15,
                onwardGoesHome: true
            )
        )
        XCTAssertNil(plan.returnDriveEvent, "already home — nowhere to drive back to")
        XCTAssertEqual(plan.appointmentStart, time(10))
        XCTAssertEqual(plan.appointmentEnd, time(11))
    }

    func testExistingOnwardWithoutHomeUsesDriveFromNextOrigin() {
        let plan = DriveTimeLogic.plan(
            officialStart: time(10),
            officialEnd: time(11),
            travel: dentistTravel,
            place: "Clinic",
            appointmentTitle: "Dentist",
            placement: .partOfEvent,
            source: .existingCalendarEvent,
            neighbors: DriveNeighborContext(
                onwardPlace: "Library",
                onwardMinutes: 12,
                onwardGoesHome: false
            )
        )
        XCTAssertEqual(plan.returnDriveEvent?.title, ScedraString("Drive from Clinic"))
        XCTAssertEqual(plan.returnDriveEvent?.location, "Library")
        XCTAssertEqual(plan.returnDriveEvent?.start, time(11))
        XCTAssertEqual(plan.returnDriveEvent?.end, time(11, 12))
    }

    func testExistingTravelNotesDoNotAddScedraMarker() {
        let details = TravelEstimator.noteLines(
            appointmentStart: time(10),
            appointmentEnd: time(11),
            travel: dentistTravel,
            place: "Clinic"
        )
        let notes = EventNotes.travelDetails(
            existingNotes: "Added in Apple Calendar",
            details: details,
            place: "Clinic"
        )
        XCTAssertFalse(notes.contains(EventNotes.marker))
        XCTAssertTrue(notes.contains("Added in Apple Calendar"))
        XCTAssertNotNil(EventNotes.savedInfo(from: notes).driveLine)
        let again = EventNotes.travelDetails(
            existingNotes: notes,
            details: details,
            place: "Clinic"
        )
        XCTAssertEqual(
            again.components(separatedBy: "Added in Apple Calendar").count - 1,
            1,
            "refresh must not duplicate the original Apple Calendar notes"
        )
    }

    func testSourceTreatsAddedByScedraAsNewEvent() {
        let apple = TodayItem(
            id: "ek-apple",
            title: "Dentist",
            start: time(10),
            end: time(11),
            isAllDay: false,
            location: "Clinic",
            notes: "Added in Apple Calendar"
        )
        let scedra = TodayItem(
            id: "ek-scedra",
            title: "Dentist",
            start: time(10),
            end: time(11),
            isAllDay: false,
            location: "Clinic",
            notes: EventNotes.body(forOriginal: "dentist at 10")
        )
        XCTAssertEqual(DriveTimeLogic.source(for: apple), .existingCalendarEvent)
        XCTAssertEqual(DriveTimeLogic.source(for: scedra), .newScedraEvent)
    }

    func testSeparateSkipsZeroMinutesAndMissingPlace() {
        let zero = TravelEstimator.estimate(
            minutes: 0,
            mode: .drive,
            start: time(10),
            bufferMinutes: 5
        )
        let noMinutes = DriveTimeLogic.plan(
            officialStart: time(10),
            officialEnd: time(11),
            travel: zero,
            place: "Clinic",
            appointmentTitle: "Dentist",
            placement: .separateEvent
        )
        XCTAssertNil(noMinutes.driveEvent)
        XCTAssertEqual(noMinutes.appointmentStart, time(10))

        let noPlace = DriveTimeLogic.plan(
            officialStart: time(10),
            officialEnd: time(11),
            travel: dentistTravel,
            place: "  ",
            appointmentTitle: "Dentist",
            placement: .separateEvent
        )
        XCTAssertNil(noPlace.driveEvent)
        XCTAssertFalse(DriveTimeLogic.shouldCreateDriveEvent(travel: dentistTravel, place: ""))
    }

    func testSeparateUpdatesExistingDriveEventInsteadOfDuplicating() {
        let plan = DriveTimeLogic.plan(
            officialStart: time(10),
            officialEnd: time(11),
            travel: dentistTravel,
            place: "Clinic",
            appointmentTitle: "Dentist",
            placement: .separateEvent,
            existingDriveEventIdentifier: "ek-drive-1"
        )
        XCTAssertEqual(plan.driveEvent?.existingIdentifier, "ek-drive-1")
        XCTAssertNil(plan.removeDriveEventIdentifier)
        XCTAssertEqual(plan.driveEvent?.start, time(9, 30))
        XCTAssertEqual(plan.driveEvent?.end, time(10))
    }

    func testSwitchingToPartOfEventRemovesTheLinkedInboundDriveEvent() {
        let plan = DriveTimeLogic.plan(
            officialStart: time(10),
            officialEnd: time(11),
            travel: dentistTravel,
            place: "Clinic",
            appointmentTitle: "Dentist",
            placement: .partOfEvent,
            existingDriveEventIdentifier: "ek-drive-1"
        )
        XCTAssertTrue(plan.isAppointmentPadded)
        XCTAssertNil(plan.driveEvent)
        XCTAssertEqual(plan.removeDriveEventIdentifier, "ek-drive-1")
        XCTAssertNotNil(plan.returnDriveEvent, "Drive home stays a sibling after the appointment")
    }

    func testEventTimeChangeInSeparateModeKeepsOfficialTimes() throws {
        let window = TravelEstimator.appointmentWindow(from: time(18), to: time(21))
        let item = TodayItem(
            id: "ek-dinner",
            title: "Dinner",
            start: time(17, 35),
            end: time(21, 25),
            isAllDay: false,
            location: "Cafe",
            notes: EventNotes.body(
                forOriginal: "dinner 6-9",
                details: ["Appointment: \(window)"]
            )
        )
        let prepared = try EventScheduleEdit.prepare(
            item: item,
            officialStart: time(14),
            officialEnd: time(15),
            placement: .separateEvent
        )
        XCTAssertEqual(prepared.identifier, "ek-dinner")
        XCTAssertEqual(prepared.start, time(14), "separate mode does not copy travel padding onto the appointment")
        XCTAssertEqual(prepared.end, time(15))
    }

    func testExclusiveTaskTreatsSeparateDriveEventAsBusy() {
        let drive = TodayItem(
            id: "ek-drive-1",
            title: ScedraString("Drive to Clinic"),
            start: time(9, 30),
            end: time(10),
            isAllDay: false,
            location: "Clinic",
            notes: DriveTimeLogic.driveNotes(forAppointment: "ek-dentist")
        )
        XCTAssertTrue(drive.isDriveEvent)
        XCTAssertFalse(drive.showsDriveSection)
        XCTAssertFalse(drive.contributesToHomeGap)
        XCTAssertFalse(CalendarTravelBackfill.shouldEstimate(drive))

        let busy = TaskAvailability.busyBlocks(from: [drive])
        XCTAssertEqual(busy[0].kind, .driving)

        let homework = ScedraTask(
            title: "Finish chemistry homework",
            estimatedDurationMinutes: 45
        )
        XCTAssertEqual(
            TaskAvailability.evaluatePlacement(task: homework, start: time(9, 40), busy: busy),
            .doesNotFit,
            "exclusive tasks cannot sit on a separate drive event"
        )

        let call = ScedraTask(
            title: "Call dentist",
            estimatedDurationMinutes: 10,
            allowedOverlaps: [.driving]
        )
        XCTAssertEqual(
            TaskAvailability.evaluatePlacement(task: call, start: time(9, 40), busy: busy),
            .overlapOK
        )
    }

    func testDriveNotesLinkBackToTheAppointment() {
        let notes = DriveTimeLogic.driveNotes(forAppointment: "ek-dentist")
        XCTAssertTrue(notes.contains(DriveTimeLogic.driveMarker))
        XCTAssertEqual(DriveTimeLogic.appointmentIdentifier(fromDriveNotes: notes), "ek-dentist")
        XCTAssertEqual(DriveTimeLogic.driveLeg(fromNotes: notes), .inbound)
        XCTAssertTrue(DriveTimeLogic.isDriveEvent(title: "Dinner", notes: notes))
        XCTAssertFalse(DriveTimeLogic.isDriveEvent(title: "Dinner", notes: EventNotes.marker))
        XCTAssertTrue(DriveTimeLogic.isDriveEvent(title: ScedraString("Drive home"), notes: nil))
        let onward = DriveTimeLogic.driveNotes(forAppointment: "ek-dentist", leg: .onward)
        XCTAssertEqual(DriveTimeLogic.driveLeg(fromNotes: onward), .onward)
    }

    @MainActor
    func testBackfillFillAttachesReturnMinutesForHomewardLeg() async {
        let item = TodayItem(
            id: "ek-apple-dentist",
            title: "Dentist",
            start: time(10),
            end: time(11),
            isAllDay: false,
            location: "Clinic",
            notes: "Added in Apple Calendar",
            latitude: 37.43,
            longitude: -122.17
        )
        var written: DriveNeighborContext?
        await CalendarTravelBackfill.fill(
            item,
            origin: CLLocation(latitude: 37.44, longitude: -122.14),
            fromHome: true,
            mode: .drive,
            bufferMinutes: 5,
            neighbors: DriveNeighborContext(
                onwardPlace: "12 Home Lane",
                onwardGoesHome: true
            ),
            resolve: { _ in nil },
            estimate: { _, _, _, _, _, _, _, _ in self.dentistTravel },
            write: { _, _, _, _, neighbors in
                written = neighbors
            }
        )
        XCTAssertEqual(written?.onwardMinutes, 20)
        XCTAssertEqual(written?.onwardPlace, "12 Home Lane")
        XCTAssertEqual(written?.onwardGoesHome, true)
    }

    func testInboundTitleUsesAppointmentTitleNotResolvedPOI() {
        XCTAssertEqual(
            DriveTimeLogic.driveEventTitle(place: "PetSmart · 100 Showers Dr", appointmentTitle: "Boba"),
            ScedraString("Drive to Boba")
        )
        XCTAssertEqual(
            DriveTimeLogic.driveEventTitle(place: "", appointmentTitle: "Dentist"),
            ScedraString("Drive to Dentist")
        )
        XCTAssertEqual(
            DriveTimeLogic.shortPlace("Westwind Community Barn · 27210 Altamont Rd"),
            "Westwind Community Barn"
        )
    }

    func testHomeAppointmentCreatesNoInboundOrOutboundDriveEvents() {
        for source: DriveTimeSource in [.existingCalendarEvent, .newScedraEvent] {
            let plan = DriveTimeLogic.plan(
                officialStart: time(10),
                officialEnd: time(11),
                travel: dentistTravel,
                place: "Home",
                appointmentTitle: "Lunch",
                placement: .separateEvent,
                source: source,
                neighbors: DriveNeighborContext(
                    onwardPlace: "Home",
                    onwardMinutes: 18,
                    onwardGoesHome: true
                )
            )
            XCTAssertNil(plan.driveEvent, "\(source) must not Drive to Home")
            XCTAssertNil(plan.returnDriveEvent, "\(source) must not Drive home from Home")
        }
    }

    func testNilTravelEstimateCreatesNoSiblingDriveEvents() {
        let plan = DriveTimeLogic.plan(
            officialStart: time(10),
            officialEnd: time(11),
            travel: nil,
            place: "Clinic",
            appointmentTitle: "Dentist",
            placement: .separateEvent,
            source: .existingCalendarEvent,
            neighbors: DriveNeighborContext(
                onwardPlace: "12 Home Lane",
                onwardMinutes: 20,
                onwardGoesHome: true
            )
        )
        XCTAssertNil(plan.driveEvent)
        XCTAssertNil(plan.returnDriveEvent)
    }

    func testTightDayChainDrivesFromBobaToWalmartNotHome() {
        let boba = DriveChainStop(
            id: "ek-boba",
            title: "Boba",
            place: "Boba",
            start: time(10, 15),
            end: time(11, 15),
            usesHome: false
        )
        let walmart = DriveChainStop(
            id: "ek-walmart",
            title: "Walmart",
            place: "Walmart",
            start: time(11, 30),
            end: time(12, 30),
            usesHome: false
        )
        let estimates = DriveChainEstimates(
            fromHome: ["ek-boba": 15, "ek-walmart": 18],
            toHome: ["ek-boba": 18, "ek-walmart": 20],
            between: ["ek-boba|ek-walmart": 12]
        )
        let plan = DriveChainLogic.plan(
            stops: [boba, walmart],
            estimates: estimates,
            minHomeMinutes: 30,
            leavingHomeBuffer: 0,
            homeLabel: "Apple Park, One Apple Park Way, Cupertino, CA 95014"
        )
        XCTAssertEqual(plan.legs.map(\.kind), [.fromHome, .between, .toHome])
        XCTAssertEqual(plan.legs[0].toTitle, "Boba")
        XCTAssertEqual(plan.legs[0].title, ScedraString("Drive to Boba"))
        XCTAssertEqual(plan.legs[0].end, time(10, 15))
        XCTAssertEqual(plan.legs[1].title, ScedraString("Drive to Walmart from Boba"))
        XCTAssertEqual(plan.legs[1].start, time(11, 15))
        XCTAssertEqual(plan.legs[1].end, time(11, 27))
        XCTAssertEqual(plan.legs[1].fromID, "ek-boba")
        XCTAssertEqual(plan.legs[1].toID, "ek-walmart")
        XCTAssertEqual(plan.legs[2].fromID, "ek-walmart")
        XCTAssertEqual(plan.legs[2].title, ScedraString("Drive home"))
        XCTAssertEqual(plan.legs[2].start, time(12, 30))
        XCTAssertFalse(plan.legs.contains { $0.kind == .toHome && $0.fromID == "ek-boba" })
        XCTAssertFalse(plan.legs.contains { $0.kind == .fromHome && $0.toID == "ek-walmart" })
        XCTAssertTrue(HomeGapLogic.canGoHome(gap: 15, aToHome: 18, homeToB: 18, minHomeMinutes: 30, buffer: 0) == false)

        for leg in plan.legs {
            XCTAssertFalse(
                ConflictLogic.overlaps(
                    start: leg.start,
                    end: leg.end,
                    otherStart: boba.start,
                    otherEnd: boba.end
                ),
                "\(leg.title) overlaps Boba"
            )
            XCTAssertFalse(
                ConflictLogic.overlaps(
                    start: leg.start,
                    end: leg.end,
                    otherStart: walmart.start,
                    otherEnd: walmart.end
                ),
                "\(leg.title) overlaps Walmart"
            )
        }
        XCTAssertFalse(
            ConflictLogic.overlaps(
                start: plan.legs[0].start,
                end: plan.legs[0].end,
                otherStart: plan.legs[1].start,
                otherEnd: plan.legs[1].end
            )
        )
    }

    func testWideGapChainGoesHomeBetweenStops() {
        let boba = DriveChainStop(
            id: "ek-boba",
            title: "Boba",
            place: "Boba",
            start: time(10, 15),
            end: time(11, 15),
            usesHome: false
        )
        let walmart = DriveChainStop(
            id: "ek-walmart",
            title: "Walmart",
            place: "Walmart",
            start: time(15),
            end: time(16),
            usesHome: false
        )
        let plan = DriveChainLogic.plan(
            stops: [boba, walmart],
            estimates: DriveChainEstimates(
                fromHome: ["ek-boba": 15, "ek-walmart": 18],
                toHome: ["ek-boba": 18, "ek-walmart": 20],
                between: ["ek-boba|ek-walmart": 12]
            ),
            minHomeMinutes: 30,
            leavingHomeBuffer: 0
        )
        XCTAssertEqual(plan.legs.map(\.kind), [.fromHome, .toHome, .fromHome, .toHome])
        XCTAssertEqual(plan.legs[1].fromID, "ek-boba")
        XCTAssertEqual(plan.legs[1].title, ScedraString("Drive home"))
        XCTAssertEqual(plan.legs[2].toID, "ek-walmart")
        XCTAssertEqual(plan.legs[2].title, ScedraString("Drive to Walmart"))
        XCTAssertNil(plan.legs.first { $0.kind == .between })
    }

    func testReplanRemovesStaleDriveHomeAndDriveToWalmart() {
        let boba = DriveChainStop(
            id: "ek-boba",
            title: "Boba",
            place: "Boba",
            start: time(10, 15),
            end: time(11, 15),
            usesHome: false
        )
        let walmart = DriveChainStop(
            id: "ek-walmart",
            title: "Walmart",
            place: "Walmart",
            start: time(11, 30),
            end: time(12, 30),
            usesHome: false
        )
        let staleHome = DriveChainLogic.chainKey(from: "ek-boba", to: nil)
        let staleInbound = DriveChainLogic.chainKey(from: nil, to: "ek-walmart")
        let petsmart = DriveChainLogic.chainKey(from: nil, to: "ek-petsmart")
        let plan = DriveChainLogic.plan(
            stops: [boba, walmart],
            estimates: DriveChainEstimates(
                fromHome: ["ek-boba": 15, "ek-walmart": 18],
                toHome: ["ek-boba": 18, "ek-walmart": 20],
                between: ["ek-boba|ek-walmart": 12]
            ),
            minHomeMinutes: 30,
            existingIdentifiers: [
                staleHome: "ek-drive-home-boba",
                staleInbound: "ek-drive-to-walmart",
                petsmart: "ek-drive-petsmart",
            ],
            staleIdentifiers: ["ek-drive-home-boba", "ek-drive-to-walmart", "ek-drive-petsmart"]
        )
        XCTAssertEqual(Set(plan.removeIdentifiers), ["ek-drive-home-boba", "ek-drive-to-walmart", "ek-drive-petsmart"])
        XCTAssertNil(plan.legs.first { $0.kind == .between }?.existingIdentifier)
        XCTAssertEqual(plan.legs.first { $0.kind == .between }?.chainKey, DriveChainLogic.chainKey(from: "ek-boba", to: "ek-walmart"))
    }

    func testChainSkipsHomeStopsAndNilMinutes() {
        let homeLunch = DriveChainStop(
            id: "ek-lunch",
            title: "Lunch",
            place: "Home",
            start: time(12),
            end: time(13),
            usesHome: true
        )
        let clinic = DriveChainStop(
            id: "ek-clinic",
            title: "Clinic",
            place: "Clinic",
            start: time(14),
            end: time(15),
            usesHome: false
        )
        let empty = DriveChainLogic.plan(
            stops: [homeLunch, clinic],
            estimates: DriveChainEstimates(),
            minHomeMinutes: 20
        )
        XCTAssertTrue(empty.legs.isEmpty, "nil estimates must not invent a 60-min block")

        let onlyHome = DriveChainLogic.plan(
            stops: [homeLunch],
            estimates: DriveChainEstimates(fromHome: ["ek-lunch": 15], toHome: ["ek-lunch": 15]),
            minHomeMinutes: 20
        )
        XCTAssertTrue(onlyHome.legs.isEmpty)
    }

    func testConnectingDriveWindowEqualCutMath() {
        XCTAssertNil(DriveChainLogic.connectingDriveWindow(firstEnd: time(14), secondStart: time(14), minutes: 0))
        XCTAssertNil(DriveChainLogic.connectingDriveWindow(firstEnd: time(14), secondStart: time(14), minutes: -3))

        let fits = DriveChainLogic.connectingDriveWindow(
            firstEnd: time(14),
            secondStart: time(14, 20),
            minutes: 12
        )
        XCTAssertEqual(fits?.start, time(14))
        XCTAssertEqual(fits?.end, time(14, 12))

        let zeroGap = DriveChainLogic.connectingDriveWindow(
            firstEnd: time(14),
            secondStart: time(14),
            minutes: 10
        )
        XCTAssertEqual(zeroGap?.start, time(13, 55))
        XCTAssertEqual(zeroGap?.end, time(14, 5))

        let smallGap = DriveChainLogic.connectingDriveWindow(
            firstEnd: time(14),
            secondStart: time(14, 4),
            minutes: 10
        )
        XCTAssertEqual(smallGap?.start, time(13, 57))
        XCTAssertEqual(smallGap?.end, time(14, 7))

        let odd = DriveChainLogic.connectingDriveWindow(
            firstEnd: time(14),
            secondStart: time(14),
            minutes: 11
        )
        let half = TimeInterval(11 * 60) / 2
        XCTAssertEqual(odd?.start, time(14).addingTimeInterval(-half))
        XCTAssertEqual(odd?.end, time(14).addingTimeInterval(half))
    }

    func testZeroGapBackToBackWritesStraddlingDriveToBFromA() {
        let boba = DriveChainStop(
            id: "ek-boba",
            title: "Boba",
            place: "Boba",
            start: time(14),
            end: time(15),
            usesHome: false
        )
        let target = DriveChainStop(
            id: "ek-target",
            title: "Target",
            place: "Target",
            start: time(15),
            end: time(16),
            usesHome: false
        )
        let plan = DriveChainLogic.plan(
            stops: [boba, target],
            estimates: DriveChainEstimates(
                fromHome: ["ek-boba": 18, "ek-target": 18],
                toHome: ["ek-boba": 18, "ek-target": 18],
                between: ["ek-boba|ek-target": 10]
            ),
            minHomeMinutes: 30,
            leavingHomeBuffer: 0
        )
        XCTAssertEqual(plan.legs.map(\.kind), [.fromHome, .between, .toHome])
        XCTAssertEqual(plan.legs[1].title, ScedraString("Drive to Target from Boba"))
        XCTAssertEqual(plan.legs[1].start, time(14, 55))
        XCTAssertEqual(plan.legs[1].end, time(15, 5))
        XCTAssertEqual(plan.legs[1].minutes, 10)
        XCTAssertEqual(plan.legs[1].fromID, "ek-boba")
        XCTAssertEqual(plan.legs[1].toID, "ek-target")
        XCTAssertFalse(plan.legs.contains { $0.kind == .toHome && $0.fromID == "ek-boba" })
        XCTAssertFalse(plan.legs.contains { $0.kind == .fromHome && $0.toID == "ek-target" })
        XCTAssertEqual(plan.legs[0].title, ScedraString("Drive to Boba"))
        XCTAssertEqual(plan.legs[0].end, time(14))
        XCTAssertEqual(plan.legs[2].title, ScedraString("Drive home"))
        XCTAssertEqual(plan.legs[2].start, time(16))
        XCTAssertTrue(
            ConflictLogic.overlaps(
                start: plan.legs[1].start,
                end: plan.legs[1].end,
                otherStart: boba.start,
                otherEnd: boba.end
            )
        )
        XCTAssertTrue(
            ConflictLogic.overlaps(
                start: plan.legs[1].start,
                end: plan.legs[1].end,
                otherStart: target.start,
                otherEnd: target.end
            )
        )
        XCTAssertEqual(boba.end, time(15), "official A end is not rewritten")
        XCTAssertEqual(target.start, time(15), "official B start is not rewritten")
    }

    func testSmallGapShorterThanDriveStillStraddlesEqually() {
        let clinic = DriveChainStop(
            id: "ek-clinic",
            title: "Dentist",
            place: "Clinic",
            start: time(10),
            end: time(11),
            usesHome: false
        )
        let barn = DriveChainStop(
            id: "ek-barn",
            title: "Riding",
            place: "Barn",
            start: time(11, 4),
            end: time(12),
            usesHome: false
        )
        let plan = DriveChainLogic.plan(
            stops: [clinic, barn],
            estimates: DriveChainEstimates(
                fromHome: ["ek-clinic": 15, "ek-barn": 15],
                toHome: ["ek-clinic": 15, "ek-barn": 15],
                between: ["ek-clinic|ek-barn": 10]
            ),
            minHomeMinutes: 30,
            leavingHomeBuffer: 0
        )
        XCTAssertEqual(plan.legs.map(\.kind), [.fromHome, .between, .toHome])
        XCTAssertEqual(plan.legs[1].title, ScedraString("Drive to Riding from Dentist"))
        XCTAssertEqual(plan.legs[1].start, time(10, 57))
        XCTAssertEqual(plan.legs[1].end, time(11, 7))
        XCTAssertEqual(plan.legs[1].minutes, 10)
        XCTAssertEqual(
            Int(clinic.end.timeIntervalSince(plan.legs[1].start) / 60),
            3,
            "3 min into A"
        )
        XCTAssertEqual(
            Int(plan.legs[1].end.timeIntervalSince(barn.start) / 60),
            3,
            "3 min into B plus the 4 min gap"
        )
        XCTAssertFalse(plan.legs.contains { $0.kind == .toHome && $0.fromID == "ek-clinic" })
        XCTAssertFalse(plan.legs.contains { $0.kind == .fromHome && $0.toID == "ek-barn" })
        XCTAssertEqual(plan.legs.last?.title, ScedraString("Drive home"))
        XCTAssertEqual(plan.legs.last?.start, barn.end)
    }

    func testShortLastEventStillGetsDriveHomeWhenBetweenOverlaps() throws {
        let first = DriveChainStop(
            id: "ek-a",
            title: "Boba",
            place: "Boba",
            start: time(14),
            end: time(15),
            usesHome: false
        )
        let last = DriveChainStop(
            id: "ek-b",
            title: "Target",
            place: "Target",
            start: time(15),
            end: time(15, 3),
            usesHome: false
        )
        let plan = DriveChainLogic.plan(
            stops: [first, last],
            estimates: DriveChainEstimates(
                fromHome: ["ek-a": 18, "ek-b": 18],
                toHome: ["ek-a": 18, "ek-b": 18],
                between: ["ek-a|ek-b": 10]
            ),
            minHomeMinutes: 30
        )
        XCTAssertEqual(plan.legs.map(\.kind), [.fromHome, .between, .toHome])
        XCTAssertEqual(plan.legs[1].start, time(14, 55))
        XCTAssertEqual(plan.legs[1].end, time(15, 5))
        let home = try XCTUnwrap(plan.legs.last)
        XCTAssertEqual(home.kind, .toHome)
        XCTAssertEqual(home.fromID, "ek-b")
        XCTAssertEqual(home.title, ScedraString("Drive home"))
        XCTAssertEqual(home.start, last.end)
        XCTAssertEqual(home.end, time(15, 21))
        XCTAssertTrue(
            ConflictLogic.overlaps(
                start: home.start,
                end: home.end,
                otherStart: plan.legs[1].start,
                otherEnd: plan.legs[1].end
            ),
            "Drive home must not be dropped when it overlaps the straddling A→B block"
        )
    }

    func testFirstFromHomeRemainsWhenStackedAgainstStraddlingDrive() {
        let first = DriveChainStop(
            id: "ek-a",
            title: "Boba",
            place: "Boba",
            start: time(14),
            end: time(14, 3),
            usesHome: false
        )
        let second = DriveChainStop(
            id: "ek-b",
            title: "Target",
            place: "Target",
            start: time(14, 3),
            end: time(15),
            usesHome: false
        )
        let plan = DriveChainLogic.plan(
            stops: [first, second],
            estimates: DriveChainEstimates(
                fromHome: ["ek-a": 15, "ek-b": 15],
                toHome: ["ek-a": 15, "ek-b": 15],
                between: ["ek-a|ek-b": 10]
            ),
            minHomeMinutes: 30
        )
        XCTAssertEqual(plan.legs.first?.kind, .fromHome)
        XCTAssertEqual(plan.legs.first?.toID, "ek-a")
        XCTAssertEqual(plan.legs.first?.title, ScedraString("Drive to Boba"))
        XCTAssertEqual(plan.legs.first?.end, first.start)
        XCTAssertEqual(plan.legs.first?.start, time(13, 45))
        XCTAssertTrue(
            ConflictLogic.overlaps(
                start: plan.legs[0].start,
                end: plan.legs[0].end,
                otherStart: plan.legs[1].start,
                otherEnd: plan.legs[1].end
            ),
            "Drive to first from Home stays even when the A→B straddle overlaps it"
        )
        XCTAssertEqual(plan.legs.last?.kind, .toHome)
        XCTAssertEqual(plan.legs.last?.fromID, "ek-b")
    }

    func testZeroGapHomeLocatedAndNilMinutesStillSkipDrive() {
        let lunch = DriveChainStop(
            id: "ek-lunch",
            title: "Lunch",
            place: "Home",
            start: time(12),
            end: time(13),
            usesHome: true
        )
        let nap = DriveChainStop(
            id: "ek-nap",
            title: "Nap",
            place: "Home",
            start: time(13),
            end: time(14),
            usesHome: true
        )
        let homePlan = DriveChainLogic.plan(
            stops: [lunch, nap],
            estimates: DriveChainEstimates(
                fromHome: ["ek-lunch": 10, "ek-nap": 10],
                toHome: ["ek-lunch": 10, "ek-nap": 10],
                between: ["ek-lunch|ek-nap": 10]
            ),
            minHomeMinutes: 20
        )
        XCTAssertTrue(homePlan.legs.isEmpty)

        let clinic = DriveChainStop(
            id: "ek-clinic",
            title: "Clinic",
            place: "Clinic",
            start: time(14),
            end: time(15),
            usesHome: false
        )
        let barn = DriveChainStop(
            id: "ek-barn",
            title: "Riding",
            place: "Barn",
            start: time(15),
            end: time(16),
            usesHome: false
        )
        let nilPlan = DriveChainLogic.plan(
            stops: [clinic, barn],
            estimates: DriveChainEstimates(),
            minHomeMinutes: 20
        )
        XCTAssertTrue(nilPlan.legs.isEmpty, "nil Maps minutes must not invent a drive")
    }

    func testZeroGapReplanRemovesStaleHomeLegsAndKeepsThrottleSibling() {
        let boba = DriveChainStop(
            id: "ek-boba",
            title: "Boba",
            place: "Boba",
            start: time(14),
            end: time(15),
            usesHome: false
        )
        let target = DriveChainStop(
            id: "ek-target",
            title: "Target",
            place: "Target",
            start: time(15),
            end: time(16),
            usesHome: false
        )
        let staleHome = DriveChainLogic.chainKey(from: "ek-boba", to: nil)
        let staleInbound = DriveChainLogic.chainKey(from: nil, to: "ek-target")
        let betweenKey = DriveChainLogic.chainKey(from: "ek-boba", to: "ek-target")
        let replaced = DriveChainLogic.plan(
            stops: [boba, target],
            estimates: DriveChainEstimates(
                fromHome: ["ek-boba": 15, "ek-target": 15],
                toHome: ["ek-boba": 15, "ek-target": 15],
                between: ["ek-boba|ek-target": 10]
            ),
            minHomeMinutes: 30,
            existingIdentifiers: [
                staleHome: "ek-drive-home-boba",
                staleInbound: "ek-drive-to-target",
            ],
            staleIdentifiers: ["ek-drive-home-boba", "ek-drive-to-target"]
        )
        XCTAssertEqual(Set(replaced.removeIdentifiers), ["ek-drive-home-boba", "ek-drive-to-target"])
        XCTAssertEqual(replaced.legs.map(\.kind), [.fromHome, .between, .toHome])
        XCTAssertEqual(replaced.legs[1].title, ScedraString("Drive to Target from Boba"))

        let throttled = DriveChainLogic.plan(
            stops: [boba, target],
            estimates: DriveChainEstimates(),
            minHomeMinutes: 30,
            existingIdentifiers: [betweenKey: "ek-drive-between"],
            staleIdentifiers: ["ek-drive-between"]
        )
        XCTAssertTrue(
            throttled.removeIdentifiers.isEmpty,
            "GEOError -3 / nil estimates must not delete the last good Drive to B from A"
        )
        XCTAssertNil(throttled.legs.first { $0.kind == .between })
    }

    func testStraddlingBetweenDriveIsNotFreeTimeAtHome() {
        let first = HomeGapStop(
            id: "ek-clinic",
            title: "Dentist",
            place: "Clinic",
            officialStart: time(10),
            officialEnd: time(11),
            extraBeforeMinutes: 0,
            extraAfterMinutes: 0,
            usesHome: false
        )
        var drive = HomeGapStop(
            id: "ek-drive",
            title: ScedraString("Drive to Riding from Dentist"),
            place: "Barn",
            officialStart: time(10, 57),
            officialEnd: time(11, 7),
            extraBeforeMinutes: 0,
            extraAfterMinutes: 0,
            usesHome: false,
            notes: DriveTimeLogic.driveNotes(
                chainKey: DriveChainLogic.chainKey(from: "ek-clinic", to: "ek-barn"),
                fromID: "ek-clinic",
                toID: "ek-barn",
                leg: .between
            ),
            isDriveEvent: true
        )
        drive.calendarEventID = "ek-drive"
        let second = HomeGapStop(
            id: "ek-barn",
            title: "Riding",
            place: "Barn",
            officialStart: time(11, 4),
            officialEnd: time(12),
            extraBeforeMinutes: 0,
            extraAfterMinutes: 0,
            usesHome: false
        )
        let leftover = HomeGapLogic.leftoverMinutesAtHome(
            first: first,
            second: second,
            occupied: [first, drive, second],
            aToHome: 0,
            homeToB: 0,
            buffer: 0,
            before: 0
        )
        XCTAssertEqual(leftover, 0, "the 4 min gap is the drive, not sitting at home")
        XCTAssertNotEqual(leftover, 4)
    }

    func testDirectDriveThatDoesNotFitStillStartsAtAEnd() {
        let target = DriveChainStop(
            id: "ek-target",
            title: "target",
            place: "Target",
            start: time(15),
            end: time(16),
            usesHome: false
        )
        let heart = DriveChainStop(
            id: "ek-heart",
            title: "Heart",
            place: "H Mart",
            start: time(16, 20),
            end: time(17, 20),
            usesHome: false
        )
        let plan = DriveChainLogic.plan(
            stops: [target, heart],
            estimates: DriveChainEstimates(
                fromHome: ["ek-target": 21, "ek-heart": 21],
                toHome: ["ek-target": 21, "ek-heart": 21],
                between: ["ek-target|ek-heart": 15]
            ),
            minHomeMinutes: 30,
            leavingHomeBuffer: 0
        )
        XCTAssertEqual(plan.legs.map(\.kind), [.fromHome, .between, .toHome])
        XCTAssertEqual(plan.legs[0].title, ScedraString("Drive to target"))
        XCTAssertEqual(plan.legs[1].title, ScedraString("Drive to Heart from target"))
        XCTAssertEqual(plan.legs[1].start, time(16))
        XCTAssertEqual(plan.legs[2].title, ScedraString("Drive home"))
        XCTAssertEqual(plan.legs[2].start, time(17, 20))
        XCTAssertNil(plan.legs.first { $0.kind == .toHome && $0.fromID == "ek-target" })
        XCTAssertNil(plan.legs.first { $0.kind == .fromHome && $0.toID == "ek-heart" })
    }

    func testDriveLineParsesOutboundAndReturnMinutes() {
        let line = "~21 min there, ~21 min back (~42 min round trip)"
        XCTAssertEqual(LeaveToNavigateNotifier.driveMinutes(from: line), 21)
        XCTAssertEqual(LeaveToNavigateNotifier.returnMinutes(from: line), 21)
        XCTAssertEqual(LeaveToNavigateNotifier.returnMinutes(from: "~21 min there"), nil)
    }

    /// Tight 20-min gap, 18 min each way home, 12 min A→B, 30 min min-at-home:
    /// one "Drive to Target from Boba", not Drive home then Drive to Target.
    func testTightGapWritesOneDriveToBFromA() {
        let boba = DriveChainStop(
            id: "ek-boba",
            title: "Boba",
            place: "Boba",
            start: time(14, 40),
            end: time(15),
            usesHome: false
        )
        let target = DriveChainStop(
            id: "ek-target",
            title: "Target",
            place: "Target",
            start: time(15, 20),
            end: time(16, 20),
            usesHome: false
        )
        let plan = DriveChainLogic.plan(
            stops: [boba, target],
            estimates: DriveChainEstimates(
                fromHome: ["ek-boba": 18, "ek-target": 18],
                toHome: ["ek-boba": 18, "ek-target": 18],
                between: ["ek-boba|ek-target": 12]
            ),
            minHomeMinutes: 30,
            leavingHomeBuffer: 0,
            staleIdentifiers: ["ek-drive-home-boba", "ek-drive-to-target"]
        )
        XCTAssertFalse(HomeGapLogic.canGoHome(gap: 20, aToHome: 18, homeToB: 18, minHomeMinutes: 30, buffer: 0))
        XCTAssertEqual(plan.legs.map(\.kind), [.fromHome, .between, .toHome])
        XCTAssertEqual(
            DriveTimeLogic.betweenEventTitle(from: "Boba", to: "Target"),
            ScedraString("Drive to Target from Boba")
        )
        XCTAssertEqual(plan.legs[1].title, ScedraString("Drive to Target from Boba"))
        XCTAssertEqual(plan.legs[1].start, time(15))
        XCTAssertEqual(plan.legs[1].end, time(15, 12))
        XCTAssertFalse(plan.legs.contains { $0.kind == .toHome && $0.fromID == "ek-boba" })
        XCTAssertFalse(plan.legs.contains { $0.kind == .fromHome && $0.toID == "ek-target" })
        XCTAssertFalse(plan.legs.contains { $0.title == ScedraString("Drive home") && $0.start == time(15) })
        XCTAssertFalse(plan.legs.contains { $0.title == ScedraString("Drive to Target") })
        XCTAssertEqual(Set(plan.removeIdentifiers), ["ek-drive-home-boba", "ek-drive-to-target"])

        let missingHome = DriveChainLogic.plan(
            stops: [boba, target],
            estimates: DriveChainEstimates(between: ["ek-boba|ek-target": 12]),
            minHomeMinutes: 30
        )
        XCTAssertEqual(missingHome.legs.map(\.kind), [.between])
        XCTAssertEqual(missingHome.legs[0].title, ScedraString("Drive to Target from Boba"))
    }

    func testCachedMinutesAndNilEstimateKeepExistingBetweenSibling() async {
        let origin = CLLocationCoordinate2D(latitude: 37.3318, longitude: -122.0312)
        let destination = CLLocationCoordinate2D(latitude: 37.4419, longitude: -122.1430)
        let depart = time(15)
        TravelEstimator.resetMinutesCache()
        TravelEstimator.rememberMinutes(
            from: origin,
            to: destination,
            departingAt: depart,
            transportType: .automobile,
            minutes: 12
        )
        XCTAssertEqual(
            TravelEstimator.cachedMinutes(
                from: origin,
                to: destination,
                departingAt: depart.addingTimeInterval(60),
                transportType: .automobile
            ),
            12
        )
        let cached = await TravelEstimator.mapsMinutes(
            from: origin,
            to: destination,
            departingAt: depart,
            transportType: .automobile
        )
        XCTAssertEqual(cached, 12)
        let samePlace = await TravelEstimator.mapsMinutes(
            from: origin,
            to: origin,
            departingAt: depart,
            transportType: .automobile
        )
        XCTAssertNil(samePlace)
        TravelEstimator.resetMinutesCache()

        let boba = DriveChainStop(
            id: "ek-boba",
            title: "Boba",
            place: "Boba",
            start: time(14, 40),
            end: time(15),
            usesHome: false
        )
        let target = DriveChainStop(
            id: "ek-target",
            title: "Target",
            place: "Target",
            start: time(15, 20),
            end: time(16, 20),
            usesHome: false
        )
        let betweenKey = DriveChainLogic.chainKey(from: "ek-boba", to: "ek-target")
        let plan = DriveChainLogic.plan(
            stops: [boba, target],
            estimates: DriveChainEstimates(),
            minHomeMinutes: 30,
            existingIdentifiers: [betweenKey: "ek-drive-between"],
            staleIdentifiers: ["ek-drive-between"]
        )
        XCTAssertTrue(
            plan.removeIdentifiers.isEmpty,
            "nil / throttled estimates must not delete the last good Drive to B from A"
        )
        XCTAssertNil(plan.legs.first { $0.kind == .between })
    }
}
