import XCTest
@testable import Scedra

/// Photo capture: Vision lines → reading-order transcript → EventExtractor, exactly
/// as ContentView does. Asserts the Review draft's local start/end, not just the clock parser.
final class ScedraPhotoTimeTests: XCTestCase {

    private func photoDrafts(_ lines: [String]) -> [DraftEvent] {
        let blocks = lines.enumerated().map { index, line in
            PhotoTextRecognizer.RecognizedTextBlock(
                text: line,
                top: CGFloat(index) * 0.05,
                left: 0.05,
                height: 0.03
            )
        }
        return EventExtractor.drafts(from: PhotoTextRecognizer.readableTranscript(from: blocks))
    }

    private func assertClock(
        _ date: Date,
        month: Int? = 10,
        day: Int? = 14,
        weekday: Int? = nil,
        hour: Int,
        minute: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let parts = Calendar.current.dateComponents([.month, .day, .weekday, .hour, .minute], from: date)
        if let month { XCTAssertEqual(parts.month, month, "month of \(date)", file: file, line: line) }
        if let day { XCTAssertEqual(parts.day, day, "day of \(date)", file: file, line: line) }
        if let weekday { XCTAssertEqual(parts.weekday, weekday, "weekday of \(date)", file: file, line: line) }
        XCTAssertEqual(parts.hour, hour, "hour of \(date)", file: file, line: line)
        XCTAssertEqual(parts.minute, minute, "minute of \(date)", file: file, line: line)
    }

    private func only(_ drafts: [DraftEvent], file: StaticString = #filePath, line: UInt = #line) throws -> DraftEvent {
        XCTAssertEqual(drafts.count, 1, drafts.map { "\($0.title) \($0.start)" }.joined(separator: " | "), file: file, line: line)
        return try XCTUnwrap(drafts.first, file: file, line: line)
    }

    func testPortalCheckInIsArriveByAndAppointmentIsStart() throws {
        let draft = try only(photoDrafts([
            "Annual Physical Exam",
            "Oct 14",
            "Check-in 9:45 AM",
            "Appointment 10:00 AM – 10:40 AM",
            "Peninsula Family Health",
            "1 Main St Suite 14"
        ]))
        assertClock(draft.start, hour: 10, minute: 0)
        assertClock(draft.end, hour: 10, minute: 40)
        assertClock(try XCTUnwrap(draft.arriveBy), hour: 9, minute: 45)
        XCTAssertEqual(draft.title, "Annual Physical Exam")
    }

    func testFlyerAfternoonRange() throws {
        let draft = try only(photoDrafts(["Book Fair", "Sat, Oct 14 · 2pm–4pm", "Central Library"]))
        assertClock(draft.start, hour: 14, minute: 0)
        assertClock(draft.end, hour: 16, minute: 0)
        XCTAssertEqual(draft.title, "Book Fair")
    }

    func testPhotoTranscriptKeepsOCRTitlesAndMeridians() {
        let cleaned = OCRTextNormalizer.readablePhotoTranscript(
            "Book Fair\nAnnual Physical Exam\nAppointment 10:00 AM – 10:40 AM"
        )
        let lines = cleaned.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "Book Fair", cleaned)
        XCTAssertEqual(lines.dropFirst().first, "Annual Physical Exam", cleaned)
        XCTAssertTrue(cleaned.contains("Appointment"), cleaned)
        XCTAssertTrue(cleaned.contains("AM"), cleaned)
        let tokens = cleaned.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        XCTAssertFalse(tokens.contains("ok"), cleaned)
        XCTAssertFalse(tokens.contains("annual"), cleaned)
        XCTAssertFalse(tokens.contains("appointment"), cleaned)
        XCTAssertFalse(tokens.contains("Am"), cleaned)
        XCTAssertFalse(tokens.contains("Pm"), cleaned)
    }

    func testDinnerFridaySixToNineIsFridayEveningNotJuneNinth() throws {
        let draft = try only(EventExtractor.drafts(from: "dinner friday 6-9"))
        let parts = Calendar.current.dateComponents([.month, .day, .weekday, .hour, .minute], from: draft.start)
        XCTAssertEqual(parts.weekday, 6, "friday 6-9 is Friday, not June 9: \(draft.start)")
        XCTAssertEqual(parts.hour, 18, "friday 6-9 is 6–9 PM: \(draft.start)")
        XCTAssertEqual(Calendar.current.component(.hour, from: draft.end), 21)
        XCTAssertNotEqual(parts.month, 6, "6-9 must not become June: \(draft.start)")
        XCTAssertEqual(draft.durationMinutes, 180)
        XCTAssertFalse(draft.durationAssumed)
    }

    func testJuneNinthAndSlashStayDates() {
        XCTAssertNil(TimeRangeParser.parse("June 9"))
        XCTAssertNil(TimeRangeParser.parse("6/9"))

        let june = EventExtractor.drafts(from: "dentist June 9")[0]
        let juneParts = Calendar.current.dateComponents([.month, .day, .hour], from: june.start)
        XCTAssertEqual(juneParts.month, 6, "\(june.start)")
        XCTAssertEqual(juneParts.day, 9, "\(june.start)")
        XCTAssertNotEqual(juneParts.hour, 18, "June 9 is a date, not 6 PM: \(june.start)")

        let slash = EventExtractor.drafts(from: "dentist 6/9")[0]
        let slashParts = Calendar.current.dateComponents([.month, .day, .hour], from: slash.start)
        XCTAssertTrue(
            (slashParts.month == 6 && slashParts.day == 9)
                || (slashParts.month == 9 && slashParts.day == 6),
            "6/9 stays a calendar date: \(slash.start)"
        )
        XCTAssertFalse(
            slash.hasTime
                && slashParts.hour == 18
                && Calendar.current.component(.hour, from: slash.end) == 21,
            "6/9 must not become 6–9 PM: \(slash.start) – \(slash.end)"
        )
        XCTAssertTrue(slash.hasDate)
    }

    func testDateAndTimeOnSeparateLinesAreOneAppointment() throws {
        let noonQuarter = try only(photoDrafts(["Dentist", "Oct 14", "12:15 PM"]))
        assertClock(noonQuarter.start, hour: 12, minute: 15)
        assertClock(noonQuarter.end, hour: 13, minute: 15)
        XCTAssertTrue(noonQuarter.durationAssumed)

        let bareMorning = try only(photoDrafts(["Dentist", "Oct 14", "9:00"]))
        assertClock(bareMorning.start, hour: 9, minute: 0)

        let phoneBetween = try only(photoDrafts(["Dentist Oct 14 2026", "(650) 555-0142", "9:30 AM"]))
        assertClock(phoneBetween.start, hour: 9, minute: 30)
    }

    func testMeridianSplitOntoItsOwnLineStillCounts() throws {
        let morning = try only(photoDrafts(["Haircut", "Oct 14", "10:30", "AM"]))
        assertClock(morning.start, hour: 10, minute: 30)
        let afternoon = try only(photoDrafts(["Haircut", "Oct 14", "12:15", "PM"]))
        assertClock(afternoon.start, hour: 12, minute: 15)
    }

    func testDottedAndNarrowSpaceMeridians() throws {
        let dinner = try only(photoDrafts(["Dinner Oct 14 7:30 p.m."]))
        assertClock(dinner.start, hour: 19, minute: 30)
        XCTAssertFalse(dinner.location.contains("."), dinner.location)

        let standup = try only(photoDrafts(["Standup Oct 14 10:16\u{202F}AM"]))
        assertClock(standup.start, hour: 10, minute: 16)
        assertClock(standup.end, hour: 11, minute: 16)
    }

    func testSuiteRoomAndAgeNumbersNeverBecomeTheTime() throws {
        let suite = try only(photoDrafts(["Dentist Oct 14 at 10:30 AM", "500 Elm St Suite 14", "Palo Alto"]))
        assertClock(suite.start, hour: 10, minute: 30)

        let suiteDash = try only(photoDrafts(["Dentist Oct 14 at 10 AM", "Suite 14 - 2nd floor"]))
        assertClock(suiteDash.start, hour: 10, minute: 0)

        let room = try only(photoDrafts(["Dentist Oct 14 at 10 AM", "Room 13-15"]))
        assertClock(room.start, hour: 10, minute: 0)

        let ages = try only(photoDrafts(["Kids 14-16 soccer Oct 14 at 10:00 AM"]))
        assertClock(ages.start, hour: 10, minute: 0)
        XCTAssertTrue(ages.title.contains("14-16"), ages.title)
    }

    func testDayRangeIsNotAnAfternoonWindow() {
        let fair = photoDrafts(["Art Fair", "Oct 14-16", "Fort Mason"])
        let hour = fair.first.map { Calendar.current.component(.hour, from: $0.start) }
        XCTAssertNotEqual(hour, 14, "Oct 14-16 is three days, not 2–4 PM")
    }

    func testMilitaryRangeStillWorksWhenStated() {
        XCTAssertEqual(TimeRangeParser.parse("14-16")?.startHour, 14)
        XCTAssertEqual(TimeRangeParser.parse("from 14-16")?.endHour, 16)
        XCTAssertNil(TimeRangeParser.parse("Room 13-15"))
        XCTAssertEqual(TimeRangeParser.parse("dinner friday 6-9")?.startHour, 18)
        XCTAssertNil(TimeRangeParser.parse("Suite 3-5, appointment at 10 AM"), "explicit AM wins")
    }

    func testIMessageStopsShareTheNamedDayAndKeepMorningClocks() throws {
        let drafts = photoDrafts(["meet at 10:30 at Sightglass then de Young at 11 on Saturday"])
        XCTAssertEqual(drafts.count, 2, drafts.map { "\($0.title) \($0.start)" }.joined(separator: " | "))
        guard drafts.count == 2 else { return }
        assertClock(drafts[0].start, month: nil, day: nil, weekday: 7, hour: 10, minute: 30)
        assertClock(drafts[1].start, month: nil, day: nil, weekday: 7, hour: 11, minute: 0)
    }
}
