import XCTest
@testable import Scedra

/// Pure string logic only — nothing here touches the network or MapKit.
///
/// The bug these cover: "westwind community barn" resolved fine on its own but not
/// once an appointment title was in front of it, because the wrong string was being
/// handed to the map search. Every case asserts the title and the place separately,
/// so neither half can leak into the other again.
final class ScedraPlaceTests: XCTestCase {

    // MARK: - Title vs place, end to end

    private func split(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> (title: String, place: String) {
        let drafts = EventExtractor.drafts(from: text)
        guard let draft = drafts.first else {
            XCTFail("no draft produced for \"\(text)\"", file: file, line: line)
            return ("", "")
        }
        return (draft.title, draft.location)
    }

    func testTitleBeforeAtDoesNotLeakIntoThePlace() {
        let parsed = split("riding lesson at westwind community barn tomorrow at 4")
        XCTAssertEqual(parsed.title, "riding lesson")
        XCTAssertEqual(parsed.place, "westwind community barn")
    }

    func testBareVenueIsBothTheTitleAndThePlace() {
        let parsed = split("westwind community barn tomorrow at 4")
        XCTAssertEqual(parsed.title, "westwind community barn")
        XCTAssertEqual(parsed.place, "westwind community barn")
    }

    /// No "at" at all — the venue is simply juxtaposed with what she is doing.
    func testJuxtaposedVenueSplitsFromTheTitle() {
        let parsed = split("horse show westwind community barn friday 9-11")
        XCTAssertEqual(parsed.title, "horse show")
        XCTAssertEqual(parsed.place, "westwind community barn")
    }

    /// "at" is overloaded: it introduces the place *and* the time. Removing the
    /// date/time span first is what makes the remaining "at" unambiguous.
    func testSecondAtIsATimeNotPartOfThePlace() {
        let parsed = split("riding lesson at westwind community barn at 4pm")
        XCTAssertEqual(parsed.title, "riding lesson")
        XCTAssertEqual(
            parsed.place,
            "westwind community barn",
            "the trailing \"at\" from \"at 4pm\" must not end up in the map query"
        )
    }

    func testLeadingTheAndTrailingOnAreStrippedFromThePlace() {
        let parsed = split("meet steve at the westwind community barn on friday at 6")
        XCTAssertEqual(parsed.title, "meet steve")
        XCTAssertEqual(parsed.place, "westwind community barn")
    }

    func testChainAfterAtKeepsTitleSeparate() {
        let parsed = split("lunch at mcdonalds today at 3")
        XCTAssertEqual(parsed.title, "lunch")
        XCTAssertEqual(parsed.place, "mcdonalds")
    }

    func testChainPlusAreaSurvivesWholeAfterAt() {
        let parsed = split("lunch at mcdonalds menlo park today at 3")
        XCTAssertEqual(parsed.title, "lunch")
        XCTAssertEqual(parsed.place, "mcdonalds menlo park", "the named area must stay attached to the brand")
    }

    func testTitleOnlyTextKeepsHerWord() {
        let parsed = split("dentist tomorrow at 2")
        XCTAssertEqual(parsed.title, "dentist")
        XCTAssertEqual(parsed.place, "dentist", "with no venue named, the type is also the lookup key")
    }

    /// The place is often several words. Truncating it to one or two is what made
    /// a findable venue unfindable.
    func testNoVenueIsEverTruncated() {
        for text in [
            "riding lesson at westwind community barn tomorrow at 4",
            "westwind community barn tomorrow at 4",
            "horse show westwind community barn friday 9-11",
            "riding lesson at westwind community barn at 4pm",
            "meet steve at the westwind community barn on friday at 6"
        ] {
            XCTAssertEqual(
                split(text).place,
                "westwind community barn",
                "every phrasing must send the same three words to the map: \(text)"
            )
        }
    }

    func testNoTitleWordLeaksIntoThePlaceAndViceVersa() {
        let cases: [(text: String, titleWords: [String], placeWords: [String])] = [
            ("riding lesson at westwind community barn tomorrow at 4", ["riding", "lesson"], ["westwind", "community", "barn"]),
            ("horse show westwind community barn friday 9-11", ["horse", "show"], ["westwind", "community", "barn"]),
            ("meet steve at the westwind community barn on friday at 6", ["meet", "steve"], ["westwind", "community", "barn"]),
            ("lunch at mcdonalds today at 3", ["lunch"], ["mcdonalds"])
        ]
        for item in cases {
            let parsed = split(item.text)
            for word in item.titleWords {
                XCTAssertFalse(
                    parsed.place.localizedCaseInsensitiveContains(word),
                    "\"\(word)\" is part of the title but reached the place query: \(item.text)"
                )
            }
            for word in item.placeWords {
                XCTAssertFalse(
                    parsed.title.localizedCaseInsensitiveContains(word),
                    "\"\(word)\" is part of the place but reached the title: \(item.text)"
                )
            }
        }
    }

    /// Dates and times belong to neither half.
    func testNoDateOrTimeFragmentSurvivesInEitherHalf() {
        let fragments = ["tomorrow", "friday", "today", "4pm", "9-11", " at 4", " at 6", " at 3", " at 2"]
        for text in [
            "riding lesson at westwind community barn tomorrow at 4",
            "westwind community barn tomorrow at 4",
            "horse show westwind community barn friday 9-11",
            "riding lesson at westwind community barn at 4pm",
            "meet steve at the westwind community barn on friday at 6",
            "lunch at mcdonalds today at 3",
            "lunch at mcdonalds menlo park today at 3",
            "dentist tomorrow at 2"
        ] {
            let parsed = split(text)
            for fragment in fragments {
                XCTAssertFalse(
                    parsed.place.localizedCaseInsensitiveContains(fragment),
                    "\"\(fragment)\" left in the place for: \(text) -> \(parsed.place)"
                )
                XCTAssertFalse(
                    parsed.title.localizedCaseInsensitiveContains(fragment),
                    "\"\(fragment)\" left in the title for: \(text) -> \(parsed.title)"
                )
            }
        }
    }

    // MARK: - Saving is never blocked by a messy title

    func testEveryShapeStillHasBothADateAndATime() {
        for text in [
            "riding lesson at westwind community barn tomorrow at 4",
            "westwind community barn tomorrow at 4",
            "horse show westwind community barn friday 9-11",
            "riding lesson at westwind community barn at 4pm",
            "meet steve at the westwind community barn on friday at 6",
            "lunch at mcdonalds today at 3",
            "lunch at mcdonalds menlo park today at 3",
            "dentist tomorrow at 2"
        ] {
            let draft = EventExtractor.drafts(from: text).first
            XCTAssertEqual(draft?.hasDate, true, "lost the date for: \(text)")
            XCTAssertEqual(draft?.hasTime, true, "lost the time for: \(text)")
        }
    }

    func testUnfindableVenueStillSavesWithHerOwnWords() {
        var draft = EventExtractor.drafts(from: "riding lesson at westwind community barn tomorrow at 4")[0]
        draft.clearResolvedPlace()
        XCTAssertEqual(draft.locationToSave, "westwind community barn")
        XCTAssertEqual(draft.calendarTitle, "riding lesson")
    }

    // MARK: - The split unit itself

    func testTitleAndPlaceOnAlreadyStrippedText() {
        XCTAssertEqual(
            EventExtractor.titleAndPlace(in: "riding lesson at westwind community barn at"),
            EventExtractor.TitlePlace(title: "riding lesson", place: "westwind community barn")
        )
        XCTAssertEqual(
            EventExtractor.titleAndPlace(in: "the westwind community barn on"),
            EventExtractor.TitlePlace(title: "the westwind community barn", place: "westwind community barn")
        )
        XCTAssertEqual(
            EventExtractor.titleAndPlace(in: "horse show westwind community barn"),
            EventExtractor.TitlePlace(title: "horse show", place: "westwind community barn")
        )
    }

    /// A lone trailing word is too thin to call a venue, so her wording is left alone.
    func testAmbiguousTwoWordTextIsNotCarvedUp() {
        XCTAssertEqual(
            EventExtractor.titleAndPlace(in: "westwind community barn"),
            EventExtractor.TitlePlace(title: "westwind community barn", place: "westwind community barn")
        )
    }

    // MARK: - Area splitting only fires on a real "brand + area"

    func testVenueNameIsNeverCarvedIntoAPlaceAndAnInventedArea() {
        XCTAssertTrue(
            PlaceResolver.placeAreaSplits(from: "westwind community barn").isEmpty,
            "\"community barn\" is part of the venue name, not a town"
        )
        let plan = PlaceResolver.searchPlan(for: "westwind community barn")
        XCTAssertEqual(plan.fullPhrase, "westwind community barn")
        XCTAssertTrue(plan.areaCandidates.isEmpty)
        XCTAssertFalse(plan.prefersNamedArea)
        XCTAssertTrue(plan.isDistinctiveVenue)
    }

    func testBrandPlusAreaStillSplits() {
        XCTAssertEqual(
            PlaceMemory.brandAndRemainder(in: "mcdonalds menlo park")?.brand,
            "mcdonalds"
        )
        XCTAssertEqual(
            PlaceMemory.brandAndRemainder(in: "mcdonalds menlo park")?.remainder,
            "menlo park"
        )
        XCTAssertNil(PlaceMemory.brandAndRemainder(in: "westwind community barn"))
        XCTAssertNil(PlaceMemory.brandAndRemainder(in: "mcdonalds"))

        let split = PlaceResolver.placeAreaSplits(from: "mcdonalds menlo park").first
        XCTAssertEqual(split?.place.lowercased(), "mcdonalds")
        XCTAssertEqual(split?.area.lowercased(), "menlo park")
        XCTAssertTrue(
            PlaceResolver.searchPlan(for: "mcdonalds menlo park").prefersNamedArea,
            "brand + area must never fall back to the user or home pin"
        )
        XCTAssertFalse(
            PlaceResolver.searchPlan(for: "mcdonalds").prefersNamedArea,
            "a bare chain name does not pin to a named area"
        )
        XCTAssertEqual(
            PlaceResolver.searchPlan(for: "mcdonalds").originPolicy(homeAddressIsSet: true),
            .home
        )
    }

    // MARK: - Falling back to shorter phrases when the split is ambiguous

    func testShorterPhrasesAreOnlyTriedWhenLeadingWordsCouldBeATitle() {
        XCTAssertEqual(
            PlaceResolver.resolutionPhrases(for: "westwind community barn"),
            ["westwind community barn"],
            "a three-word venue name must be searched whole and never shortened"
        )
        XCTAssertEqual(PlaceResolver.resolutionPhrases(for: "mcdonalds"), ["mcdonalds"])
        XCTAssertEqual(
            PlaceResolver.resolutionPhrases(for: "mcdonalds menlo park"),
            ["mcdonalds menlo park"],
            "a named area must never be dropped to reach a store near her house"
        )

        let ambiguous = PlaceResolver.resolutionPhrases(for: "annual gathering westwind community barn")
        XCTAssertEqual(ambiguous.first, "annual gathering westwind community barn")
        XCTAssertEqual(
            ambiguous.last,
            "westwind community barn",
            "the longest tail that could be the venue has to be reachable"
        )
    }

    // MARK: - Messy voice / OCR / typed input

    private func parsed(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> DraftEvent {
        let drafts = EventExtractor.drafts(from: text)
        if let draft = drafts.first {
            return draft
        }
        XCTFail("no draft produced for \"\(text)\"", file: file, line: line)
        return EventExtractor.drafts(from: "dentist tomorrow at 2")[0]
    }

    func testMessyInputsSplitTitlePlaceAndTime() {
        PlaceMemory.resetForTests()
        defer { PlaceMemory.resetForTests() }

        let cases: [(text: String, title: String, place: String, hasTime: Bool)] = [
            ("riding lesson at westwind community barn tomorrow at 4", "riding lesson", "westwind community barn", true),
            ("riding west wind barn today at 10", "riding", "west wind barn", true),
            ("westwind community barn tomorrow at 4", "westwind community barn", "westwind community barn", true),
            ("horse show westwind community barn friday 9-11", "horse show", "westwind community barn", true),
            ("lunch mcdonalds menlo park 3", "lunch", "mcdonalds menlo park", true),
            ("dentist 2pm", "dentist", "dentist", true),
            ("meet at the barn friday 6", "meet", "barn", true),
            ("i have a dentist appointment tomorrow at 2 at stanford", "dentist appointment", "stanford", true),
            ("um so like riding lesson at westwind tomorrow at four", "riding lesson", "westwind", true),
            ("Riding, West wind barn", "Riding", "West wind barn", false),
            ("Riding, West wind barn tomorrow at 10", "Riding", "West wind barn", true)
        ]

        for item in cases {
            let draft = parsed(item.text)
            XCTAssertEqual(draft.title, item.title, "title for: \(item.text)")
            XCTAssertEqual(draft.location, item.place, "place for: \(item.text)")
            XCTAssertEqual(draft.hasTime, item.hasTime, "time flag for: \(item.text)")
            XCTAssertFalse(draft.title.localizedCaseInsensitiveContains("tomorrow"), item.text)
            XCTAssertFalse(draft.location.localizedCaseInsensitiveContains("tomorrow"), item.text)
            XCTAssertFalse(draft.location.localizedCaseInsensitiveContains("friday"), item.text)
            XCTAssertFalse(draft.location.localizedCaseInsensitiveContains("four"), "spoken time leaked into place: \(item.text)")
        }
    }

    func testSpokenFourIsFourOClock() {
        XCTAssertEqual(ClockTimeParser.parse("tomorrow at four")?.hour, 16)
        XCTAssertEqual(ClockTimeParser.parse("dentist 2pm")?.hour, 14)
        XCTAssertEqual(ClockTimeParser.parse("lunch mcdonalds menlo park 3")?.hour, 15)

        let draft = parsed("um so like riding lesson at westwind tomorrow at four")
        XCTAssertEqual(Calendar.current.component(.hour, from: draft.start), 16)
        XCTAssertTrue(draft.hasTime)
        XCTAssertTrue(draft.hasDate)
    }

    func testBarnNicknameUsesRememberedVenue() {
        PlaceMemory.resetForTests()
        defer { PlaceMemory.resetForTests() }

        PlaceMemory.remember(
            title: "riding lesson",
            location: "Westwind Community Barn · 27210 Altamont Rd",
            latitude: 37.3576,
            longitude: -122.1503
        )
        XCTAssertEqual(
            PlaceMemory.remembered(matchingPlaceQuery: "barn")?.location,
            "Westwind Community Barn · 27210 Altamont Rd"
        )

        let draft = parsed("meet at the barn friday 6")
        XCTAssertEqual(draft.title, "meet")
        XCTAssertEqual(draft.location, "Westwind Community Barn · 27210 Altamont Rd")
        XCTAssertTrue(draft.hasTime)
        XCTAssertTrue(draft.hasDate)
    }

    func testSplitWestWindStillSearchesWestwind() {
        XCTAssertEqual(PlaceResolver.joinSplitBrandTokens("west wind barn"), "westwind barn")
        XCTAssertEqual(PlaceResolver.joinSplitBrandTokens("West wind community barn"), "westwind community barn")
        XCTAssertEqual(
            PlaceResolver.resolutionPhrases(for: "west wind barn"),
            ["west wind barn", "westwind barn"]
        )
        XCTAssertEqual(
            PlaceResolver.resolutionPhrases(for: "westwind community barn"),
            ["westwind community barn"],
            "a three-word venue name must still be searched whole"
        )
    }

    func testBrandInAreaIsNotSplitIntoABareCity() {
        let parsed = split("mcdonalds in menlo park today at 3")
        XCTAssertTrue(parsed.place.localizedCaseInsensitiveContains("mcdonalds"), parsed.place)
        XCTAssertTrue(parsed.place.localizedCaseInsensitiveContains("menlo"), parsed.place)
        XCTAssertFalse(
            parsed.place.localizedCaseInsensitiveContains("today"),
            "date leaked into the place: \(parsed.place)"
        )
    }

    func testAppointmentDetailsPortalKeepsExamTitleAndClinicAddressApart() {
        let text = """
        Appointment Details
        Annual Physical Exam
        Appointment Type Annual Physical Exam
        Date Tuesday, October 14, 2026
        Appointment Time 2:30 PM – 3:15 PM
        Location Peninsula Family Health
        Address 11800 Willow Road, Suite 240, Menlo Park, CA 94025
        """
        let parsed = split(text)
        XCTAssertEqual(parsed.title, "Annual Physical Exam")
        XCTAssertTrue(parsed.place.localizedCaseInsensitiveContains("Peninsula"), parsed.place)
        XCTAssertTrue(parsed.place.contains("11800"), parsed.place)
        XCTAssertFalse(parsed.place.localizedCaseInsensitiveContains("Alex"))
        XCTAssertFalse(parsed.title.localizedCaseInsensitiveContains("Details"))
        XCTAssertFalse(parsed.title.localizedCaseInsensitiveContains("11800"))
    }

    func testDentistLeftoverStaysTheLookupKeyWithoutMemory() {
        PlaceMemory.resetForTests()
        defer { PlaceMemory.resetForTests() }
        XCTAssertEqual(
            PlaceMemory.distinctiveAliases(from: "Westwind Community Barn · 27210 Altamont Rd").sorted(),
            ["barn", "westwind community barn"]
        )
        let parsed = split("dentist 2pm")
        XCTAssertEqual(parsed.title, "dentist")
        XCTAssertEqual(parsed.place, "dentist")
    }

    func testAddressLookupPrefersTheStreetAfterTheDot() {
        XCTAssertEqual(
            PlaceResolver.addressLookupCandidates(from: "McDonald's · 165 University Ave"),
            ["165 University Ave", "McDonald's · 165 University Ave", "McDonald's"]
        )
        XCTAssertEqual(
            PlaceResolver.addressLookupCandidates(from: "1 Apple Park Way, Cupertino, CA"),
            ["1 Apple Park Way, Cupertino, CA"]
        )
        XCTAssertTrue(PlaceResolver.isSpecificAddress("1 Apple Park Way, Cupertino, CA"))
        XCTAssertTrue(PlaceResolver.isSpecificAddress("McDonald's · 165 University Ave"))
    }

    func testSearchHintNeverLeavesLocalSearchWithoutARegionCenter() {
        let home = CLLocation(latitude: 37.4419, longitude: -122.1430)
        let last = CLLocation(latitude: 37.3349, longitude: -122.0090)
        XCTAssertEqual(
            PlaceResolver.searchHint(home: home, lastKnown: last).coordinate.latitude,
            home.coordinate.latitude,
            accuracy: 0.0001,
            "Home wins over last-known for a search region"
        )
        XCTAssertEqual(
            PlaceResolver.searchHint(home: nil, lastKnown: last).coordinate.latitude,
            last.coordinate.latitude,
            accuracy: 0.0001
        )
        let fallback = PlaceResolver.searchHint(home: nil, lastKnown: nil)
        XCTAssertTrue(CLLocationCoordinate2DIsValid(fallback.coordinate))
        XCTAssertTrue(PlaceResolver.isFallbackSearchLocation(fallback))
        XCTAssertFalse(PlaceResolver.isFallbackSearchLocation(home))

        let region = PlaceResolver.localSearchRegion(
            around: fallback,
            radius: PlaceResolver.fallbackSearchRadiusMeters
        )
        XCTAssertGreaterThan(region.span.latitudeDelta, 0)
        XCTAssertGreaterThan(region.span.longitudeDelta, 0)
    }
}
