import XCTest
@testable import Scedra

/// iMessage / chat screenshots: glued Vision OCR and a spaced transcript of the
/// same Mayaya thread about The Daily Grind on Saturday at 11am.
final class ScedraChatScreenshotTests: XCTestCase {

    static let gluedIMessageOCR = """
    3:27
    M
    Mayaya
    heyey! areeyou freeethisweekeend? iwasthinkingweecould go tothat newcoffee shopdowntown togetherr
    yes! thatsounds sofun. whichone wereyouthinking?
    Thedailly Grind!
    12344Elm St,Denver,CO80202
    theyhavegreat drinks andcute seatingg
    perfect! whattime?
    howabout11amonSaturday?
    worksforme! seeyouthen
    Read 3:26PM
    yayey!
    """

    static let spacedIMessageOCR = """
    3:27
    M
    Mayaya
    hey! are you free this weekend? i was thinking we could go to that new coffee shop downtown together
    yes! that sounds so fun. which one were you thinking?
    The Daily Grind!
    12344 Elm St, Denver, CO 80202
    they have great drinks and cute seating
    perfect! what time?
    how about 11am on saturday?
    works for me! see you then
    Read 3:26PM
    yay!
    """

    func testGluedIMessageOCRSplitsChatWordsAndKeepsSpokenPhrasesAlone() {
        let cleaned = OCRTextNormalizer.normalize(Self.gluedIMessageOCR)
        XCTAssertTrue(cleaned.localizedCaseInsensitiveContains("are you"), cleaned)
        XCTAssertTrue(cleaned.localizedCaseInsensitiveContains("this weekend"), cleaned)
        XCTAssertTrue(cleaned.localizedCaseInsensitiveContains("coffee"), cleaned)
        XCTAssertTrue(cleaned.localizedCaseInsensitiveContains("Daily"), cleaned)
        XCTAssertTrue(cleaned.localizedCaseInsensitiveContains("Grind"), cleaned)
        XCTAssertTrue(cleaned.contains("12344"), cleaned)
        XCTAssertTrue(cleaned.localizedCaseInsensitiveContains("Elm"), cleaned)
        XCTAssertTrue(cleaned.localizedCaseInsensitiveContains("Denver"), cleaned)
        XCTAssertTrue(cleaned.contains("80202"), cleaned)
        XCTAssertTrue(
            cleaned.range(of: #"(?i)11\s*am"#, options: .regularExpression) != nil,
            "11am should unglue: \(cleaned)"
        )
        XCTAssertTrue(cleaned.localizedCaseInsensitiveContains("Saturday"), cleaned)

        XCTAssertEqual(
            OCRTextNormalizer.normalize("dentist tomorrow at 2 at McDonald's"),
            "dentist tomorrow at 2 at McDonald's"
        )
        XCTAssertEqual(
            OCRTextNormalizer.normalize("riding lesson at westwind community barn tomorrow at 4"),
            "riding lesson at westwind community barn tomorrow at 4"
        )
    }

    func testGluedAndSpacedIMessageFixturesExtractDailyGrindSaturday11am() {
        for sample in [Self.gluedIMessageOCR, Self.spacedIMessageOCR] {
            assertDailyGrindChatDraft(from: sample)
        }
    }

    func testAppointmentClockIgnoresReadReceiptAndUsesSaturday11am() {
        let cleaned = OCRTextNormalizer.normalize(Self.gluedIMessageOCR)
        let agreed = ClockTimeParser.appointmentClock(in: cleaned)
        XCTAssertEqual(agreed?.hour, 11, cleaned)
        XCTAssertEqual(agreed?.minute, 0, cleaned)
        XCTAssertEqual(ClockTimeParser.parse(cleaned)?.hour, 15, "last mentioned is Read 3:26PM")
        XCTAssertEqual(ClockTimeParser.latest(in: cleaned)?.hour, 15, "latest clock of day is still 3:26")
    }

    static let gluedSFTripOCR = """
    6:14
    L
    E
    SF trip?
    Yesterday 5:21PM
    Lilyoly
    areyou guysyt stilldown togotothe deyoung museumthis Saturday?
    yes! whattime wereyouthinking?
    Ethanhan
    themuseumopensat9:30am butmaybewe couldgo around11? grabcoffee firstnth
    soundsgood! wantto meetatthe museumor somewhere before?
    Lilyoly
    let's getcoffee first!
    Sightglass Coffee
    565 3rd St,San Francisco,CA94107
    howabout 10:30 there? thenwe walkover to themuseum
    perff! so 10:30 at Sightglass andthen deyoung around11?
    Ethanhan
    yepet! deyoungmuseum
    50 Hagiwara Tea Garden Dr
    San Francisco, CA 94118
    excited! thisis going tobe sofunn
    """

    func testGluedSFTripOCRExtractsSightglassAndDeYoung() {
        XCTAssertEqual(
            OCRTextNormalizer.normalize("dentist tomorrow at 2"),
            "dentist tomorrow at 2"
        )
        let drafts = EventExtractor.drafts(from: Self.gluedSFTripOCR)
        XCTAssertEqual(drafts.count, 2, drafts.map { "\($0.title) \($0.start) \($0.location)" }.joined(separator: " | "))

        let coffee = drafts[0]
        XCTAssertTrue(coffee.title.localizedCaseInsensitiveContains("Sightglass"), coffee.title)
        XCTAssertTrue(coffee.title.localizedCaseInsensitiveContains("Coffee"), coffee.title)
        XCTAssertFalse(coffee.title.localizedCaseInsensitiveContains("Lily"), coffee.title)
        XCTAssertFalse(coffee.title.localizedCaseInsensitiveContains("Ethan"), coffee.title)
        let coffeeParts = Calendar.current.dateComponents([.weekday, .hour, .minute], from: coffee.start)
        XCTAssertEqual(coffeeParts.weekday, 7, "Sightglass is Saturday: \(coffee.start)")
        XCTAssertEqual(coffeeParts.hour, 10, "10:30, not 9:30 opening or status bar: \(coffee.start)")
        XCTAssertEqual(coffeeParts.minute, 30, "\(coffee.start)")
        XCTAssertTrue(coffee.hasDate)
        XCTAssertTrue(coffee.hasTime)
        XCTAssertTrue(coffee.location.contains("565"), coffee.location)
        XCTAssertTrue(coffee.location.localizedCaseInsensitiveContains("3rd"), coffee.location)
        XCTAssertTrue(coffee.location.localizedCaseInsensitiveContains("Francisco"), coffee.location)
        XCTAssertTrue(coffee.location.contains("94107"), coffee.location)

        let museum = drafts[1]
        XCTAssertTrue(museum.title.localizedCaseInsensitiveContains("Young"), museum.title)
        XCTAssertTrue(museum.title.localizedCaseInsensitiveContains("Museum"), museum.title)
        let museumParts = Calendar.current.dateComponents([.weekday, .hour, .minute], from: museum.start)
        XCTAssertEqual(museumParts.weekday, 7, "de Young is Saturday: \(museum.start)")
        XCTAssertEqual(museumParts.hour, 11, "around 11, not 9:30 opening: \(museum.start)")
        XCTAssertEqual(museumParts.minute, 0, "\(museum.start)")
        XCTAssertTrue(museum.hasDate)
        XCTAssertTrue(museum.hasTime)
        XCTAssertTrue(museum.location.contains("50"), museum.location)
        XCTAssertTrue(museum.location.localizedCaseInsensitiveContains("Hagiwara"), museum.location)
        XCTAssertTrue(museum.location.localizedCaseInsensitiveContains("Francisco"), museum.location)
        XCTAssertTrue(museum.location.contains("94118"), museum.location)
    }

    func testChatLooksLikeChatAndNotAPortal() {
        XCTAssertTrue(CalendarCardParser.looksLikeChat(OCRTextNormalizer.normalize(Self.spacedIMessageOCR)))
        XCTAssertTrue(CalendarCardParser.looksLikeChat(OCRTextNormalizer.normalize(Self.gluedIMessageOCR)))
        XCTAssertFalse(
            CalendarCardParser.looksLikeChat("dentist tomorrow at 2 at McDonald's"),
            "a spoken phrase is not a chat screenshot"
        )
    }

    private func assertDailyGrindChatDraft(from text: String, file: StaticString = #filePath, line: UInt = #line) {
        let drafts = EventExtractor.drafts(from: text)
        XCTAssertEqual(drafts.count, 1, "chat screenshot is one appointment: \(text)", file: file, line: line)
        let draft = drafts[0]
        let title = draft.title
        XCTAssertTrue(
            title.localizedCaseInsensitiveContains("Daily Grind")
                || title.localizedCaseInsensitiveContains("Coffee"),
            "title should be Daily Grind / coffee, got \(title)",
            file: file,
            line: line
        )
        XCTAssertFalse(title.localizedCaseInsensitiveContains("Mayaya"), "contact name is not the title: \(title)", file: file, line: line)
        XCTAssertFalse(title.localizedCaseInsensitiveContains("yay"), "yay is not the title: \(title)", file: file, line: line)
        XCTAssertFalse(title.localizedCaseInsensitiveContains("heyey"), "glued blob is not the title: \(title)", file: file, line: line)
        XCTAssertFalse(title.localizedCaseInsensitiveContains("Check-in"), title, file: file, line: line)

        let calendar = Calendar.current
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: draft.start)
        XCTAssertEqual(parts.weekday, 7, "date is Saturday: \(draft.start)", file: file, line: line)
        XCTAssertEqual(parts.hour, 11, "agreed time is 11:00 AM, not Read 3:26: \(draft.start)", file: file, line: line)
        XCTAssertEqual(parts.minute, 0, file: file, line: line)
        XCTAssertTrue(draft.hasDate, file: file, line: line)
        XCTAssertTrue(draft.hasTime, file: file, line: line)
        XCTAssertTrue(draft.durationAssumed, "no end on the thread, assume 1 hour", file: file, line: line)
        XCTAssertEqual(draft.durationMinutes, 60, file: file, line: line)

        let location = draft.location
        XCTAssertTrue(location.localizedCaseInsensitiveContains("Daily Grind"), location, file: file, line: line)
        XCTAssertTrue(location.contains("12344"), location, file: file, line: line)
        XCTAssertTrue(location.localizedCaseInsensitiveContains("Elm"), location, file: file, line: line)
        XCTAssertTrue(location.localizedCaseInsensitiveContains("Denver"), location, file: file, line: line)
        XCTAssertTrue(location.contains("80202"), location, file: file, line: line)
    }
}
