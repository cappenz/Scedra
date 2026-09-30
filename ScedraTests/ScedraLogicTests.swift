import CoreLocation
import MapKit
import XCTest
@testable import Scedra

final class ScedraLogicTests: XCTestCase {
    func testTypePathParsesTodayTimeAndAssumesOneHour() {
        let drafts = EventExtractor.drafts(from: "dentist today at 2 at McDonald's")
        XCTAssertEqual(drafts.count, 1)
        let draft = drafts[0]
        XCTAssertTrue(draft.hasDate, "date+time text should mark the date present")
        XCTAssertTrue(draft.hasTime, "today at 2 should mark the time present")
        XCTAssertTrue(draft.durationAssumed)
        XCTAssertEqual(draft.durationMinutes, 60)
        XCTAssertTrue(
            draft.location.localizedCaseInsensitiveContains("McDonald"),
            "expected McDonald's location, got \(draft.location)"
        )
    }

    func testMissingDateAndTimeBlocksSave() {
        let drafts = EventExtractor.drafts(from: "dentist at McDonald's")
        XCTAssertEqual(drafts.count, 1)
        XCTAssertFalse(drafts[0].hasDate, "extractor flags still record that the text named neither")
        XCTAssertFalse(drafts[0].hasTime)
        XCTAssertEqual(
            CalendarStoreError.missingDateOrTime.errorDescription,
            ScedraString("This needs a date and a time before it can be saved.")
        )
    }

    /// Screenshot bug: Review showed "Sep 17, 2026 at 10:16 AM – 11:16 AM" but Confirm
    /// refused because extractor `hasTime` was false. The displayed window is the time.
    func testDisplayedClockTimeAllowsConfirmEvenWhenExtractorMissedDateTime() {
        let drafts = EventExtractor.drafts(from: "Riding, West wind barn")
        XCTAssertEqual(drafts.count, 1)
        var draft = drafts[0]
        XCTAssertFalse(draft.hasDate)
        XCTAssertFalse(draft.hasTime)
        XCTAssertEqual(draft.durationMinutes, 60)
        XCTAssertTrue(draft.durationAssumed)
        XCTAssertTrue(
            draft.hasDisplayedDateAndTime,
            "Review shows start–end as a clock window even when the text omitted the time"
        )
        XCTAssertGreaterThan(draft.end, draft.start)

        draft.acceptDisplayedDateAndTime()
        XCTAssertTrue(draft.hasDate, "Confirm copies the on-screen DatePicker day into the save flags")
        XCTAssertTrue(draft.hasTime, "Confirm copies the on-screen clock time into the save flags")

        let screenshotDraft = EventExtractor.drafts(from: "Riding, West wind barn")[0]
        let ready = CalendarSaveGate.readyToSave(screenshotDraft)
        XCTAssertNotNil(ready, "if the card shows 10:16–11:16, Confirm must save — extractor flags are not the gate")
        XCTAssertEqual(ready?.hasDate, true)
        XCTAssertEqual(ready?.hasTime, true)
    }

    /// Confirm used to refuse a displayed clock because the locale-formatted
    /// field ("10:16 AM" with a narrow space) failed the English parser.
    func testLocaleFormattedClockDoesNotBlockConfirm() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let formatted = date.scedraDisplay(date: .omitted, time: .shortened)
        let narrow = formatted.replacingOccurrences(of: " ", with: "\u{202F}")
        XCTAssertTrue(
            ReviewTimeTyping.clocksMatch(narrow, formatted: formatted),
            "a locale narrow-space clock is the same time Confirm already shows"
        )
        XCTAssertTrue(ReviewTimeTyping.clocksMatch(formatted, formatted: formatted))

        var draft = EventExtractor.drafts(from: "Riding, West wind barn")[0]
        XCTAssertFalse(draft.hasDate)
        XCTAssertFalse(draft.hasTime)
        XCTAssertTrue(draft.hasDisplayedDateAndTime)
        XCTAssertNotNil(CalendarSaveGate.readyToSave(draft))

        draft.acceptDisplayedDateAndTime()
        XCTAssertNotNil(CalendarSaveGate.readyToSave(draft))
    }

    func testEventTimeChangeUpdatesTheIdentifiersStart() throws {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.date(from: DateComponents(year: 2026, month: 6, day: 10))!
        func time(_ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }
        let item = TodayItem(
            id: "ek-dentist",
            title: "Dentist",
            start: time(10),
            end: time(11),
            isAllDay: false,
            location: "Clinic",
            notes: EventNotes.body(forOriginal: "dentist tomorrow at 10")
        )
        XCTAssertTrue(CalendarSaveGate.readyToSave(start: time(14), end: time(15)))
        XCTAssertFalse(CalendarSaveGate.readyToSave(start: time(15), end: time(14)))

        let prepared = try EventScheduleEdit.prepare(
            item: item,
            officialStart: time(14),
            officialEnd: time(15)
        )
        XCTAssertEqual(prepared.identifier, "ek-dentist")
        XCTAssertEqual(prepared.title, "Dentist", "titles she typed stay raw")
        XCTAssertEqual(prepared.start, time(14))
        XCTAssertEqual(prepared.end, time(15))
        XCTAssertEqual(EventNotes.original(from: prepared.notes), "dentist tomorrow at 10")

        XCTAssertThrowsError(
            try EventScheduleEdit.prepare(item: item, officialStart: time(15), officialEnd: time(14))
        ) { error in
            XCTAssertEqual(
                (error as? CalendarStoreError)?.errorDescription,
                CalendarStoreError.missingDateOrTime.errorDescription
            )
        }
    }

    func testEventTimeChangeKeepsTravelPaddingOnTheSameIdentifier() throws {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.date(from: DateComponents(year: 2026, month: 6, day: 10))!
        func time(_ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }
        let officialStart = time(18)
        let officialEnd = time(21)
        let window = TravelEstimator.appointmentWindow(from: officialStart, to: officialEnd)
        let item = TodayItem(
            id: "ek-dinner",
            title: "Dinner",
            start: time(17, 35),
            end: time(21, 25),
            isAllDay: false,
            location: nil,
            notes: EventNotes.body(
                forOriginal: "dinner 6-9",
                details: ["Appointment: \(window)"]
            )
        )
        XCTAssertEqual(item.officialStart, officialStart)
        XCTAssertEqual(item.officialEnd, officialEnd)

        let prepared = try EventScheduleEdit.prepare(
            item: item,
            officialStart: time(14),
            officialEnd: time(15)
        )
        XCTAssertEqual(prepared.identifier, "ek-dinner")
        XCTAssertEqual(prepared.start, time(13, 35))
        XCTAssertEqual(prepared.end, time(15, 25))
        XCTAssertEqual(EventNotes.original(from: prepared.notes), "dinner 6-9")
        XCTAssertTrue(prepared.notes?.contains(TravelEstimator.appointmentWindow(from: time(14), to: time(15))) == true)
    }

    func testConfirmDoesNotTreatEmptyEventKitIdentifierAsSaved() {
        XCTAssertFalse(CalendarPersistCheck.accepted(eventIdentifier: nil, access: .full, canFetch: false))
        XCTAssertFalse(CalendarPersistCheck.accepted(eventIdentifier: "", access: .full, canFetch: true))
        XCTAssertFalse(CalendarPersistCheck.accepted(eventIdentifier: "ek-1", access: .full, canFetch: false))
        XCTAssertTrue(CalendarPersistCheck.accepted(eventIdentifier: "ek-1", access: .full, canFetch: true))
        XCTAssertTrue(
            CalendarPersistCheck.accepted(eventIdentifier: "ek-1", access: .writeOnly, canFetch: false),
            "write-only cannot fetch the event back; a real identifier after commit is enough"
        )
        XCTAssertFalse(
            CalendarPersistCheck.accepted(eventIdentifier: nil, access: .writeOnly, canFetch: false),
            "write-only still cannot silently succeed without an EventKit identifier"
        )
        XCTAssertEqual(
            CalendarStoreError.saveFailed(
                ScedraString("Calendar did not accept this appointment. Check Calendar access in Settings.")
            ).errorDescription,
            ScedraString("Calendar did not accept this appointment. Check Calendar access in Settings.")
        )
    }

    func testDriveSectionShowsForResolvedBarnEvenWhenExtractorMissedTime() {
        var draft = EventExtractor.drafts(from: "Riding, West wind barn")[0]
        XCTAssertFalse(draft.hasTime, "the original text named no clock time")
        XCTAssertTrue(draft.hasDisplayedDateAndTime)

        draft.location = ""
        draft.clearResolvedPlace()
        XCTAssertFalse(TravelEstimator.shouldEstimate(for: draft), "no place means no drive section")

        draft.location = "West wind barn"
        XCTAssertTrue(
            TravelEstimator.shouldEstimate(for: draft),
            "a location plus the displayed 10:16–11:16 window must show drive time, not a blank"
        )

        draft.applyResolvedPlace(
            ResolvedPlace(
                name: "Westwind Community Barn",
                address: "27210 Altamont Rd, Los Altos Hills",
                latitude: 37.3576,
                longitude: -122.1503
            )
        )
        XCTAssertTrue(TravelEstimator.shouldEstimate(for: draft))
        XCTAssertEqual(draft.locationLatitude, 37.3576)
        XCTAssertEqual(
            draft.locationToSave,
            "Westwind Community Barn · 27210 Altamont Rd, Los Altos Hills"
        )
        XCTAssertEqual(TravelEstimator.loadingMessage, String(localized: "Asking Maps for drive time…"))
        XCTAssertEqual(TravelEstimator.noOriginMessage, String(localized: "Set Home in Settings for drive time"))
        XCTAssertEqual(TravelEstimator.noPinMessage, String(localized: "Couldn’t pin this place"))
        XCTAssertEqual(TravelEstimator.noRouteMessage, String(localized: "No drive time from Maps"))
    }

    func testScreenshotBarnAppointmentPadsCalendarAndLeadsNotesWithOfficialTime() {
        let calendar = Calendar.current
        let start = calendar.date(bySettingHour: 10, minute: 16, second: 0, of: Date())!
        let end = start.addingTimeInterval(60 * 60)
        var draft = EventExtractor.drafts(from: "Riding, West wind barn")[0]
        draft.start = start
        draft.durationMinutes = 60
        draft.acceptDisplayedDateAndTime()
        draft.applyResolvedPlace(
            ResolvedPlace(
                name: "Westwind Community Barn",
                address: "27210 Altamont Rd, Los Altos Hills",
                latitude: 37.3576,
                longitude: -122.1503
            )
        )

        let estimate = TravelEstimator.estimate(
            minutes: 25,
            mode: .drive,
            start: draft.start,
            bufferMinutes: 0,
            returnMinutes: 25
        )
        XCTAssertEqual(TravelEstimator.line(for: estimate), expectedTravelLine(estimate))
        XCTAssertEqual(estimate.leaveBy, start.addingTimeInterval(-25 * 60))

        let block = TravelEstimator.calendarBlock(start: draft.start, end: draft.end, travel: estimate)
        XCTAssertTrue(block.isPadded)
        XCTAssertEqual(block.start, start.addingTimeInterval(-25 * 60))
        XCTAssertEqual(block.end, end.addingTimeInterval(25 * 60))

        let lines = TravelEstimator.noteLines(
            appointmentStart: draft.start,
            appointmentEnd: draft.end,
            travel: estimate,
            place: draft.locationToSave
        )
        XCTAssertEqual(lines[0], "Appointment: \(TravelEstimator.appointmentWindow(from: start, to: end))")
        XCTAssertEqual(lines[1], "Travel: Driving")
        XCTAssertEqual(lines[2], "Drive: ~25 min there, ~25 min back (~50 min round trip)")
        XCTAssertEqual(lines[3], "Leave by \(estimate.leaveBy.formatted(date: .omitted, time: .shortened))")
        XCTAssertEqual(lines[4], "Westwind Community Barn · 27210 Altamont Rd, Los Altos Hills")

        let unpadded = TravelEstimator.calendarBlock(start: draft.start, end: draft.end, travel: nil)
        XCTAssertEqual(unpadded.start, start)
        XCTAssertEqual(unpadded.end, end)
        XCTAssertFalse(unpadded.isPadded)
    }

    func testExtraTimeDoesNotChangeOfficialAppointmentTimes() {
        var draft = EventExtractor.drafts(from: "lunch today at 1")[0]
        let officialEnd = draft.end
        draft.extraBeforeMinutes = 15
        draft.extraAfterMinutes = 30
        XCTAssertEqual(draft.end, officialEnd, "official end stays the stated appointment")
        XCTAssertEqual(draft.extraBeforeMinutes, 15)
        XCTAssertEqual(draft.extraAfterMinutes, 30)
        draft.extraBeforeMinutes = 0
        draft.extraAfterMinutes = 0
        XCTAssertEqual(draft.end, officialEnd)
    }

    func testTypedReviewClocksUpdateDraftWithoutSteppers() {
        let calendar = Calendar.current
        let start = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: Date())!
        var draft = DraftEvent(
            title: "Dentist",
            start: start,
            durationMinutes: 60,
            durationAssumed: true,
            location: "",
            sourceText: "dentist",
            hasDate: true,
            hasTime: true
        )

        XCTAssertEqual(ReviewTimeTyping.parseAppointment("2:30 PM"), .clock(hour: 14, minute: 30, resolved: true))
        XCTAssertEqual(ReviewTimeTyping.parseAppointment("14:30"), .clock(hour: 14, minute: 30, resolved: true))
        XCTAssertEqual(
            ReviewTimeTyping.parseAppointment("6-9"),
            .window(startHour: 18, startMinute: 0, endHour: 21, endMinute: 0)
        )
        XCTAssertEqual(ReviewTimeTyping.parseAppointment("6 to 9"), .window(startHour: 18, startMinute: 0, endHour: 21, endMinute: 0))
        XCTAssertEqual(ReviewTimeTyping.parseAppointment("2:30"), .clock(hour: 14, minute: 30, resolved: true))
        XCTAssertNil(ReviewTimeTyping.parseAppointment("nope"))
        XCTAssertNil(ReviewTimeTyping.parseExtraMinutes("abc"))

        XCTAssertTrue(draft.applyTypedStart("2:30 PM"))
        XCTAssertEqual(calendar.component(.hour, from: draft.start), 14)
        XCTAssertEqual(calendar.component(.minute, from: draft.start), 30)
        XCTAssertEqual(draft.durationMinutes, 60, "typing only a start keeps the existing duration")
        XCTAssertTrue(draft.durationAssumed, "assumed 1 hour stays assumed until she gives an end")
        XCTAssertEqual(calendar.component(.hour, from: draft.end), 15)
        XCTAssertEqual(calendar.component(.minute, from: draft.end), 30)

        XCTAssertTrue(draft.applyTypedStart("2:30"))
        XCTAssertEqual(calendar.component(.hour, from: draft.start), 14, "bare 2:30 is afternoon, never 2 AM")

        XCTAssertTrue(draft.applyTypedStart("14:30"))
        XCTAssertEqual(calendar.component(.hour, from: draft.start), 14)
        XCTAssertEqual(calendar.component(.minute, from: draft.start), 30)
        XCTAssertEqual(draft.durationMinutes, 60)
        XCTAssertTrue(draft.durationAssumed)

        XCTAssertTrue(draft.applyTypedStart("6-9"))
        XCTAssertEqual(calendar.component(.hour, from: draft.start), 18)
        XCTAssertEqual(calendar.component(.minute, from: draft.start), 0)
        XCTAssertEqual(draft.durationMinutes, 180)
        XCTAssertFalse(draft.durationAssumed)
        XCTAssertEqual(calendar.component(.hour, from: draft.end), 21)
        XCTAssertEqual(calendar.component(.minute, from: draft.end), 0)
    }

    func testTypedEndAndExtraMinutesLeaveOfficialWindowAndMapsApart() {
        let calendar = Calendar.current
        let start = calendar.date(bySettingHour: 14, minute: 30, second: 0, of: Date())!
        var draft = DraftEvent(
            title: "Dentist",
            start: start,
            durationMinutes: 60,
            durationAssumed: true,
            location: "",
            sourceText: "dentist",
            hasDate: true,
            hasTime: true
        )

        XCTAssertTrue(draft.applyTypedEnd("4:00 PM"))
        XCTAssertEqual(calendar.component(.hour, from: draft.start), 14)
        XCTAssertEqual(calendar.component(.minute, from: draft.start), 30)
        XCTAssertEqual(draft.durationMinutes, 90)
        XCTAssertFalse(draft.durationAssumed)
        XCTAssertEqual(calendar.component(.hour, from: draft.end), 16)

        let officialStart = draft.start
        let officialEnd = draft.end
        XCTAssertTrue(draft.applyTypedExtraBefore("15"))
        XCTAssertTrue(draft.applyTypedExtraAfter("30 min"))
        XCTAssertEqual(draft.extraBeforeMinutes, 15)
        XCTAssertEqual(draft.extraAfterMinutes, 30)
        XCTAssertEqual(draft.start, officialStart)
        XCTAssertEqual(draft.end, officialEnd)

        let estimate = TravelEstimator.estimate(
            minutes: 20,
            mode: .drive,
            start: draft.start,
            bufferMinutes: 5,
            returnMinutes: 20,
            extraBeforeMinutes: draft.extraBeforeMinutes,
            extraAfterMinutes: draft.extraAfterMinutes
        )
        XCTAssertEqual(estimate.minutes, 20, "typed extra must not mix into Apple Maps drive minutes")
        XCTAssertEqual(estimate.routedReturnMinutes, 20)
        XCTAssertEqual(
            estimate.leaveBy,
            draft.start.addingTimeInterval(-40 * 60),
            "leave-by = start − drive − buffer − typed extra before"
        )

        XCTAssertTrue(draft.applyTypedEnd("6-9"))
        XCTAssertEqual(calendar.component(.hour, from: draft.start), 18)
        XCTAssertEqual(draft.durationMinutes, 180)
        XCTAssertEqual(calendar.component(.hour, from: draft.end), 21)
        XCTAssertEqual(draft.extraBeforeMinutes, 15, "a new official window does not clear extra time")
    }

    func testGenericPlaceIsNotTreatedAsFullAddress() {
        XCTAssertFalse(PlaceResolver.isSpecificAddress("McDonald's"))
        XCTAssertFalse(PlaceResolver.isSpecificAddress("Stanford"))
        XCTAssertTrue(PlaceResolver.isSpecificAddress("123 Main St"))
        XCTAssertTrue(PlaceResolver.isSpecificAddress("McDonald's · 123 Main St"))
    }

    func testClosestPlaceRejectsFarFranchise() {
        let center = CLLocation(latitude: 37.4419, longitude: -122.1430) // Palo Alto
        let nearby = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 37.4470, longitude: -122.1590)))
        nearby.name = "McDonald's University Ave"
        let far = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)))
        far.name = "McDonald's Los Angeles"

        let picked = PlaceResolver.closestMapItem(in: [far, nearby], near: center)
        XCTAssertEqual(picked?.name, "McDonald's University Ave")

        let onlyFar = PlaceResolver.closestMapItem(in: [far], near: center)
        XCTAssertNil(onlyFar, "a franchise ~500km away must not be chosen")
    }

    func testTodayWindowIncludesSameDayAndExcludesTomorrow() {
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: now) ?? now
        let todayEnd = todayStart.addingTimeInterval(3600)
        XCTAssertTrue(TodayWindow.contains(start: todayStart, end: todayEnd, now: now, calendar: calendar))

        let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart)!
        XCTAssertFalse(TodayWindow.contains(start: tomorrow, end: tomorrow.addingTimeInterval(3600), now: now, calendar: calendar))
    }

    func testResolvedLocationIsWhatGetsSaved() {
        var draft = EventExtractor.drafts(from: "lunch today at 1 at McDonald's")[0]
        draft.applyResolvedPlace(
            ResolvedPlace(name: "McDonald's", address: "165 University Ave", latitude: 37.44, longitude: -122.16)
        )
        XCTAssertEqual(draft.locationToSave, "McDonald's · 165 University Ave")
    }

    func testMcdonaldsTodayAt3HasDateTimeAndLocation() {
        let drafts = EventExtractor.drafts(from: "mcdonalds today at 3")
        XCTAssertEqual(drafts.count, 1)
        let draft = drafts[0]
        XCTAssertTrue(draft.hasDate)
        XCTAssertTrue(draft.hasTime)
        XCTAssertTrue(
            draft.location.localizedCaseInsensitiveContains("mcdonalds"),
            "expected mcdonalds as location, got \(draft.location)"
        )
        XCTAssertTrue(TodayWindow.contains(start: draft.start, end: draft.end))
    }

    func testDentistTomorrowAt2IsOutsideTodayWindow() {
        let drafts = EventExtractor.drafts(from: "dentist tomorrow at 2")
        XCTAssertEqual(drafts.count, 1)
        let draft = drafts[0]
        XCTAssertTrue(draft.hasDate)
        XCTAssertTrue(draft.hasTime)
        XCTAssertFalse(TodayWindow.contains(start: draft.start, end: draft.end))
    }

    func testGenericPlaceHasNoAreaSplit() {
        XCTAssertTrue(PlaceResolver.placeAreaSplits(from: "mcdonalds").isEmpty)
        XCTAssertTrue(PlaceResolver.placeAreaSplits(from: "McDonald's").isEmpty)
        XCTAssertTrue(PlaceResolver.placeAreaSplits(from: "the dentist").isEmpty)
    }

    func testQualifiedPlaceSplitsNamedArea() {
        let menlo = PlaceResolver.placeAreaSplits(from: "mcdonalds menlo park")
        XCTAssertEqual(menlo.first?.place.lowercased(), "mcdonalds")
        XCTAssertEqual(menlo.first?.area.lowercased(), "menlo park")

        let preposition = PlaceResolver.placeAreaSplits(from: "mcdonalds in menlo park")
        XCTAssertEqual(preposition.first?.place.lowercased(), "mcdonalds")
        XCTAssertEqual(preposition.first?.area.lowercased(), "menlo park")

        let starbucks = PlaceResolver.placeAreaSplits(from: "starbucks palo alto")
        XCTAssertEqual(starbucks.first?.place.lowercased(), "starbucks")
        XCTAssertEqual(starbucks.first?.area.lowercased(), "palo alto")
    }

    func testQualifiedAreaPicksPlaceNearNamedLocationNotUser() {
        let menloPark = CLLocation(latitude: 37.4529, longitude: -122.1817)
        let menloStore = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 37.4485, longitude: -122.1778)))
        menloStore.name = "McDonald's Menlo Park"
        let paloStore = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 37.4470, longitude: -122.1590)))
        paloStore.name = "McDonald's University Ave"

        let picked = PlaceResolver.closestMapItem(in: [paloStore, menloStore], near: menloPark)
        XCTAssertEqual(picked?.name, "McDonald's Menlo Park")
    }

    func testMcdonaldsMenloParkTodayKeepsNamedArea() {
        let drafts = EventExtractor.drafts(from: "mcdonalds menlo park today at 3")
        XCTAssertEqual(drafts.count, 1)
        XCTAssertTrue(drafts[0].hasDate)
        XCTAssertTrue(drafts[0].hasTime)
        XCTAssertTrue(drafts[0].location.localizedCaseInsensitiveContains("mcdonalds"))
        XCTAssertTrue(drafts[0].location.localizedCaseInsensitiveContains("menlo"))
        XCTAssertFalse(PlaceResolver.placeAreaSplits(from: drafts[0].location).isEmpty)
        XCTAssertTrue(TodayWindow.contains(start: drafts[0].start, end: drafts[0].end))
    }

    func testSixToNineUsesExplicitRangeNotAssumedHour() {
        for text in ["dentist today 6-9", "dentist today 6 to 9", "dentist today 6–9"] {
            let drafts = EventExtractor.drafts(from: text)
            XCTAssertEqual(drafts.count, 1, text)
            let draft = drafts[0]
            XCTAssertTrue(draft.hasTime, text)
            XCTAssertFalse(draft.durationAssumed, text)
            XCTAssertEqual(draft.durationMinutes, 180, text)
            let hour = Calendar.current.component(.hour, from: draft.start)
            XCTAssertEqual(hour, 18, text)
            XCTAssertEqual(Calendar.current.component(.hour, from: draft.end), 21, text)
        }
    }

    func testSixPmToNinePmKeepsEveningWindow() {
        let draft = EventExtractor.drafts(from: "dinner today 6pm-9pm")[0]
        XCTAssertFalse(draft.durationAssumed)
        XCTAssertEqual(draft.durationMinutes, 180)
        XCTAssertEqual(Calendar.current.component(.hour, from: draft.start), 18)
        XCTAssertEqual(Calendar.current.component(.hour, from: draft.end), 21)
    }

    func testBareClockHoursAssumeAfternoonNotEarlyMorning() {
        XCTAssertEqual(ClockTimeParser.parse("at 1")?.hour, 13)
        XCTAssertEqual(ClockTimeParser.parse("at 2")?.hour, 14)
        XCTAssertEqual(ClockTimeParser.parse("1am")?.hour, 1)
        XCTAssertEqual(ClockTimeParser.parse("today 10")?.hour, 10)
        XCTAssertEqual(ReviewTimeTyping.parseAppointment("1"), .clock(hour: 13, minute: 0, resolved: true))
        XCTAssertEqual(ReviewTimeTyping.parseAppointment("1:00"), .clock(hour: 13, minute: 0, resolved: true))
        XCTAssertEqual(ReviewTimeTyping.parseAppointment("at 2"), .clock(hour: 14, minute: 0, resolved: true))
        XCTAssertEqual(ReviewTimeTyping.parseAppointment("10"), .clock(hour: 10, minute: 0, resolved: true))
        XCTAssertEqual(ReviewTimeTyping.parseAppointment("1am"), .clock(hour: 1, minute: 0, resolved: true))

        let twoThree = TimeRangeParser.parse("2-3")
        XCTAssertEqual(twoThree?.startHour, 14)
        XCTAssertEqual(twoThree?.endHour, 15)

        let sixNine = TimeRangeParser.parse("6-9")
        XCTAssertEqual(sixNine?.startHour, 18)
        XCTAssertEqual(sixNine?.endHour, 21)

        let dentist = EventExtractor.drafts(from: "dentist tomorrow at 2")[0]
        XCTAssertEqual(Calendar.current.component(.hour, from: dentist.start), 14)
        XCTAssertNotEqual(Calendar.current.component(.hour, from: dentist.start), 2)

        let lunch = EventExtractor.drafts(from: "lunch today at 1")[0]
        XCTAssertEqual(Calendar.current.component(.hour, from: lunch.start), 13)

        let riding = EventExtractor.drafts(from: "riding today at 10")[0]
        XCTAssertEqual(Calendar.current.component(.hour, from: riding.start), 10)
    }

    func testCalendarCardScreenshotKeepsTitleRangeAndAddress() {
        let card = """
        Lunch with friends
        Wed, Sep 23, 12:00–1:00\(String("\u{202F}"))PM
        Location: 100 Example Ave, Springfield, IL 62701
        Notes: Please bring drinks
        """
        let drafts = EventExtractor.drafts(from: card)
        XCTAssertEqual(drafts.count, 1, "a calendar card is one appointment")
        let draft = drafts[0]
        XCTAssertEqual(draft.title, "Lunch with friends")
        XCTAssertTrue(draft.hasDate)
        XCTAssertTrue(draft.hasTime)
        XCTAssertFalse(draft.durationAssumed)
        XCTAssertEqual(draft.durationMinutes, 60)
        let parts = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: draft.start)
        XCTAssertEqual(parts.month, 9)
        XCTAssertEqual(parts.day, 23)
        XCTAssertEqual(parts.hour, 12)
        XCTAssertEqual(parts.minute, 0)
        XCTAssertTrue(draft.location.contains("100"), draft.location)
        XCTAssertTrue(draft.location.localizedCaseInsensitiveContains("Springfield"), draft.location)
        XCTAssertFalse(draft.title.localizedCaseInsensitiveContains("Notes"))
        XCTAssertFalse(draft.title.localizedCaseInsensitiveContains("bring drinks"))
    }

    func testCalendarCardStillParsesWhenOCRPastesOneLine() {
        let blob = "Lunch with friends Wed, Sep 23, 12:00–1:00 PM Location: 100 Example Ave, Springfield, IL 62701 Notes: Please bring drinks"
        let draft = EventExtractor.drafts(from: blob)[0]
        XCTAssertEqual(draft.title, "Lunch with friends")
        XCTAssertEqual(Calendar.current.component(.hour, from: draft.start), 12)
        XCTAssertEqual(draft.durationMinutes, 60)
        XCTAssertTrue(draft.location.contains("100"), draft.location)
    }

    func testSpokenPhraseIsNotForcedIntoACalendarCard() {
        let drafts = EventExtractor.drafts(from: "dentist tomorrow at 2 at McDonald's")
        XCTAssertEqual(drafts.count, 1)
        XCTAssertTrue(drafts[0].title.localizedCaseInsensitiveContains("dentist"))
        XCTAssertTrue(drafts[0].hasTime)
    }

    func testAppointmentDetailsPortalExtractsExamWindowAndAddress() {
        assertPhysicalExamDraft(from: Self.appointmentDetailsOCR)
    }

    func testPortalTitleIsPhysicalExamNeverCheckInLabel() {
        let stackedLabels = """
        Appointment Details
        Appointment Type
        Check-in Time
        2:15 PM
        Appointment Time
        2:30 PM – 3:15 PM
        Date Tuesday, October 14, 2026
        Annual Physical Exam Confirmed
        Location Peninsula Family Health
        Address 11800 Willow Road, Suite 240, Menlo Park, CA 94025
        """
        for sample in [Self.appointmentDetailsOCR, Self.appointmentDetailsMessyOCR, stackedLabels] {
            let draft = EventExtractor.drafts(from: sample)[0]
            XCTAssertTrue(
                draft.title.localizedCaseInsensitiveContains("Physical Exam"),
                "title must be the exam, not a label: \(draft.title)\n\(sample)"
            )
            XCTAssertFalse(
                draft.title.localizedCaseInsensitiveContains("Check-in"),
                "Check-in Time is a label, not the title: \(draft.title)"
            )
            XCTAssertFalse(draft.title.localizedCaseInsensitiveContains("Appointment Time"), draft.title)
            XCTAssertFalse(draft.title.localizedCaseInsensitiveContains("Appointment Details"), draft.title)
            XCTAssertFalse(draft.title == "Date" || draft.title.localizedCaseInsensitiveCompare("Date") == .orderedSame, draft.title)
            XCTAssertFalse(draft.title.localizedCaseInsensitiveContains("Alex"), draft.title)
        }
    }

    func testAppointmentDetailsPortalHandlesMessyOCR() {
        assertPhysicalExamDraft(from: Self.appointmentDetailsMessyOCR, locationMayBeMessy: true)
        let cleaned = OCRTextNormalizer.normalize(Self.appointmentDetailsMessyOCR)
        XCTAssertTrue(cleaned.localizedCaseInsensitiveContains("Appointment"), cleaned)
        XCTAssertTrue(cleaned.localizedCaseInsensitiveContains("Peninsula"), cleaned)
        XCTAssertTrue(cleaned.localizedCaseInsensitiveContains("Family"), cleaned)
        assertPhysicalExamDraft(from: cleaned)
    }

    func testAppointmentDetailsPortalReadsDashlessAndOneLineOCR() {
        let dashless = """
        Appointment Details
        Annual Physical Exam Confirmed
        Appointment Type Annual Physical Exam
        Date Tuesday, October 14, 2026
        Check-in Time 2:15 PM
        Appointment Time 2:30 PM
        3:15 PM
        Location Peninsula Family Health
        Address 11800 Willow Road, Suite 240, Menlo Park, CA 94025
        Notes Please bring your insurance card and photo ID.
        """
        assertPhysicalExamDraft(from: dashless)

        let oneLine = "Appointment Details Annual Physical Exam Confirmed Peninsula Family Health Appointment Type Annual Physical Exam Date Tuesday, October 14, 2026 Check-in Time 2:15 PM Appointment Time 2:30 PM – 3:15 PM Location Peninsula Family Health Address 11800 Willow Road, Suite 240, Menlo Park, CA 94025 Notes Please bring your insurance card and photo ID. Arrive 15 minutes early."
        assertPhysicalExamDraft(from: oneLine)
    }

    func testPortalLatestClockIsEndNotAppointmentStart() throws {
        let page = CalendarCardParser.lineated(OCRTextNormalizer.normalize(Self.appointmentDetailsOCR))
        let fields = CalendarCardParser.fields(from: page)
        let window = try XCTUnwrap(CalendarCardParser.portalAppointmentWindow(fields: fields, page: page))
        XCTAssertEqual(window.range.startHour, 14)
        XCTAssertEqual(window.range.startMinute, 30)
        XCTAssertEqual(window.range.endHour, 15)
        XCTAssertEqual(window.range.endMinute, 15)
        XCTAssertEqual(window.range.durationMinutes, 45)
        XCTAssertTrue(
            window.endToken.replacingOccurrences(of: " ", with: "").localizedCaseInsensitiveContains("3:15"),
            "end token is latest clock 3:15 PM, not 2:30: \(window.endToken)"
        )
        XCTAssertFalse(
            window.endToken.replacingOccurrences(of: " ", with: "").localizedCaseInsensitiveContains("2:30"),
            "appointment start must not be the end token: \(window.endToken)"
        )

        let clocks = ClockTimeParser.all(in: page)
        XCTAssertEqual(Set(clocks.map { "\($0.hour):\($0.minute)" }), ["14:15", "14:30", "15:15"])
        let latest = try XCTUnwrap(ClockTimeParser.latest(in: page))
        XCTAssertEqual(latest.hour, 15)
        XCTAssertEqual(latest.minute, 15)
        XCTAssertTrue(latest.matchedText(in: page).replacingOccurrences(of: " ", with: "").localizedCaseInsensitiveContains("3:15"))

        let draft = EventExtractor.drafts(from: Self.appointmentDetailsOCR)[0]
        let calendar = Calendar.current
        XCTAssertEqual(calendar.component(.hour, from: draft.start), 14)
        XCTAssertEqual(calendar.component(.minute, from: draft.start), 30)
        XCTAssertEqual(calendar.component(.hour, from: draft.end), 15)
        XCTAssertEqual(calendar.component(.minute, from: draft.end), 15)
        XCTAssertEqual(draft.extraBeforeMinutes, 0)
        XCTAssertEqual(calendar.component(.minute, from: try XCTUnwrap(draft.arriveBy)), 15)
    }

    func testPortalLatestClockWinsEvenWhenTimesAreOutOfOrder() {
        let scrambled = """
        Appointment Details
        Annual Physical Exam Confirmed
        Appointment Type Annual Physical Exam
        Date Tuesday, October 14, 2026
        Appointment Time 2:30 PM
        3:15 PM
        Location Peninsula Family Health
        Address 11800 Willow Road, Suite 240, Menlo Park, CA 94025
        Check-in Time 2:15 PM
        Notes Please bring your insurance card and photo ID. Arrive 15 minutes early.
        """
        assertPhysicalExamDraft(from: scrambled)
        XCTAssertEqual(ClockTimeParser.parse(scrambled)?.hour, 14, "last mentioned is check-in 2:15")
        XCTAssertEqual(ClockTimeParser.parse(scrambled)?.minute, 15)
        XCTAssertEqual(ClockTimeParser.latest(in: scrambled)?.hour, 15, "latest of day is 3:15, not last mentioned")
        XCTAssertEqual(ClockTimeParser.latest(in: scrambled)?.minute, 15)
    }

    func testPortalCheckInIsArrivalTargetNotExtraBeforeChip() throws {
        let fields = CalendarCardParser.fields(from: Self.appointmentDetailsOCR)
        XCTAssertEqual(fields.checkIn?.contains("2:15"), true, "check-in=\(fields.checkIn ?? "nil")")
        let draft = EventExtractor.drafts(from: Self.appointmentDetailsOCR)[0]
        let calendar = Calendar.current
        XCTAssertEqual(calendar.component(.hour, from: draft.start), 14)
        XCTAssertEqual(calendar.component(.minute, from: draft.start), 30)
        XCTAssertEqual(calendar.component(.hour, from: draft.end), 15)
        XCTAssertEqual(calendar.component(.minute, from: draft.end), 15)
        XCTAssertEqual(draft.durationMinutes, 45)
        XCTAssertEqual(draft.extraBeforeMinutes, 0, "do not double-count the matching 15")
        let arrival = try XCTUnwrap(draft.arriveBy)
        XCTAssertEqual(calendar.component(.hour, from: arrival), 14)
        XCTAssertEqual(calendar.component(.minute, from: arrival), 15)
        XCTAssertEqual(draft.arrivalTarget, arrival)

        let estimate = TravelEstimator.estimate(
            minutes: 20,
            mode: .drive,
            start: draft.arrivalTarget,
            bufferMinutes: 5,
            extraBeforeMinutes: draft.extraBeforeMinutes
        )
        XCTAssertEqual(
            estimate.leaveBy,
            arrival.addingTimeInterval(-25 * 60),
            "leave-by = check-in 2:15 − drive − buffer, not 2:30"
        )
        XCTAssertNotEqual(
            estimate.leaveBy,
            draft.start.addingTimeInterval(-25 * 60),
            "leave-by must not treat official start as the arrive-by"
        )

        let official = TravelEstimator.appointmentWindow(from: draft.start, to: draft.end)
        XCTAssertTrue(official.contains("2:30") || official.contains("14:30"), official)
        XCTAssertTrue(official.contains("3:15") || official.contains("15:15"), official)

        let notes = TravelEstimator.noteLines(
            appointmentStart: draft.start,
            appointmentEnd: draft.end,
            travel: estimate,
            place: draft.location,
            extraBeforeMinutes: draft.extraBeforeMinutes,
            arriveBy: draft.arriveBy
        )
        XCTAssertEqual(notes[0], "Appointment: \(official)")
        XCTAssertTrue(notes.contains { $0.hasPrefix("Leave by") })
        XCTAssertEqual(
            TravelEstimator.leaveBy(
                start: draft.arrivalTarget,
                travelMinutes: 20,
                bufferMinutes: 5,
                extraBeforeMinutes: 0
            ),
            estimate.leaveBy
        )

        let block = TravelEstimator.calendarBlock(
            start: draft.arrivalTarget,
            end: draft.end,
            travel: estimate,
            extraBeforeMinutes: draft.extraBeforeMinutes
        )
        XCTAssertEqual(block.start, estimate.leaveBy)
        XCTAssertEqual(draft.asHomeGapStop().extraBeforeMinutes, 15, "home-gap still has to make 2:15")
    }

    func testOCRCleanupLeavesSpokenPhrasesAlone() {
        let spoken = "dentist tomorrow at 2 at McDonald's"
        XCTAssertEqual(OCRTextNormalizer.normalize(spoken), spoken)
        let riding = "riding lesson at westwind community barn tomorrow at 4"
        XCTAssertEqual(OCRTextNormalizer.normalize(riding), riding)
    }

    private func assertPhysicalExamDraft(from text: String, locationMayBeMessy: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        let drafts = EventExtractor.drafts(from: text)
        XCTAssertEqual(drafts.count, 1, "portal screenshot is one appointment: \(text)", file: file, line: line)
        let draft = drafts[0]
        XCTAssertEqual(draft.title, "Annual Physical Exam", file: file, line: line)
        XCTAssertFalse(draft.title.localizedCaseInsensitiveContains("Details"), file: file, line: line)
        XCTAssertFalse(draft.title.localizedCaseInsensitiveContains("Alex"), file: file, line: line)
        XCTAssertFalse(draft.title.localizedCaseInsensitiveContains("Rivera"), file: file, line: line)

        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: draft.start)
        XCTAssertEqual(parts.year, 2026, file: file, line: line)
        XCTAssertEqual(parts.month, 10, file: file, line: line)
        XCTAssertEqual(parts.day, 14, file: file, line: line)
        XCTAssertEqual(parts.hour, 14, "appointment starts at 2:30 PM, not check-in: \(draft.start)", file: file, line: line)
        XCTAssertEqual(parts.minute, 30, file: file, line: line)
        XCTAssertTrue(draft.hasDate, file: file, line: line)
        XCTAssertTrue(draft.hasTime, file: file, line: line)
        XCTAssertFalse(draft.durationAssumed, "2:30–3:15 is on the page", file: file, line: line)
        XCTAssertEqual(draft.durationMinutes, 45, file: file, line: line)
        let endParts = Calendar.current.dateComponents([.hour, .minute], from: draft.end)
        XCTAssertEqual(endParts.hour, 15, "end is latest clock 3:15 PM, not appointment start 2:30: \(draft.end)", file: file, line: line)
        XCTAssertEqual(endParts.minute, 15, file: file, line: line)
        let page = CalendarCardParser.lineated(OCRTextNormalizer.normalize(text))
        let latestClock = ClockTimeParser.latest(in: page)
        XCTAssertEqual(latestClock?.hour, 15, "latest clock must be 3:15: \(latestClock?.matchedText(in: page) ?? "nil")", file: file, line: line)
        XCTAssertEqual(latestClock?.minute, 15, file: file, line: line)
        let endToken = latestClock?.matchedText(in: page) ?? ""
        XCTAssertTrue(
            endToken.replacingOccurrences(of: " ", with: "").localizedCaseInsensitiveContains("3:15"),
            "end token should be 3:15, got \(endToken)",
            file: file,
            line: line
        )
        XCTAssertEqual(draft.extraBeforeMinutes, 0, "matching arrive-early is check-in, not a second 15", file: file, line: line)
        guard let arrival = draft.arriveBy else {
            XCTFail("check-in must set arriveBy", file: file, line: line)
            return
        }
        let arrivalParts = Calendar.current.dateComponents([.hour, .minute], from: arrival)
        XCTAssertEqual(arrivalParts.hour, 14, "check-in is 2:15 PM: \(arrival)", file: file, line: line)
        XCTAssertEqual(arrivalParts.minute, 15, file: file, line: line)
        XCTAssertEqual(draft.arrivalTarget, arrival, file: file, line: line)
        XCTAssertEqual(draft.checkInLeadMinutes, 15, file: file, line: line)

        if locationMayBeMessy {
            XCTAssertTrue(
                draft.location.localizedCaseInsensitiveContains("Peninsul")
                    || draft.location.localizedCaseInsensitiveContains("Health"),
                draft.location,
                file: file,
                line: line
            )
        } else {
            XCTAssertTrue(draft.location.localizedCaseInsensitiveContains("Peninsula"), draft.location, file: file, line: line)
            XCTAssertTrue(draft.location.localizedCaseInsensitiveContains("Family"), draft.location, file: file, line: line)
            XCTAssertTrue(draft.location.localizedCaseInsensitiveContains("Health"), draft.location, file: file, line: line)
        }
        XCTAssertTrue(draft.location.contains("11800"), draft.location, file: file, line: line)
        XCTAssertTrue(draft.location.localizedCaseInsensitiveContains("Willow"), draft.location, file: file, line: line)
        XCTAssertTrue(draft.location.localizedCaseInsensitiveContains("Menlo"), draft.location, file: file, line: line)

        let extras = (draft.details + [draft.sourceText]).joined(separator: "\n")
        XCTAssertTrue(extras.localizedCaseInsensitiveContains("insurance"), extras, file: file, line: line)
        let bring = WhatToBring.items(title: draft.title, place: draft.location, notes: extras)
        XCTAssertTrue(bring.contains { $0.localizedCaseInsensitiveContains("insurance") }, "\(bring)", file: file, line: line)
        XCTAssertTrue(bring.contains { $0.localizedCaseInsensitiveContains("photo") || $0.localizedCaseInsensitiveContains("ID") }, "\(bring)", file: file, line: line)
    }

    private static let appointmentDetailsOCR = """
    Appointment Details
    Annual Physical Exam Confirmed
    Peninsula Family Health
    Appointment Type Annual Physical Exam
    Patient Alex Rivera
    Provider Dr. Maya Chen, MD
    Date Tuesday, October 14, 2026
    Check-in Time 2:15 PM
    Appointment Time 2:30 PM – 3:15 PM
    Location Peninsula Family Health
    Address 11800 Willow Road, Suite 240, Menlo Park, CA 94025
    Phone (650) 555-0184
    Parking Garage entrance on Oak Avenue
    Notes Please bring your insurance card and photo ID. Arrive 15 minutes early.
    """

    private static let appointmentDetailsMessyOCR = """
    Appointoointment Detailils
    Annual Physical Exam Confirmed
    Peninsulla Familly Healthh
    Appointoointment Typeype Annual Physical Exam
    Patient Alex Rivera
    Provider Dr. Maya Chen, MD
    Dateate Tuesday, October 14, 2026
    Check-in Time 2:15 PM
    Appointoointment Time 2:30 PM – 3:15 PM
    Location Peninsulla Familly Healthh
    Address 11800 Willow Road, Suite 240, Menlo Park, CA 94025
    Phone (650) 555-0184
    Parking Garage entrance on Oak Avenue
    Notes Please bring your insurance card and photo ID. Arrive 15 minutes early.
    """

    func testConflictsTouchingEndpointsDoNotOverlap() {
        let calendar = Calendar.current
        let start = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: Date())!
        let end = start.addingTimeInterval(3600)
        let next = end.addingTimeInterval(3600)
        XCTAssertTrue(ConflictLogic.overlaps(start: start, end: end, otherStart: start.addingTimeInterval(1800), otherEnd: next))
        XCTAssertFalse(ConflictLogic.overlaps(start: start, end: end, otherStart: end, otherEnd: next))
    }

    func testPlaceMemoryRemembersDentistAndSkipsMcdonalds() {
        PlaceMemory.resetForTests()
        defer { PlaceMemory.resetForTests() }

        XCTAssertTrue(PlaceMemory.isGenericPOI("mcdonalds"))
        XCTAssertFalse(PlaceMemory.isGenericPOI("dentist"))
        XCTAssertTrue(PlaceMemory.shouldPreferMemory(title: "dentist", locationQuery: "dentist"))
        XCTAssertTrue(PlaceMemory.shouldPreferMemory(title: "dentist", locationQuery: ""))
        XCTAssertFalse(PlaceMemory.shouldPreferMemory(title: "mcdonalds", locationQuery: "mcdonalds"))

        PlaceMemory.remember(title: "dentist", location: "Stanford Hospital", latitude: 37.43, longitude: -122.17)
        let remembered = PlaceMemory.remembered(forTitle: "dentist")
        XCTAssertEqual(remembered?.location, "Stanford Hospital")

        PlaceMemory.remember(title: "mcdonalds", location: "123 Main", latitude: nil, longitude: nil)
        XCTAssertNil(PlaceMemory.remembered(forTitle: "mcdonalds"))
    }

    func testMultiWordVenueSearchesWholePhraseAndAllowsNearbyFallback() {
        let plan = PlaceResolver.searchPlan(for: "westwind community barn")
        XCTAssertEqual(plan.fullPhrase, "westwind community barn", "the whole venue name must be searched, not a fragment")
        XCTAssertTrue(plan.isDistinctiveVenue)
        XCTAssertFalse(
            plan.prefersNamedArea,
            "\"community barn\" is part of the venue name, not an area — the nearby/home/unscoped chain must stay available"
        )
    }

    func testVenueQueryIsNotTreatedAsAnAddressOrGenericBrand() {
        XCTAssertFalse(PlaceResolver.isSpecificAddress("westwind community barn"))
        XCTAssertFalse(PlaceMemory.isGenericPOI("westwind community barn"))
        XCTAssertTrue(PlaceResolver.isDistinctiveVenue("westwind community barn"))
        XCTAssertFalse(PlaceResolver.isDistinctiveVenue("mcdonalds"), "a bare chain name is not a distinctive venue")
        XCTAssertFalse(PlaceResolver.isDistinctiveVenue("mcdonalds menlo park"))
    }

    func testVenueNameSurvivesExtractionWithDateAndTime() {
        let drafts = EventExtractor.drafts(from: "westwind community barn tomorrow at 2")
        XCTAssertEqual(drafts.count, 1)
        let draft = drafts[0]
        XCTAssertTrue(draft.hasDate)
        XCTAssertTrue(draft.hasTime)
        XCTAssertTrue(
            draft.location.localizedCaseInsensitiveContains("westwind community barn"),
            "expected the full venue name as the location, got \(draft.location)"
        )
    }

    func testNamedAreaValidationRejectsVenueWordsButKeepsRealCities() {
        let menlo = MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: 37.4529, longitude: -122.1817),
            addressDictionary: ["City": "Menlo Park"]
        )
        XCTAssertTrue(PlaceResolver.looksLikeNamedArea(menlo, area: "menlo park"))
        XCTAssertFalse(
            PlaceResolver.looksLikeNamedArea(menlo, area: "community barn"),
            "part of a venue name must not be accepted as an area"
        )

        let barn = MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: 51.5, longitude: -0.1),
            addressDictionary: ["City": "Barn"]
        )
        XCTAssertFalse(
            PlaceResolver.looksLikeNamedArea(barn, area: "community barn"),
            "a stray place called \"Barn\" must not anchor the search"
        )
    }

    func testBrandPlusAreaStillPinsToNamedArea() {
        let plan = PlaceResolver.searchPlan(for: "mcdonalds menlo park")
        XCTAssertTrue(plan.prefersNamedArea, "brand + area must never fall back to the user or home pin")
        XCTAssertEqual(plan.areaCandidates.first?.area.lowercased(), "menlo park")

        let preposition = PlaceResolver.searchPlan(for: "mcdonalds in menlo park")
        XCTAssertTrue(preposition.prefersNamedArea)

        let bare = PlaceResolver.searchPlan(for: "mcdonalds")
        XCTAssertFalse(bare.prefersNamedArea, "a bare chain name does not pin to a named area")
        XCTAssertEqual(
            bare.originPolicy(homeAddressIsSet: true),
            .home,
            "generic mcdonalds prefers Home when Home is set"
        )
        XCTAssertTrue(bare.areaCandidates.isEmpty)
    }

    func testGenericMcdonaldsOriginPrefersHomeWhenHomeIsSet() {
        XCTAssertEqual(
            PlaceResolver.originPolicy(for: "mcdonalds", homeAddressIsSet: true),
            .home,
            "the closest McDonald's is the one by Home, not Simulator GPS"
        )
        XCTAssertEqual(
            PlaceResolver.originPolicy(for: "McDonald's", homeAddressIsSet: true),
            .home
        )
        XCTAssertEqual(
            PlaceResolver.originPolicy(for: "mcdonalds", homeAddressIsSet: false),
            .currentLocation,
            "current pin is only for closest-to-me when Home is empty"
        )
        XCTAssertEqual(
            PlaceResolver.originPolicy(for: "mcdonalds menlo park", homeAddressIsSet: true),
            .namedArea,
            "a named area still wins over Home"
        )
        XCTAssertEqual(
            PlaceResolver.searchPlan(for: "mcdonalds").originPolicy(homeAddressIsSet: true),
            .home
        )
    }

    func testAreaPrepositionSplit() {
        let split = PlaceResolver.areaPrepositionSplit(from: "mcdonalds near menlo park")
        XCTAssertEqual(split?.place.lowercased(), "mcdonalds")
        XCTAssertEqual(split?.area.lowercased(), "menlo park")
        XCTAssertNil(PlaceResolver.areaPrepositionSplit(from: "westwind community barn"))
    }

    func testUnresolvedVenueStillSaves() {
        var draft = EventExtractor.drafts(from: "westwind community barn tomorrow at 2")[0]
        draft.clearResolvedPlace()
        XCTAssertTrue(draft.hasDate)
        XCTAssertTrue(draft.hasTime)
        XCTAssertTrue(
            draft.locationToSave.localizedCaseInsensitiveContains("westwind community barn"),
            "an unresolved venue keeps the user's own words: \(draft.locationToSave)"
        )
    }

    func testVenueLocationIsRememberedNextTime() {
        PlaceMemory.resetForTests()
        defer { PlaceMemory.resetForTests() }

        PlaceMemory.remember(
            title: "westwind community barn",
            location: "Westwind Community Barn · 27210 Altamont Rd",
            latitude: 37.3576,
            longitude: -122.1503
        )
        XCTAssertTrue(
            PlaceMemory.shouldPreferMemory(title: "westwind community barn", locationQuery: "westwind community barn")
        )
        XCTAssertEqual(
            PlaceMemory.remembered(forTitle: "westwind community barn")?.location,
            "Westwind Community Barn · 27210 Altamont Rd"
        )
    }

    func testLeaveByArithmeticSubtractsDriveTimeAndBuffer() {
        let calendar = Calendar.current
        let start = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: Date())!

        XCTAssertEqual(
            TravelEstimator.leaveBy(start: start, travelMinutes: 25, bufferMinutes: 0),
            start.addingTimeInterval(-25 * 60)
        )
        XCTAssertEqual(
            TravelEstimator.leaveBy(start: start, travelMinutes: 25, bufferMinutes: 10),
            start.addingTimeInterval(-35 * 60),
            "the Settings leaving-home buffer comes off the leave-by time too"
        )
        XCTAssertEqual(
            TravelEstimator.leaveBy(start: start, travelMinutes: 0, bufferMinutes: 0),
            start
        )
        XCTAssertEqual(
            TravelEstimator.leaveBy(start: start, travelMinutes: 25, bufferMinutes: -5),
            start.addingTimeInterval(-25 * 60),
            "a negative buffer must not push the leave-by time later"
        )

        let overnight = calendar.date(bySettingHour: 0, minute: 30, second: 0, of: start)!
        XCTAssertEqual(
            TravelEstimator.leaveBy(start: overnight, travelMinutes: 45, bufferMinutes: 10),
            overnight.addingTimeInterval(-55 * 60),
            "leaving the day before is still just start minus travel minus buffer"
        )
        XCTAssertEqual(
            TravelEstimator.leaveBy(start: start, travelMinutes: 15, bufferMinutes: 5, extraBeforeMinutes: 10),
            start.addingTimeInterval(-30 * 60),
            "leave-by = start − drive − buffer − extra before"
        )
    }

    func testMapsDepartureIsPlannedLeaveByNotNow() {
        let now = Date()
        let start = now.addingTimeInterval(4 * 3600)
        let end = start.addingTimeInterval(3600)

        let seed = TravelEstimator.outboundMapsDeparture(
            start: start,
            knownDriveMinutes: nil,
            bufferMinutes: 5,
            extraBeforeMinutes: 10,
            now: now
        )
        XCTAssertEqual(seed, start.addingTimeInterval(-15 * 60), "first Maps pass is start − buffer − extra-before")
        XCTAssertGreaterThan(seed.timeIntervalSince(now), 3 * 3600, "must not ask Maps for current traffic")

        let leave = TravelEstimator.outboundMapsDeparture(
            start: start,
            knownDriveMinutes: 15,
            bufferMinutes: 5,
            extraBeforeMinutes: 10,
            now: now
        )
        XCTAssertEqual(leave, start.addingTimeInterval(-30 * 60), "second pass is the real leave-by")
        XCTAssertEqual(
            leave,
            TravelEstimator.leaveBy(start: start, travelMinutes: 15, bufferMinutes: 5, extraBeforeMinutes: 10)
        )

        let back = TravelEstimator.returnMapsDeparture(end: end, extraAfterMinutes: 15, now: now)
        XCTAssertEqual(back, end.addingTimeInterval(15 * 60), "return departs when extra-after ends")
        XCTAssertNotEqual(back, now)
    }

    func testDriveTimeLineShowsDurationAndLeaveBy() {
        let calendar = Calendar.current
        let start = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: Date())!
        let estimate = TravelEstimator.estimate(minutes: 25, mode: .drive, start: start, bufferMinutes: 10, returnMinutes: 25)

        XCTAssertEqual(estimate.leaveBy, start.addingTimeInterval(-35 * 60))
        let line = TravelEstimator.line(for: estimate)
        XCTAssertEqual(line, expectedTravelLine(estimate))
        XCTAssertFalse(line.contains("~35 min"), "the 10 min buffer is not added into drive minutes")
        XCTAssertEqual(TravelEstimator.note(for: estimate), expectedTravelNote(estimate))

        let fromHome = TravelEstimator.estimate(
            minutes: 15,
            mode: .drive,
            start: start,
            bufferMinutes: 5,
            returnMinutes: 15,
            fromHome: true
        )
        XCTAssertEqual(TravelEstimator.note(for: fromHome), expectedTravelNote(fromHome))

        let noBuffer = TravelEstimator.estimate(minutes: 25, mode: .drive, start: start, bufferMinutes: 0)
        XCTAssertEqual(TravelEstimator.note(for: noBuffer), expectedTravelNote(noBuffer))
    }

    func testPublicTransportShowsTransitMinutesNotDrive() {
        let start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        let transit = TravelEstimator.estimate(
            minutes: 28,
            mode: .transit,
            start: start,
            bufferMinutes: 0,
            returnMinutes: 30
        )
        let line = TravelEstimator.line(for: transit)
        XCTAssertEqual(line, expectedTravelLine(transit))
        XCTAssertTrue(line.contains("~28"), line)
        XCTAssertEqual(TravelEstimator.noteKind(for: transit), "Transit")
        XCTAssertEqual(TravelEstimator.appointmentModeTitle(for: transit), "Public transport")
        XCTAssertTrue(
            TravelEstimator.accepts(routeTransport: .transit, requested: .transit)
        )
        XCTAssertFalse(
            TravelEstimator.accepts(routeTransport: .automobile, requested: .transit),
            "a car route must not count as public transport"
        )
        XCTAssertEqual(TravelEstimator.noRouteMessage(for: .transit), String(localized: "No transit route"))
        XCTAssertEqual(
            TravelEstimator.loadingMessage(for: .transit),
            String(localized: "Asking Maps for transit time…")
        )
    }

    func testTransitEstimateMinutesDifferFromDriveAndLineUsesTransit() {
        let start = Calendar.current.date(bySettingHour: 10, minute: 16, second: 0, of: Date())!
        let end = start.addingTimeInterval(60 * 60)
        let drive = TravelEstimator.estimate(
            minutes: 12,
            mode: .drive,
            start: start,
            bufferMinutes: 5,
            returnMinutes: 14
        )
        let transit = TravelEstimator.estimate(
            minutes: 28,
            mode: .transit,
            start: start,
            bufferMinutes: 5,
            returnMinutes: 31
        )

        XCTAssertNotEqual(transit.minutes, drive.minutes, "when both exist, transit minutes must not copy drive minutes")
        XCTAssertNotEqual(transit.leaveBy, drive.leaveBy)
        XCTAssertEqual(transit.minutes, 28)
        XCTAssertEqual(drive.minutes, 12)

        let transitLine = TravelEstimator.line(for: transit)
        let driveLine = TravelEstimator.line(for: drive)
        XCTAssertNotEqual(transitLine, driveLine)
        XCTAssertEqual(transitLine, expectedTravelLine(transit))
        XCTAssertTrue(transitLine.contains("~28"), transitLine)
        XCTAssertFalse(transitLine.contains("~12"), transitLine)
        XCTAssertEqual(driveLine, expectedTravelLine(drive))
        XCTAssertTrue(driveLine.contains("~12"), driveLine)

        let transitNotes = TravelEstimator.noteLines(
            appointmentStart: start,
            appointmentEnd: end,
            travel: transit,
            place: "McDonald's · 1100 El Camino Real, Menlo Park"
        )
        XCTAssertEqual(transitNotes[1], "Travel: Public transport")
        XCTAssertTrue(transitNotes[2].hasPrefix("Transit: ~28 min there"), transitNotes[2])
        XCTAssertFalse(transitNotes.contains { $0.hasPrefix("Drive:") })
        XCTAssertFalse(transitNotes.contains { $0.contains("~12 min") })

        let driveNotes = TravelEstimator.noteLines(
            appointmentStart: start,
            appointmentEnd: end,
            travel: drive,
            place: "McDonald's · 1100 El Camino Real, Menlo Park"
        )
        XCTAssertEqual(driveNotes[1], "Travel: Driving")
        XCTAssertTrue(driveNotes[2].hasPrefix("Drive: ~12 min there"), driveNotes[2])

        XCTAssertEqual(
            TravelEstimator.labeledSavedLine("~28 min there, ~31 min back", mode: .transit),
            TravelEstimator.localizedRoundTrip(outbound: 28, back: 31, total: 59, mode: .transit)
        )
        XCTAssertEqual(
            TravelEstimator.labeledSavedLine("~12 min there, ~14 min back", mode: .drive),
            TravelEstimator.localizedRoundTrip(outbound: 12, back: 14, total: 26, mode: .drive)
        )
    }

    func testTravelChromeLocalizesWhileSavedNotesStayEnglish() {
        let window = "8:31 PM – 10:15 PM"
        XCTAssertEqual(
            localizedFormat(
                "Calendar %@, with drive",
                language: "fr",
                window
            ),
            "Calendrier 8:31 PM – 10:15 PM, avec trajet"
        )
        XCTAssertEqual(
            localizedFormat(
                "Calendar %@, with drive",
                language: "de",
                window
            ),
            "Kalender 8:31 PM – 10:15 PM, mit Fahrt"
        )
        XCTAssertEqual(
            localizedFormat(
                "~%lld min drive · ~%lld min back · ~%lld min round trip",
                language: "fr",
                19, 15, 34
            ),
            "~19 min en voiture · ~15 min retour · ~34 min aller-retour"
        )
        XCTAssertEqual(
            localizedFormat(
                "~%lld min drive · ~%lld min back · ~%lld min round trip",
                language: "de",
                19, 15, 34
            ),
            "~19 Min. mit dem Auto · ~15 Min. zurück · ~34 Min. Hin und zurück"
        )

        let start = Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: Date())!
        let end = start.addingTimeInterval(3600)
        let estimate = TravelEstimator.estimate(
            minutes: 19,
            mode: .drive,
            start: start,
            bufferMinutes: 0,
            returnMinutes: 15
        )
        let notes = TravelEstimator.noteLines(
            appointmentStart: start,
            appointmentEnd: end,
            travel: estimate,
            place: "Westwind"
        )
        XCTAssertTrue(notes.contains { $0.hasPrefix("Drive: ~19 min there, ~15 min back") }, notes.joined(separator: "\n"))
        XCTAssertTrue(notes.contains { $0.hasPrefix("Leave by") }, notes.joined(separator: "\n"))
        XCTAssertTrue(notes.contains { $0.hasPrefix("Travel: Driving") }, notes.joined(separator: "\n"))
    }

    func testPhotoTranscriptDropsWeirdSymbols() {
        let raw = "Annual ★ Physical ◆ Exam\n• Check-in Time ¦ 2:15 PM\nAddress: 11800 Willow Road �"
        let cleaned = OCRTextNormalizer.readablePhotoTranscript(raw)
        XCTAssertTrue(cleaned.localizedCaseInsensitiveContains("Annual Physical Exam"), cleaned)
        XCTAssertTrue(cleaned.contains("2:15"), cleaned)
        XCTAssertTrue(cleaned.contains("11800"), cleaned)
        XCTAssertFalse(cleaned.contains("★"), cleaned)
        XCTAssertFalse(cleaned.contains("◆"), cleaned)
        XCTAssertFalse(cleaned.contains("¦"), cleaned)
        XCTAssertFalse(cleaned.contains("�"), cleaned)
        XCTAssertFalse(cleaned.contains("•"), cleaned)
    }

    func testDriveIsTheDefaultTravelModeAndMapsToAutomobile() {
        XCTAssertEqual(TravelMode(rawValue: TravelMode.drive.rawValue), .drive)
        XCTAssertEqual(TravelMode(rawValue: "nonsense") ?? .drive, .drive, "an unset preference means drive")
        XCTAssertEqual(TravelEstimator.transportType(for: .drive), .automobile)
        XCTAssertEqual(TravelEstimator.transportType(for: .transit), .transit)
        XCTAssertEqual(TravelEstimator.transportType(for: .walk), .walking)
        XCTAssertEqual(TravelMode.drive.travelLabel, "drive")
    }

    func testStackKeepsBothAppointmentsWhenOneUsesATimeRange() {
        let drafts = EventExtractor.drafts(from: "dentist tomorrow 6-9 and lunch friday at 1")
        XCTAssertEqual(drafts.count, 2, "an explicit range must not swallow the second appointment")
        XCTAssertTrue(drafts.allSatisfy { $0.hasDate && $0.hasTime })
    }

    func testSavedEventNotesLinkBackToOriginal() {
        let notes = EventNotes.body(forOriginal: "westwind community barn tomorrow at 2")
        XCTAssertTrue(notes.contains(EventNotes.marker))
        XCTAssertEqual(EventNotes.original(from: notes), "westwind community barn tomorrow at 2")
        XCTAssertEqual(EventNotes.body(forOriginal: "   "), EventNotes.marker)
        XCTAssertNil(EventNotes.original(from: EventNotes.marker))
        XCTAssertNil(EventNotes.original(from: nil))
    }

    /// The ••• menu was removed; delete moved to a visible trash button and "view original"
    /// to a row tap, so the row must still be able to find its original text.
    func testRowFindsOriginalFromStoreOrEventNotes() {
        let stored = TodayItem(
            id: "scedra-test-event",
            title: "Barn visit",
            start: Date(),
            end: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            notes: nil
        )
        OriginalTextStore.save("typed at the barn", for: stored.id)
        defer { OriginalTextStore.remove(stored.id) }
        XCTAssertEqual(stored.originalText, "typed at the barn")

        let fromNotes = TodayItem(
            id: "no-local-map",
            title: "Barn visit",
            start: Date(),
            end: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            notes: EventNotes.body(forOriginal: "spoken at the barn")
        )
        XCTAssertEqual(fromNotes.originalText, "spoken at the barn")

        let foreign = TodayItem(
            id: "someone-elses-event",
            title: "Team sync",
            start: Date(),
            end: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            notes: "Weekly sync"
        )
        XCTAssertNil(foreign.originalText, "a non-Scedra event has no original to show")
    }

    // MARK: - Drive there and back

    func testRoundTripDoesNotGuessAReturnLeg() {
        let start = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date())!

        let unknownReturn = TravelEstimator.estimate(minutes: 25, mode: .drive, start: start, bufferMinutes: 0)
        XCTAssertNil(unknownReturn.routedReturnMinutes, "Apple Maps did not route the way home — do not copy 25")
        XCTAssertEqual(unknownReturn.roundTripMinutes, 25)
        XCTAssertEqual(TravelEstimator.legSummary(for: unknownReturn), TravelEstimator.localizedLegMinutes(25, mode: .drive))
        XCTAssertEqual(TravelEstimator.line(for: unknownReturn), expectedTravelLine(unknownReturn))

        let slowerHome = TravelEstimator.estimate(
            minutes: 25,
            mode: .drive,
            start: start,
            bufferMinutes: 0,
            returnMinutes: 34
        )
        XCTAssertEqual(slowerHome.roundTripMinutes, 59)
        XCTAssertEqual(TravelEstimator.legSummary(for: slowerHome), TravelEstimator.localizedThereAndBack(outbound: 25, back: 34, mode: .drive))

        let nonsenseReturn = TravelEstimator.estimate(
            minutes: 25,
            mode: .drive,
            start: start,
            bufferMinutes: 0,
            returnMinutes: -10
        )
        XCTAssertNil(nonsenseReturn.routedReturnMinutes, "a negative return is not an Apple Maps route")
        XCTAssertEqual(nonsenseReturn.roundTripMinutes, 25)
    }

    func testAppleMapsSecondsBecomeDriveMinutesAndNeverDefaultToSixty() {
        XCTAssertEqual(TravelEstimator.minutesFromExpectedTravelTime(12 * 60), 12)
        XCTAssertEqual(TravelEstimator.minutesFromExpectedTravelTime(8.4 * 60), 8)
        XCTAssertEqual(TravelEstimator.minutesFromExpectedTravelTime(8.6 * 60), 9)
        XCTAssertNil(TravelEstimator.minutesFromExpectedTravelTime(0), "no route is not a guess")
        XCTAssertNil(TravelEstimator.minutesFromExpectedTravelTime(-1))
        XCTAssertEqual(
            TravelEstimator.minutesFromExpectedTravelTime(3600),
            60,
            "60 is allowed only when Apple Maps actually returned 3600 seconds"
        )
        XCTAssertEqual(
            TravelEstimator.minutesFromExpectedTravelTime(15 * 60),
            15,
            "900 seconds is 15 minutes — divide by 60 once"
        )
    }

    func testDisplayedDriveMinutesExcludeBufferAndAppointment() {
        let start = Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: Date())!
        let appointmentMinutes = 60
        let estimate = TravelEstimator.estimate(
            minutes: 15,
            mode: .drive,
            start: start,
            bufferMinutes: 5,
            returnMinutes: 15,
            fromHome: true
        )
        XCTAssertEqual(estimate.minutes, 15)
        XCTAssertEqual(estimate.routedReturnMinutes, 15)
        XCTAssertEqual(estimate.roundTripMinutes, 30)
        XCTAssertNotEqual(estimate.routedReturnMinutes, appointmentMinutes + 15)
        XCTAssertNotEqual(estimate.roundTripMinutes, 15 + appointmentMinutes + 15)
        XCTAssertEqual(estimate.leaveBy, start.addingTimeInterval(-20 * 60))
        let line = TravelEstimator.line(for: estimate)
        XCTAssertEqual(line, expectedTravelLine(estimate))
        XCTAssertFalse(line.contains("~20 min"), "buffer is not in the drive figures")
        XCTAssertFalse(line.contains("~75 min"), "appointment length is not in round trip")
        XCTAssertEqual(UserProfile.defaultHomeGapMinutes, 5)
    }

    func testAssumedHourAppointmentIsNotUsedAsDriveTime() {
        let draft = EventExtractor.drafts(from: "mcdonalds today at 3")[0]
        XCTAssertTrue(draft.durationAssumed)
        XCTAssertEqual(draft.durationMinutes, 60)

        let drive = TravelEstimator.estimate(minutes: 12, mode: .drive, start: draft.start, bufferMinutes: 0)
        XCTAssertNotEqual(drive.minutes, draft.durationMinutes)
        XCTAssertEqual(drive.minutes, 12)

        let block = TravelEstimator.calendarBlock(start: draft.start, end: draft.end, travel: drive)
        XCTAssertEqual(block.start, draft.start.addingTimeInterval(-12 * 60))
        XCTAssertEqual(block.end, draft.end, "no return route means no guessed return padding")

        let none = TravelEstimator.calendarBlock(start: draft.start, end: draft.end, travel: nil)
        XCTAssertEqual(none.end.timeIntervalSince(none.start), TimeInterval(draft.durationMinutes * 60))
        XCTAssertEqual(TravelEstimator.noRouteMessage, String(localized: "No drive time from Maps"))
    }

    func testPreferredOriginUsesHomeForReviewPlanning() {
        let applePark = CLLocation(latitude: 37.3349, longitude: -122.0090)
        let home = CLLocation(latitude: 37.4419, longitude: -122.1430)

        XCTAssertFalse(TravelEstimator.shouldTrustCurrentFix(homeAddressIsSet: true, isSimulator: true))
        XCTAssertFalse(
            TravelEstimator.shouldTrustCurrentFix(homeAddressIsSet: true, isSimulator: false),
            "live GPS is leave-now later — Review planning uses Home"
        )
        XCTAssertTrue(TravelEstimator.shouldTrustCurrentFix(homeAddressIsSet: false, isSimulator: true))
        XCTAssertTrue(TravelEstimator.shouldTrustCurrentFix(homeAddressIsSet: false, isSimulator: false))

        let fromHome = TravelEstimator.preferredOrigin(current: applePark, home: home, currentIsTrusted: true)
        XCTAssertEqual(fromHome?.coordinate.latitude, home.coordinate.latitude)
        XCTAssertEqual(fromHome?.coordinate.longitude, home.coordinate.longitude)

        let fromDevice = TravelEstimator.preferredOrigin(current: applePark, home: nil, currentIsTrusted: true)
        XCTAssertEqual(fromDevice?.coordinate.latitude, applePark.coordinate.latitude)

        XCTAssertNil(TravelEstimator.preferredOrigin(current: applePark, home: nil, currentIsTrusted: false))

        let appleParkFix = CLLocation(
            coordinate: applePark.coordinate,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10,
            timestamp: Date()
        )
        XCTAssertTrue(
            LocationProvider.isUsableFix(appleParkFix),
            "Simulator Apple Park is a real Core Location fix, not an invalid pin"
        )
        let stale = CLLocation(
            coordinate: applePark.coordinate,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10,
            timestamp: Date().addingTimeInterval(-1_000)
        )
        XCTAssertFalse(LocationProvider.isUsableFix(stale))
        let wildAccuracy = CLLocation(
            coordinate: applePark.coordinate,
            altitude: 0,
            horizontalAccuracy: 5_000,
            verticalAccuracy: 10,
            timestamp: Date()
        )
        XCTAssertFalse(LocationProvider.isUsableFix(wildAccuracy))
    }

    func testNotesBlockStatesRealAppointmentTimeThenDriveThenPlace() {
        let calendar = Calendar.current
        let start = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: Date())!
        let end = start.addingTimeInterval(3 * 3600)
        let estimate = TravelEstimator.estimate(minutes: 25, mode: .drive, start: start, bufferMinutes: 10, returnMinutes: 25)

        let lines = TravelEstimator.noteLines(
            appointmentStart: start,
            appointmentEnd: end,
            travel: estimate,
            place: "Westwind Community Barn · 27210 Altamont Rd, Los Altos Hills"
        )
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(
            lines[0],
            "Appointment: \(TravelEstimator.appointmentWindow(from: start, to: end))",
            "the official time comes first so a padded block is never confusing"
        )
        XCTAssertEqual(lines[1], "Travel: Driving")
        XCTAssertEqual(lines[2], "Drive: ~25 min there, ~25 min back (~50 min round trip)")
        XCTAssertEqual(lines[3], "Leave by \(start.addingTimeInterval(-35 * 60).formatted(date: .omitted, time: .shortened))")
        XCTAssertEqual(lines[4], "Westwind Community Barn · 27210 Altamont Rd, Los Altos Hills")
    }

    func testNotesBlockWritesNoDriveLinesWhenDriveTimeIsUnknown() {
        let start = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date())!
        let end = start.addingTimeInterval(3 * 3600)

        let lines = TravelEstimator.noteLines(
            appointmentStart: start,
            appointmentEnd: end,
            travel: nil,
            place: "Westwind Community Barn"
        )
        XCTAssertEqual(lines, ["Westwind Community Barn"], "no estimate means no drive lines and no placeholder")
        XCTAssertFalse(lines.contains { $0.localizedCaseInsensitiveContains("unknown") })

        XCTAssertTrue(
            TravelEstimator.noteLines(appointmentStart: start, appointmentEnd: end, travel: nil, place: "  ").isEmpty
        )
    }

    func testSavedNotesKeepOriginalIntactBelowTheDriveDetails() {
        let calendar = Calendar.current
        let start = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: Date())!
        let end = start.addingTimeInterval(3 * 3600)
        let estimate = TravelEstimator.estimate(minutes: 25, mode: .drive, start: start, bufferMinutes: 10)
        let details = TravelEstimator.noteLines(
            appointmentStart: start,
            appointmentEnd: end,
            travel: estimate,
            place: "Westwind Community Barn · 27210 Altamont Rd"
        )

        let notes = EventNotes.body(forOriginal: "westwind community barn tomorrow 6-9", details: details)
        XCTAssertTrue(notes.hasPrefix(EventNotes.marker), notes)
        XCTAssertTrue(notes.contains("Drive: ~25 min there"), notes)
        XCTAssertEqual(
            EventNotes.original(from: notes),
            "westwind community barn tomorrow 6-9",
            "the drive block must not leak into View original"
        )
        XCTAssertEqual(
            EventNotes.body(forOriginal: "typed words", details: []),
            EventNotes.body(forOriginal: "typed words"),
            "no details means the notes are exactly what they were before"
        )
    }

    // MARK: - Travel-wrapped calendar block

    func testCalendarBlockWrapsDriveWhileAppointmentStaysPut() {
        let calendar = Calendar.current
        let start = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: Date())!
        let end = start.addingTimeInterval(3 * 3600)
        let estimate = TravelEstimator.estimate(minutes: 25, mode: .drive, start: start, bufferMinutes: 0, returnMinutes: 25)

        let block = TravelEstimator.calendarBlock(start: start, end: end, travel: estimate)
        XCTAssertTrue(block.isPadded)
        XCTAssertEqual(block.start, start.addingTimeInterval(-25 * 60), "the block opens when she has to leave")
        XCTAssertEqual(block.end, end.addingTimeInterval(25 * 60), "the block closes when she gets home")
        XCTAssertNotNil(TravelEstimator.blockLabel(for: block))

        // The stated 6-9 is untouched: only the saved block moved.
        XCTAssertEqual(start, calendar.date(bySettingHour: 18, minute: 0, second: 0, of: start))
        XCTAssertEqual(end.timeIntervalSince(start), 3 * 3600)
    }

    func testCalendarBlockIncludesLeavingHomeBufferOnTheOutboundSideOnly() {
        let start = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date())!
        let end = start.addingTimeInterval(3 * 3600)
        let estimate = TravelEstimator.estimate(minutes: 25, mode: .drive, start: start, bufferMinutes: 10, returnMinutes: 25)

        let block = TravelEstimator.calendarBlock(start: start, end: end, travel: estimate)
        XCTAssertEqual(block.start, estimate.leaveBy, "the block starts at the same leave-by time she is shown")
        XCTAssertEqual(block.start, start.addingTimeInterval(-35 * 60))
        XCTAssertEqual(block.end, end.addingTimeInterval(25 * 60), "the buffer is for leaving home, not for coming back")
    }

    func testCalendarBlockAddsNoPaddingWithoutADriveEstimate() {
        let start = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date())!
        let end = start.addingTimeInterval(3 * 3600)

        let noEstimate = TravelEstimator.calendarBlock(start: start, end: end, travel: nil)
        XCTAssertEqual(noEstimate.start, start)
        XCTAssertEqual(noEstimate.end, end)
        XCTAssertFalse(noEstimate.isPadded)
        XCTAssertNil(TravelEstimator.blockLabel(for: noEstimate), "nothing to warn about when nothing was padded")

        let zeroMinutes = TravelEstimator.estimate(minutes: 0, mode: .drive, start: start, bufferMinutes: 10)
        let unpadded = TravelEstimator.calendarBlock(start: start, end: end, travel: zeroMinutes)
        XCTAssertEqual(unpadded.start, start, "a zero-minute drive must not pull the start earlier by the buffer alone")
        XCTAssertEqual(unpadded.end, end)
        XCTAssertFalse(unpadded.isPadded)
    }

    func testSixToNineStaysAThreeHourAppointmentUnderTheTravelPadding() {
        let draft = EventExtractor.drafts(from: "dentist tomorrow 6-9")[0]
        XCTAssertFalse(draft.durationAssumed, "an explicit range is still not an assumed duration")
        XCTAssertEqual(draft.durationMinutes, 180)

        let estimate = TravelEstimator.estimate(minutes: 25, mode: .drive, start: draft.start, bufferMinutes: 0, returnMinutes: 25)
        let block = TravelEstimator.calendarBlock(start: draft.start, end: draft.end, travel: estimate)
        XCTAssertEqual(block.start, draft.start.addingTimeInterval(-25 * 60))
        XCTAssertEqual(block.end, draft.end.addingTimeInterval(25 * 60))
        XCTAssertEqual(
            draft.end.timeIntervalSince(draft.start),
            180 * 60,
            "the appointment she stated is still exactly 6-9 underneath the padding"
        )
        XCTAssertTrue(
            TravelEstimator.noteLines(
                appointmentStart: draft.start,
                appointmentEnd: draft.end,
                travel: estimate,
                place: ""
            ).first?.hasPrefix("Appointment: ") == true
        )

        let assumed = EventExtractor.drafts(from: "dentist tomorrow at 6")[0]
        XCTAssertTrue(assumed.durationAssumed, "the assumed one-hour case is unchanged")
        XCTAssertEqual(assumed.durationMinutes, 60)
        let assumedBlock = TravelEstimator.calendarBlock(start: assumed.start, end: assumed.end, travel: estimate)
        XCTAssertEqual(assumedBlock.end.timeIntervalSince(assumedBlock.start), TimeInterval((60 + 50) * 60))
    }

    func testExtraBeforeAndAfterPadCalendarNotMapsMinutes() {
        var draft = EventExtractor.drafts(from: "lunch tomorrow at 1")[0]
        draft.extraBeforeMinutes = 10
        draft.extraAfterMinutes = 15
        let estimate = TravelEstimator.estimate(
            minutes: 20,
            mode: .drive,
            start: draft.start,
            bufferMinutes: 5,
            returnMinutes: 20,
            extraBeforeMinutes: 10,
            extraAfterMinutes: 15
        )
        XCTAssertEqual(estimate.minutes, 20, "Maps drive there is not extra-before")
        XCTAssertEqual(estimate.routedReturnMinutes, 20, "Maps drive back is not extra-after")
        XCTAssertEqual(estimate.roundTripMinutes, 40, "round trip is drive + drive")
        XCTAssertEqual(
            estimate.leaveBy,
            draft.start.addingTimeInterval(-35 * 60),
            "leave-by = start − drive − buffer − extra before"
        )

        let block = TravelEstimator.calendarBlock(
            start: draft.start,
            end: draft.end,
            travel: estimate,
            extraBeforeMinutes: 10,
            extraAfterMinutes: 15
        )
        XCTAssertEqual(block.start, draft.start.addingTimeInterval(-35 * 60))
        XCTAssertEqual(block.end, draft.end.addingTimeInterval((20 + 15) * 60))
        XCTAssertEqual(draft.end.timeIntervalSince(draft.start), 60 * 60)

        let extraOnly = TravelEstimator.calendarBlock(
            start: draft.start,
            end: draft.end,
            travel: nil,
            extraBeforeMinutes: 10,
            extraAfterMinutes: 15
        )
        XCTAssertEqual(extraOnly.start, draft.start.addingTimeInterval(-10 * 60))
        XCTAssertEqual(extraOnly.end, draft.end.addingTimeInterval(15 * 60))
    }

    func testDeleteExplainsItselfInsteadOfFailingSilently() {
        for message in [
            CalendarStoreError.deleteFailed("Full Calendar access needed to delete. Turn it on in Settings.").errorDescription,
            CalendarStoreError.noAccess.errorDescription
        ] {
            XCTAssertFalse(message?.isEmpty ?? true, "a failed delete must always say why")
        }
    }

    func testDeleteLookupMatchesTravelPaddedBlockToOfficialTimes() {
        let calendar = Calendar.current
        let officialStart = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: Date())!
        let officialEnd = officialStart.addingTimeInterval(3 * 3600)
        let blockStart = officialStart.addingTimeInterval(-25 * 60)
        let blockEnd = officialEnd.addingTimeInterval(25 * 60)

        XCTAssertTrue(
            EventMatchLogic.isSameEvent(
                itemTitle: "Riding",
                itemStart: officialStart,
                itemEnd: officialEnd,
                eventTitle: "Riding",
                eventStart: blockStart,
                eventEnd: blockEnd
            ),
            "trash on a 6–9 row must still find the 5:35–9:25 EventKit block"
        )
        XCTAssertTrue(
            EventMatchLogic.isSameEvent(
                itemTitle: "Riding",
                itemStart: blockStart,
                itemEnd: blockEnd,
                eventTitle: "Riding",
                eventStart: officialStart,
                eventEnd: officialEnd
            )
        )
        XCTAssertFalse(
            EventMatchLogic.isSameEvent(
                itemTitle: "Riding",
                itemStart: officialStart,
                itemEnd: officialEnd,
                eventTitle: "Lunch",
                eventStart: blockStart,
                eventEnd: blockEnd
            )
        )
        XCTAssertTrue(
            EventMatchLogic.isShownOccurrence(
                eventStart: blockStart,
                itemStart: officialStart,
                isRecurring: true
            ),
            "a padded start that slipped to the previous hour is still this occurrence"
        )
    }

    func testTapDetailsShowOfficialTimesDriveAndOriginalNotOriginalOnly() {
        let calendar = Calendar.current
        let officialStart = calendar.date(bySettingHour: 10, minute: 16, second: 0, of: Date())!
        let officialEnd = officialStart.addingTimeInterval(3600)
        let paddedStart = officialStart.addingTimeInterval(-25 * 60)
        let paddedEnd = officialEnd.addingTimeInterval(25 * 60)
        let window = TravelEstimator.appointmentWindow(from: officialStart, to: officialEnd)
        let estimate = TravelEstimator.estimate(
            minutes: 25,
            mode: .drive,
            start: officialStart,
            bufferMinutes: 0,
            returnMinutes: 25
        )
        let notes = EventNotes.body(
            forOriginal: "Riding, West wind barn",
            details: TravelEstimator.noteLines(
                appointmentStart: officialStart,
                appointmentEnd: officialEnd,
                travel: estimate,
                place: "Westwind Community Barn · 27210 Altamont Rd, Los Altos Hills"
            )
        )
        let item = TodayItem(
            id: "padded-barn",
            title: "Riding",
            start: paddedStart,
            end: paddedEnd,
            isAllDay: false,
            location: "Westwind Community Barn · 27210 Altamont Rd, Los Altos Hills",
            notes: notes
        )

        XCTAssertEqual(item.officialTimeLabel, window, "details must quote 10:16–11:16, not the padded block")
        XCTAssertNotNil(item.calendarBlockCaption)
        XCTAssertTrue(item.showsDriveSection)
        XCTAssertEqual(item.savedInfo.driveLine, "~25 min there, ~25 min back (~50 min round trip)")
        XCTAssertEqual(item.driveDisplay, TravelEstimator.localizedRoundTrip(outbound: 25, back: 25, total: 50, mode: .drive))
        XCTAssertEqual(item.leaveByDisplay, "Leave by \(estimate.leaveBy.formatted(date: .omitted, time: .shortened))")
        XCTAssertEqual(item.originalText, "Riding, West wind barn")
        XCTAssertEqual(item.placeLabel, "Westwind Community Barn · 27210 Altamont Rd, Los Altos Hills")

        let foreign = TodayItem(
            id: "someone-elses-event",
            title: "Team sync",
            start: officialStart,
            end: officialEnd,
            isAllDay: false,
            location: "Conference room",
            notes: "Weekly sync"
        )
        XCTAssertNil(foreign.originalText, "a non-Scedra event has no original, but tap still opens details")
        XCTAssertEqual(foreign.officialTimeLabel, window)
        XCTAssertTrue(foreign.showsDriveSection, "a place without a saved drive still shows the drive section")
        XCTAssertNil(foreign.driveDisplay)
    }

    func testTodayRowPrefersLeaveByWhenLeaveByLineExists() {
        let calendar = Calendar.current
        let officialStart = calendar.date(bySettingHour: 14, minute: 30, second: 0, of: Date())!
        let officialEnd = officialStart.addingTimeInterval(45 * 60)
        let paddedStart = officialStart.addingTimeInterval(-20 * 60)
        let paddedEnd = officialEnd.addingTimeInterval(20 * 60)
        let window = TravelEstimator.appointmentWindow(from: officialStart, to: officialEnd)
        let estimate = TravelEstimator.estimate(
            minutes: 20,
            mode: .drive,
            start: officialStart,
            bufferMinutes: 0,
            returnMinutes: 20
        )
        let withTravel = TodayItem(
            id: "today-leave-by",
            title: "Dentist",
            start: paddedStart,
            end: paddedEnd,
            isAllDay: false,
            location: "Stanford",
            notes: EventNotes.body(
                forOriginal: "dentist today at 2:30 at Stanford",
                details: TravelEstimator.noteLines(
                    appointmentStart: officialStart,
                    appointmentEnd: officialEnd,
                    travel: estimate,
                    place: "Stanford"
                )
            )
        )
        XCTAssertEqual(
            withTravel.todayTimeLabel,
            TravelEstimator.localizedLeaveByLine(withTravel.leaveByDisplay ?? "")
        )
        XCTAssertEqual(
            withTravel.todayTimeLabel,
            ScedraString("Leave by \(estimate.leaveBy.scedraDisplay(date: .omitted, time: .shortened))")
        )
        XCTAssertEqual(withTravel.todayAppointmentCaption, ScedraString("Appointment \(window)"))
        XCTAssertNotEqual(withTravel.todayTimeLabel, withTravel.officialTimeLabel)

        let noTravel = TodayItem(
            id: "today-official-only",
            title: "Call",
            start: officialStart,
            end: officialEnd,
            isAllDay: false,
            location: nil,
            notes: "no place"
        )
        XCTAssertNil(noTravel.leaveByDisplay)
        XCTAssertEqual(noTravel.todayTimeLabel, noTravel.officialTimeLabel)
        XCTAssertNil(noTravel.todayAppointmentCaption)
    }

    func testThemeStoreRoundTripsSelectedID() {
        let suite = "scedra.theme.tests"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("could not create isolated defaults")
        }
        defaults.removePersistentDomain(forName: suite)

        XCTAssertEqual(ScedraThemeStore.id(from: defaults), .lavender)

        ScedraThemeStore.set(.blush, in: defaults)
        XCTAssertEqual(defaults.string(forKey: ScedraThemeStore.key), ScedraThemeID.blush.rawValue)
        XCTAssertEqual(ScedraThemeStore.id(from: defaults), .blush)

        ScedraThemeStore.set(.sage, in: defaults)
        XCTAssertEqual(ScedraThemeStore.id(from: defaults), .sage)

        ScedraThemeStore.set(.midnight, in: defaults)
        XCTAssertEqual(ScedraThemeStore.id(from: defaults), .midnight)

        ScedraThemeStore.set(.lavender, in: defaults)
        XCTAssertEqual(ScedraThemeStore.id(from: defaults), .lavender)

        defaults.set("not-a-theme", forKey: ScedraThemeStore.key)
        XCTAssertEqual(ScedraThemeStore.id(from: defaults), .lavender)

        XCTAssertTrue(ScedraThemeID.midnight.prefersDark)
        XCTAssertFalse(ScedraThemeID.lavender.prefersDark)
        XCTAssertFalse(ScedraThemeID.blush.prefersDark)
        XCTAssertFalse(ScedraThemeID.sage.prefersDark)
    }

    func testFollowPhoneLanguageClearsLeftoverOverridesWithoutTouchingAppleLanguages() {
        let suite = "scedra.language.tests"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("could not create isolated defaults")
        }
        defaults.removePersistentDomain(forName: suite)
        defaults.set("de", forKey: ScedraLocale.overrideKey)
        defaults.set("de", forKey: "scedra.locale")
        defaults.set(["de"], forKey: "AppleLanguages")

        ScedraLocale.followPhoneLanguage(in: defaults)

        let domain = defaults.persistentDomain(forName: suite) ?? [:]
        XCTAssertNil(domain[ScedraLocale.overrideKey])
        XCTAssertNil(domain["scedra.locale"])
        XCTAssertEqual(defaults.array(forKey: "AppleLanguages") as? [String], ["de"])
    }

    func testLocaleMappingReturnsSupportedCodesFromLocale() {
        XCTAssertEqual(ScedraLocale.supportedLanguage(from: Locale(identifier: "de-DE")), "de")
        XCTAssertEqual(ScedraLocale.supportedLanguage(from: Locale(identifier: "fr-FR")), "fr")
        XCTAssertEqual(ScedraLocale.supportedLanguage(from: Locale(identifier: "en-US")), "en")
        XCTAssertEqual(ScedraLocale.supportedLanguage(from: Locale(identifier: "es-MX")), "es")
        XCTAssertEqual(ScedraLocale.supportedLanguage(from: Locale(identifier: "it-IT")), "en")

        XCTAssertEqual(ScedraString("Voice", locale: Locale(identifier: "de")), "Sprache")
        XCTAssertEqual(ScedraString("Voice", locale: Locale(identifier: "fr")), "Voix")
        XCTAssertEqual(ScedraString("Voice", locale: Locale(identifier: "en")), "Voice")
        XCTAssertFalse(ScedraString("Voice", locale: Locale(identifier: "de")).isEmpty)
        XCTAssertFalse(ScedraString("Voice", locale: Locale(identifier: "fr")).isEmpty)
        XCTAssertFalse(ScedraString("Voice", locale: Locale(identifier: "en")).isEmpty)
    }

    func testPhoneLanguageFollowsPreferredListNotPinnedGerman() {
        XCTAssertEqual(ScedraLocale.supportedLanguage(fromPreferred: ["fr-FR", "en"]), "fr")
        XCTAssertEqual(ScedraLocale.supportedLanguage(fromPreferred: ["es-MX"]), "es")
        XCTAssertEqual(ScedraLocale.supportedLanguage(fromPreferred: ["de-DE"]), "de")
        XCTAssertEqual(ScedraLocale.supportedLanguage(fromPreferred: ["en-US"]), "en")
        XCTAssertEqual(ScedraLocale.supportedLanguage(fromPreferred: ["it-IT", "en"]), "en")
        XCTAssertNotEqual(ScedraLocale.phoneLanguageCode, "")
        XCTAssertTrue(ScedraLocale.supportedLanguageCodes.contains(ScedraLocale.phoneLanguageCode))
    }

    func testDisplayClocksUseCurrentLocale() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            date.scedraDisplay(date: .omitted, time: .shortened),
            date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(.current))
        )
        XCTAssertEqual(
            date.scedraHourLabel(),
            date.formatted(Date.FormatStyle.dateTime.hour().locale(.current))
        )
    }

    func testStringCatalogCoversPhoneLanguages() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Scedra/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = catalog?["strings"] as? [String: Any]
        XCTAssertNotNil(strings)
        let needed = ["en", "fr", "es", "de"]
        var missing: [String] = []
        for (key, raw) in strings ?? [:] {
            let entry = raw as? [String: Any]
            let localizations = entry?["localizations"] as? [String: Any] ?? [:]
            let absent = needed.filter { localizations[$0] == nil }
            if !absent.isEmpty {
                missing.append("\(key) missing \(absent.joined(separator: ","))")
            }
        }
        XCTAssertEqual(missing, [], missing.joined(separator: "\n"))
    }

    func testGreetingUsesNameWhenPresent() {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: UserProfile.nameKey)
        defaults.set("", forKey: UserProfile.nameKey)
        XCTAssertEqual(UserProfile.greeting, "Hi")
        defaults.set("Alex", forKey: UserProfile.nameKey)
        XCTAssertEqual(UserProfile.greeting, "Hi, Alex")
        defaults.set(previous, forKey: UserProfile.nameKey)
    }

    func testProfileDetailsMatchesWorkAndSchoolLabels() {
        let details = ProfileDetails(
            notes: "Park in the back lot",
            places: [
                ProfilePlace(label: "Work", address: "500 El Camino Real, Menlo Park"),
                ProfilePlace(label: "School", address: "123 Campus Dr, Stanford")
            ]
        )
        XCTAssertEqual(ProfileDetailsStore.place(matching: "work", in: details)?.address.contains("El Camino"), true)
        XCTAssertEqual(ProfileDetailsStore.place(matching: "at school", in: details)?.label, "School")
        XCTAssertNil(ProfileDetailsStore.place(matching: "dentist", in: details))
        XCTAssertTrue(ProfileDetailsStore.looksLikeSavedPlace("to work", in: details))

        let school = ProfileDetails(
            notes: "",
            places: [ProfilePlace(label: "school", address: "100 Example Ave, Springfield, IL 62701")]
        )
        for phrasing in ["school", "School", "the school", "at school", "my school", "lunch at school", "heading to school"] {
            XCTAssertEqual(
                ProfileDetailsStore.place(matching: phrasing, in: school)?.address,
                "100 Example Ave, Springfield, IL 62701",
                phrasing
            )
        }
        XCTAssertNil(ProfileDetailsStore.place(matching: "dentist tomorrow at 2", in: school))

        let fromNotes = ProfileDetails(
            notes: "school = 100 Example Ave, Springfield, IL 62701\nwork: 500 El Camino Real",
            places: []
        )
        XCTAssertEqual(
            ProfileDetailsStore.place(matching: "the school", in: fromNotes)?.address,
            "100 Example Ave, Springfield, IL 62701"
        )

        let data = ProfileDetailsStore.encode(details)
        let roundTrip = ProfileDetailsStore.decode(data)
        XCTAssertEqual(roundTrip.notes, "Park in the back lot")
        XCTAssertEqual(roundTrip.places.count, 2)
    }

    func testNearbyTransitWalkLine() {
        let stop = NearbyTransitStop(
            name: "California Ave Caltrain",
            address: "California Ave, Palo Alto",
            latitude: 37.43,
            longitude: -122.14,
            meters: 240
        )
        XCTAssertEqual(stop.walkMinutes, 3)
        XCTAssertEqual(stop.line, ScedraString("\(stop.name) is about a \(stop.walkMinutes)-min walk"))
        let atDoor = NearbyTransitStop(
            name: "Bus stop",
            address: "",
            latitude: 37.43,
            longitude: -122.14,
            meters: 20
        )
        XCTAssertEqual(atDoor.line, ScedraString("\(atDoor.name) is at the place"))
    }

    func testHomeGapTransitSavesADayDrivingWouldMiss() {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date())
        let first = homeGapStop(
            id: "a",
            title: "Dentist",
            start: calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day)!,
            end: calendar.date(bySettingHour: 11, minute: 0, second: 0, of: day)!
        )
        let second = homeGapStop(
            id: "b",
            title: "Barn",
            place: "Westwind Community Barn",
            start: calendar.date(bySettingHour: 11, minute: 40, second: 0, of: day)!,
            end: calendar.date(bySettingHour: 12, minute: 40, second: 0, of: day)!
        )
        let minutes = HomeGapMinutes(
            aToHome: 20,
            homeToB: 20,
            aToB: 50,
            aToBTransit: 25
        )
        let suggestion = HomeGapLogic.suggestion(
            first: first,
            second: second,
            minutes: minutes,
            leavingHomeBuffer: 5,
            walkMinutes: 15
        )
        XCTAssertEqual(suggestion?.kind, .takeTransit)
        XCTAssertEqual(suggestion?.headline, String(localized: "Take transit to \(second.title)"))
        XCTAssertTrue(suggestion?.detail.contains("25") == true)
        XCTAssertFalse(suggestion?.detail.contains("last bus") == true)
    }

    func testHomeGapMentionsTransitWhenBothFit() {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date())
        let first = homeGapStop(
            id: "a",
            title: "Lunch",
            start: calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day)!,
            end: calendar.date(bySettingHour: 13, minute: 0, second: 0, of: day)!
        )
        let second = homeGapStop(
            id: "b",
            title: "Barn",
            start: calendar.date(bySettingHour: 16, minute: 0, second: 0, of: day)!,
            end: calendar.date(bySettingHour: 17, minute: 0, second: 0, of: day)!
        )
        let minutes = HomeGapMinutes(
            aToHome: 15,
            homeToB: 15,
            aToB: 20,
            aToBTransit: 35,
            aToHomeTransit: 25,
            homeToBTransit: 25
        )
        let suggestion = HomeGapLogic.suggestion(
            first: first,
            second: second,
            minutes: minutes,
            leavingHomeBuffer: 5,
            walkMinutes: 15
        )
        XCTAssertNil(suggestion, "both paths fit — going home is assumed")
    }

    func testHomeGapTransitNoteDoesNotGuess() {
        XCTAssertNil(HomeGapLogic.transitNote(drive: 15, transit: nil, preferTransit: false))
        XCTAssertEqual(
            HomeGapLogic.transitNote(drive: 20, transit: 12, preferTransit: false),
            ScedraString("Transit ~\(12) min, faster than ~\(20) min drive.")
        )
        XCTAssertEqual(
            HomeGapLogic.transitNote(drive: 15, transit: 22, preferTransit: true),
            ScedraString("Transit ~\(22) min (preferred). Drive ~\(15) min.")
        )
    }

    func testSwitchingAppointmentModeRecalculatesLeaveByFromMatchingMinutes() {
        let start = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: Date())!
        let driveMinutes = 12
        let transitMinutes = 28
        let buffer = 5

        let driving = TravelEstimator.estimate(
            minutes: driveMinutes,
            mode: .drive,
            start: start,
            bufferMinutes: buffer,
            returnMinutes: 14
        )
        let transit = TravelEstimator.estimate(
            minutes: transitMinutes,
            mode: .transit,
            start: start,
            bufferMinutes: buffer,
            returnMinutes: 31
        )

        XCTAssertEqual(driving.leaveBy, start.addingTimeInterval(-17 * 60))
        XCTAssertEqual(transit.leaveBy, start.addingTimeInterval(-33 * 60))
        XCTAssertNotEqual(driving.leaveBy, transit.leaveBy, "transit leave-by must not keep the car leave-by")
        XCTAssertEqual(TravelEstimator.line(for: driving), expectedTravelLine(driving))
        XCTAssertEqual(TravelEstimator.line(for: transit), expectedTravelLine(transit))
        XCTAssertFalse(TravelEstimator.line(for: transit).contains("~12"), "switching must not reuse drive minutes")

        let switchedBack = TravelEstimator.estimate(
            minutes: driveMinutes,
            mode: .drive,
            start: start,
            bufferMinutes: buffer,
            returnMinutes: 14
        )
        XCTAssertEqual(switchedBack.leaveBy, driving.leaveBy)
    }

    func testSavedNotesRememberDrivingVersusPublicTransport() {
        let start = Calendar.current.date(bySettingHour: 11, minute: 0, second: 0, of: Date())!
        let end = start.addingTimeInterval(3600)
        let driving = TravelEstimator.estimate(
            minutes: 12,
            mode: .drive,
            start: start,
            bufferMinutes: 0,
            returnMinutes: 12
        )
        let transit = TravelEstimator.estimate(
            minutes: 28,
            mode: .transit,
            start: start,
            bufferMinutes: 0,
            returnMinutes: 30
        )

        let driveNotes = EventNotes.body(
            forOriginal: "mcdonalds today at 11",
            details: TravelEstimator.noteLines(
                appointmentStart: start,
                appointmentEnd: end,
                travel: driving,
                place: "McDonald's · 1100 El Camino Real, Menlo Park"
            )
        )
        let transitNotes = EventNotes.body(
            forOriginal: "mcdonalds today at 11",
            details: TravelEstimator.noteLines(
                appointmentStart: start,
                appointmentEnd: end,
                travel: transit,
                place: "McDonald's · 1100 El Camino Real, Menlo Park"
            )
        )

        let driveInfo = EventNotes.savedInfo(from: driveNotes)
        XCTAssertEqual(driveInfo.travelMode, .drive)
        XCTAssertEqual(driveInfo.resolvedTravelMode, .drive)
        XCTAssertEqual(driveInfo.travelModeLine, "Travel: Driving")
        XCTAssertTrue(driveNotes.contains("Drive: ~12 min there"), driveNotes)

        let transitInfo = EventNotes.savedInfo(from: transitNotes)
        XCTAssertEqual(transitInfo.travelMode, .transit)
        XCTAssertEqual(transitInfo.resolvedTravelMode, .transit)
        XCTAssertEqual(transitInfo.travelModeLine, "Travel: Public transport")
        XCTAssertTrue(transitNotes.contains("Transit: ~28 min there"), transitNotes)
        XCTAssertEqual(TravelMode.parseAppointmentChoice("Public transport"), .transit)
        XCTAssertEqual(TravelMode.parseAppointmentChoice("Driving"), .drive)
        XCTAssertEqual(TravelMode.appointmentDefault(fromSettings: .walk), .drive)
        XCTAssertEqual(TravelMode.appointmentDefault(fromSettings: .transit), .transit)

        let extras = EventNotes.body(
            forOriginal: "portal",
            details: TravelEstimator.noteLines(
                appointmentStart: start,
                appointmentEnd: end,
                travel: transit,
                place: "Peninsula Family Health, 11800 Willow Road"
            ) + [
                "Please bring your insurance card and photo ID. Arrive 15 minutes early.",
                "Parking: Garage entrance on Oak Avenue"
            ]
        )
        let info = EventNotes.savedInfo(from: extras)
        XCTAssertEqual(info.resolvedTravelMode, .transit)
        XCTAssertEqual(info.placeFromNotes, "Peninsula Family Health, 11800 Willow Road")
        XCTAssertTrue(
            info.extraLines.contains { $0.localizedCaseInsensitiveContains("insurance") },
            "\(info.extraLines)"
        )
        XCTAssertTrue(
            info.extraLines.contains { $0.localizedCaseInsensitiveContains("Parking") },
            "\(info.extraLines)"
        )
        let rewritten = EventNotes.body(
            forOriginal: info.original ?? "",
            details: TravelEstimator.noteLines(
                appointmentStart: start,
                appointmentEnd: end,
                travel: driving,
                place: info.placeFromNotes ?? ""
            ) + info.extraLines
        )
        XCTAssertTrue(rewritten.contains("Travel: Driving"), rewritten)
        XCTAssertTrue(rewritten.contains("insurance"), rewritten)
        XCTAssertTrue(rewritten.contains("Parking:"), rewritten)
        XCTAssertEqual(EventNotes.original(from: rewritten), "portal")
    }

    private func expectedTravelLine(_ estimate: TravelEstimate) -> String {
        let leave = estimate.leaveBy.formatted(date: .omitted, time: .shortened)
        return "\(TravelEstimator.travelSummary(for: estimate)) · \(String(localized: "leaveByInline \(leave)"))"
    }

    private func expectedTravelNote(_ estimate: TravelEstimate) -> String? {
        TravelEstimator.note(for: estimate)
    }

    private func localizedFormat(_ key: String, language: String, _ arguments: CVarArg...) -> String {
        let hosts = [Bundle.main, Bundle(for: ScedraLogicTests.self)]
        let lproj = hosts.compactMap { $0.path(forResource: language, ofType: "lproj") }.first.flatMap(Bundle.init(path:))
        XCTAssertNotNil(lproj, "missing \(language).lproj in the app bundle")
        let table = (lproj ?? Bundle.main).localizedString(forKey: key, value: key, table: "Localizable")
        return String(format: table, locale: Locale(identifier: language), arguments: arguments)
    }

    private func homeGapStop(
        id: String,
        title: String,
        place: String = "",
        start: Date,
        end: Date
    ) -> HomeGapStop {
        HomeGapStop(
            id: id,
            title: title,
            place: place,
            officialStart: start,
            officialEnd: end,
            extraBeforeMinutes: 0,
            extraAfterMinutes: 0,
            latitude: 37.36,
            longitude: -122.16,
            usesHome: false
        )
    }
}
