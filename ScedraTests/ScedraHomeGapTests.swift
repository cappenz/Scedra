import CoreLocation
import MapKit
import UserNotifications
import XCTest
@testable import Scedra

/// Fit / no-fit arithmetic for going home between two stops.
/// Fake minutes only — no MapKit, no network.
final class ScedraHomeGapTests: XCTestCase {
    private let cal = Calendar.current
    private lazy var day: Date = cal.startOfDay(
        for: cal.date(from: DateComponents(year: 2026, month: 6, day: 10))!
    )

    private func time(_ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    private func stop(
        _ id: String,
        _ title: String,
        start: Date,
        end: Date,
        place: String = "",
        extraBefore: Int = 0,
        extraAfter: Int = 0,
        usesHome: Bool = false
    ) -> HomeGapStop {
        HomeGapStop(
            id: id,
            title: title,
            place: place,
            officialStart: start,
            officialEnd: end,
            extraBeforeMinutes: extraBefore,
            extraAfterMinutes: extraAfter,
            latitude: nil,
            longitude: nil,
            usesHome: usesHome
        )
    }

    private func advice(
        first: HomeGapStop,
        second: HomeGapStop,
        aToHome: Int? = 20,
        homeToB: Int? = 25,
        aToB: Int,
        aToBTransit: Int? = nil,
        aToHomeTransit: Int? = nil,
        homeToBTransit: Int? = nil,
        buffer: Int = 5,
        walk: Int = 15,
        preferTransit: Bool = false,
        minHome: Int = 0,
        standing: [String] = []
    ) -> HomeGapSuggestion? {
        HomeGapLogic.suggestion(
            first: first,
            second: second,
            minutes: HomeGapMinutes(
                aToHome: aToHome,
                homeToB: homeToB,
                aToB: aToB,
                aToBTransit: aToBTransit,
                aToHomeTransit: aToHomeTransit,
                homeToBTransit: homeToBTransit
            ),
            leavingHomeBuffer: buffer,
            walkMinutes: walk,
            preferTransit: preferTransit,
            minHomeMinutes: minHome,
            standingBring: standing,
            calendar: cal
        )
    }

    // MARK: - Fit / no-fit

    func testWideGapCanGoHome() {
        let dentist = stop("a", "Dentist", start: time(14), end: time(15), place: "Valencia")
        let riding = stop("b", "Riding", start: time(17), end: time(18), place: "Westwind Community Barn")
        let suggestion = advice(first: dentist, second: riding, aToHome: 20, homeToB: 25, aToB: 15, buffer: 5)
        XCTAssertNil(suggestion, "going home is assumed — no card when the detour fits")
    }

    func testTightGapDoesNotFitHomeDetour() throws {
        // Leave dentist at 3:00. Home path needs 20+20+5 = 45. B is at 3:40. 40 min gap.
        let dentist = stop("a", "Dentist", start: time(14), end: time(15))
        let riding = stop("b", "Riding", start: time(15, 40), end: time(16, 40), place: "barn")
        let suggestion = try XCTUnwrap(
            advice(first: dentist, second: riding, aToHome: 20, homeToB: 20, aToB: 10, buffer: 5)
        )
        XCTAssertEqual(suggestion.kind, .stayOut)
        XCTAssertEqual(suggestion.headline, "Don’t go home — go to Riding")
        XCTAssertEqual(suggestion.collapsedHeadline, String(localized: "Don’t go home"))
        XCTAssertEqual(suggestion.collapsedSubtitle, String(localized: "Go to Riding"))
        XCTAssertTrue(suggestion.detail.contains("~10 min drive"), suggestion.detail)
        XCTAssertTrue(suggestion.detail.contains("Head to Riding"), "30 min leftover is not short")
        XCTAssertFalse(suggestion.bringItems.isEmpty)
        XCTAssertTrue(
            suggestion.bringItems[0].localizedCaseInsensitiveContains("riding"),
            "\(suggestion.bringItems)"
        )
    }

    func testShortLeftoverStaysAtA() throws {
        // Leave A at 3:00. Direct 20 min, B at 3:30. Leftover 10 < 15.
        let classStop = stop("a", "Class", start: time(14), end: time(15))
        let dentist = stop("b", "Dentist", start: time(15, 30), end: time(16, 30))
        let suggestion = try XCTUnwrap(
            advice(first: classStop, second: dentist, aToHome: 25, homeToB: 25, aToB: 20, buffer: 5)
        )
        XCTAssertEqual(suggestion.kind, .stayOut)
        XCTAssertTrue(suggestion.detail.contains("Stay at Class"), suggestion.detail)
        XCTAssertTrue(
            suggestion.bringItems[0].localizedCaseInsensitiveContains("dentist"),
            "\(suggestion.bringItems)"
        )
    }

    func testExactFitCountsAsGoHome() {
        // Leave A at 3:15 (15 after). Needed 20+20+5+0 = 45. B at 4:00. Gap 45.
        let first = stop("a", "Class", start: time(14), end: time(15), extraAfter: 15)
        let second = stop("b", "Dentist", start: time(16), end: time(17))
        let suggestion = advice(first: first, second: second, aToHome: 20, homeToB: 20, aToB: 12, buffer: 5)
        XCTAssertNil(suggestion, "arriving home at the leave-home moment still counts as assumed")
    }

    func testExtraBeforeOnBIsRequiredInTheHomePath() throws {
        // Leave A at 3:00. Needed 20+20+5+15 = 60. B at 4:00. Gap 60.
        let first = stop("a", "Class", start: time(14), end: time(15))
        let second = stop("b", "Dentist", start: time(16), end: time(17), extraBefore: 15)
        let fits = advice(first: first, second: second, aToHome: 20, homeToB: 20, aToB: 12, buffer: 5)
        XCTAssertNil(fits, "home path fits — no card")

        let noFit = try XCTUnwrap(
            advice(first: first, second: second, aToHome: 20, homeToB: 21, aToB: 12, buffer: 5)
        )
        XCTAssertEqual(noFit.kind, .stayOut)
    }

    func testLeavingHomeBufferDoesNotChangeDisplayedDriveMinutes() {
        let first = stop("a", "Class", start: time(9), end: time(10))
        let second = stop("b", "Barn", start: time(13), end: time(14), place: "Westwind")
        // Wide gap still fits after a 10 min leave-home buffer — silence, not a card.
        XCTAssertNil(
            advice(first: first, second: second, aToHome: 18, homeToB: 22, aToB: 12, buffer: 10)
        )
        XCTAssertEqual(
            HomeGapLogic.minutesAtHome(gap: 180, aToHome: 18, homeToB: 22, buffer: 10, before: 0),
            130
        )
    }

    // MARK: - Conflict

    func testImpossibleDirectTravelIsOneSuggestion() throws {
        let first = stop("a", "Dentist", start: time(14), end: time(15))
        let second = stop("b", "Riding", start: time(15, 10), end: time(16, 10))
        let suggestion = try XCTUnwrap(
            advice(first: first, second: second, aToHome: 20, homeToB: 20, aToB: 25, buffer: 5)
        )
        XCTAssertEqual(suggestion.kind, .cannotBeLived)
        XCTAssertEqual(suggestion.headline, String(localized: "Conflict"))
        XCTAssertEqual(suggestion.collapsedHeadline, String(localized: "Conflict"))
        XCTAssertNil(suggestion.collapsedSubtitle)
        XCTAssertTrue(suggestion.detail.contains("25"), suggestion.detail)
        XCTAssertTrue(suggestion.detail.contains("10"), suggestion.detail)
        XCTAssertFalse(suggestion.headline.contains("Don’t go home"))
        XCTAssertFalse(suggestion.headline.contains("can’t be lived"))
    }

    func testCollapsedHeadlinesStayOneLine() throws {
        let stayOut = try XCTUnwrap(
            advice(
                first: stop("a", "Dentist", start: time(14), end: time(15)),
                second: stop("b", "Riding", start: time(15, 40), end: time(16, 40), place: "barn"),
                aToHome: 20,
                homeToB: 20,
                aToB: 10,
                buffer: 5
            )
        )
        XCTAssertEqual(stayOut.kind, .stayOut)
        XCTAssertEqual(stayOut.collapsedHeadline, String(localized: "Don’t go home"))
        XCTAssertEqual(stayOut.collapsedSubtitle, String(localized: "Go to \(stayOut.secondTitle)"))
        XCTAssertTrue(stayOut.headline.contains("Don’t go home"), stayOut.headline)

        let overlap = try XCTUnwrap(
            advice(
                first: stop("a", "Dentist", start: time(14), end: time(16)),
                second: stop("b", "Riding", start: time(15, 30), end: time(17)),
                aToHome: 5,
                homeToB: 5,
                aToB: 5,
                buffer: 5
            )
        )
        XCTAssertEqual(overlap.collapsedHeadline, String(localized: "These overlap"))
        XCTAssertEqual(overlap.collapsedSubtitle, "Dentist / Riding")

        let transit = try XCTUnwrap(
            advice(
                first: stop("a", "Dentist", start: time(10), end: time(11)),
                second: stop("b", "Barn", start: time(11, 40), end: time(12, 40), place: "Westwind"),
                aToHome: 20,
                homeToB: 20,
                aToB: 50,
                aToBTransit: 25
            )
        )
        XCTAssertEqual(transit.kind, .takeTransit)
        XCTAssertEqual(transit.collapsedHeadline, String(localized: "Take transit"))
    }

    func testOverlapIsCannotBeLivedWithoutLookingAtDriveMinutes() throws {
        let first = stop("a", "Dentist", start: time(14), end: time(16))
        let second = stop("b", "Riding", start: time(15, 30), end: time(17))
        let suggestion = try XCTUnwrap(
            advice(first: first, second: second, aToHome: 5, homeToB: 5, aToB: 5, buffer: 5)
        )
        XCTAssertEqual(suggestion.kind, .cannotBeLived)
        XCTAssertEqual(suggestion.headline, String(localized: "These overlap"))
        XCTAssertEqual(suggestion.collapsedSubtitle, "Dentist / Riding")
        XCTAssertEqual(suggestion.detail, "Dentist / Riding")
        XCTAssertFalse(suggestion.headline.contains("can’t be lived"))
    }

    func testOverlapCollapsedSubtitleKeepsBothRawTitles() throws {
        let first = stop("a", "Chemistry", start: time(14), end: time(16))
        let second = stop("b", "Dentist", start: time(15, 30), end: time(17))
        let suggestion = try XCTUnwrap(
            advice(first: first, second: second, aToHome: 5, homeToB: 5, aToB: 5, buffer: 5)
        )
        XCTAssertEqual(suggestion.collapsedHeadline, String(localized: "These overlap"))
        XCTAssertEqual(suggestion.collapsedSubtitle, "Chemistry / Dentist")
        XCTAssertEqual(HomeGapSuggestion.pairLine("Chemistry", "Dentist"), "Chemistry / Dentist")
    }

    func testMissingHomeLegsStillFlagsImpossibleTravel() throws {
        let first = stop("a", "Dentist", start: time(14), end: time(15))
        let second = stop("b", "Riding", start: time(15, 10), end: time(16))
        let suggestion = try XCTUnwrap(
            advice(first: first, second: second, aToHome: nil, homeToB: nil, aToB: 30)
        )
        XCTAssertEqual(suggestion.kind, .cannotBeLived)
    }

    func testMissingHomeLegsStillSuggestsStayOutWhenDirectFits() throws {
        let first = stop("a", "Dentist", start: time(14), end: time(15))
        let second = stop("b", "Riding", start: time(17), end: time(18))
        let suggestion = try XCTUnwrap(
            advice(first: first, second: second, aToHome: nil, homeToB: nil, aToB: 15)
        )
        XCTAssertEqual(suggestion.kind, .stayOut)
        XCTAssertEqual(suggestion.headline, "Don’t go home — go to Riding")
        XCTAssertFalse(suggestion.headline.contains(String(localized: "You can go home")))
        XCTAssertFalse(suggestion.bringItems.isEmpty)
    }

    func testDriveMissTransitFitsIsTakeTransit() throws {
        let first = stop("a", "Dentist", start: time(10), end: time(11))
        let second = stop("b", "Barn", start: time(11, 40), end: time(12, 40), place: "Westwind")
        let suggestion = try XCTUnwrap(
            advice(
                first: first,
                second: second,
                aToHome: 20,
                homeToB: 20,
                aToB: 50,
                aToBTransit: 25
            )
        )
        XCTAssertEqual(suggestion.kind, .takeTransit)
        XCTAssertTrue(suggestion.headline.localizedCaseInsensitiveContains("transit"))
        XCTAssertTrue(suggestion.detail.contains("~50 min"))
        XCTAssertTrue(suggestion.detail.contains("~25 min"))
        XCTAssertFalse(suggestion.detail.localizedCaseInsensitiveContains("last bus"))
    }

    func testDriveHomeMissTransitHomeFits() {
        let first = stop("a", "Lunch", start: time(12), end: time(13))
        let second = stop("b", "Barn", start: time(14, 20), end: time(15, 20))
        // Gap 80. Drive via home 40+40+5 = 85, miss. Transit via home 30+30+5 = 65, fit.
        let suggestion = advice(
            first: first,
            second: second,
            aToHome: 40,
            homeToB: 40,
            aToB: 20,
            aToHomeTransit: 30,
            homeToBTransit: 30
        )
        XCTAssertNil(suggestion, "transit home fits — still assumed, not a card")
    }

    func testPreferTransitIsANoteNotAGuess() {
        let first = stop("a", "Class", start: time(9), end: time(10))
        let second = stop("b", "Barn", start: time(13), end: time(14))
        XCTAssertNil(
            advice(
                first: first,
                second: second,
                aToHome: 15,
                homeToB: 15,
                aToB: 20,
                aToBTransit: 35,
                preferTransit: true
            )
        )
        XCTAssertEqual(
            HomeGapLogic.transitNote(drive: 20, transit: 35, preferTransit: true),
            ScedraString("Transit ~\(35) min (preferred). Drive ~\(20) min.")
        )
    }

    func testNilTransitNeverInvented() {
        XCTAssertNil(HomeGapLogic.transitNote(drive: 15, transit: nil, preferTransit: false))
        XCTAssertNil(HomeGapLogic.transitNote(drive: 15, transit: nil, preferTransit: true))
    }

    func testAppleMapsHandoffUsesTransitWhenPreferred() {
        XCTAssertEqual(
            MapsHandoff.appleMapsMode(for: .transit),
            MKLaunchOptionsDirectionsModeTransit
        )
        XCTAssertEqual(
            MapsHandoff.appleMapsMode(for: .drive),
            MKLaunchOptionsDirectionsModeDriving
        )
        XCTAssertEqual(MapsHandoff.googleMapsMode(for: .transit), "transit")
        XCTAssertEqual(MapsHandoff.googleMapsMode(for: .drive), "driving")
    }

    // MARK: - Walk mention

    func testShortDriveMentionsWalkingWithoutReplacingCarNumbers() {
        let first = stop("a", "Class", start: time(14), end: time(15))
        let second = stop("b", "Dentist", start: time(17), end: time(18))
        XCTAssertNil(
            advice(first: first, second: second, aToHome: 10, homeToB: 10, aToB: 12, walk: 15),
            "wide gap with a walkable drive — no card"
        )
        XCTAssertEqual(
            HomeGapLogic.walkingNote(aToB: 12, walkMinutes: 15),
            ScedraString("Also a \(15) min walk.")
        )
    }

    func testLongerThanWalkPreferenceDoesNotMentionWalking() {
        let first = stop("a", "Class", start: time(14), end: time(15))
        let second = stop("b", "Dentist", start: time(17), end: time(18))
        XCTAssertNil(
            advice(first: first, second: second, aToHome: 20, homeToB: 20, aToB: 20, walk: 15)
        )
        XCTAssertNil(HomeGapLogic.walkingNote(aToB: 20, walkMinutes: 15))
    }

    // MARK: - What to bring

    func testWhatToBringIsHumbleAndSpecific() {
        XCTAssertTrue(WhatToBring.items(title: "Riding", place: "Westwind Community Barn")[0].localizedCaseInsensitiveContains("riding"))
        XCTAssertTrue(WhatToBring.items(title: "Dentist", place: "Stanford")[0].localizedCaseInsensitiveContains("dentist"))
        XCTAssertEqual(
            WhatToBring.items(title: "McDonald’s", place: "University Ave")[0],
            String(localized: "Anything you need for McDonald’s at University Ave")
        )
        XCTAssertTrue(WhatToBring.items(title: "Office standup", place: "")[0].localizedCaseInsensitiveContains("laptop"))
    }

    func testTooLittleTimeAtHomeStaysOutEvenWhenDrivesFit() throws {
        // Leave A at 3:00. Drive-home path 15+15+5 = 35 fits a 60 min gap.
        // Minutes at home = 60-15-15-5 = 25, below a 30 min “don’t bother” floor.
        let first = stop("a", "Class", start: time(14), end: time(15))
        let second = stop("b", "Barn", start: time(16), end: time(17), place: "Westwind")
        let suggestion = try XCTUnwrap(
            advice(
                first: first,
                second: second,
                aToHome: 15,
                homeToB: 15,
                aToB: 12,
                buffer: 5,
                minHome: 30
            )
        )
        XCTAssertEqual(suggestion.kind, .stayOut)
        XCTAssertTrue(suggestion.detail.contains("25 min at home"), suggestion.detail)
        XCTAssertTrue(suggestion.detail.contains("need 30"), suggestion.detail)
        XCTAssertTrue(
            suggestion.bringItems.contains { $0.localizedCaseInsensitiveContains("riding") },
            "\(suggestion.bringItems)"
        )
    }

    func testTransitHomeTooLittleTimeStaysOut() throws {
        // Gap 80. Drive via home 85 misses. Transit via home 65 fits, but
        // 80-30-30-5 = 15 min at home is below the 20 min floor.
        let first = stop("a", "Lunch", start: time(12), end: time(13))
        let second = stop("b", "Barn", start: time(14, 20), end: time(15, 20), place: "Westwind")
        let suggestion = try XCTUnwrap(
            advice(
                first: first,
                second: second,
                aToHome: 40,
                homeToB: 40,
                aToB: 20,
                aToHomeTransit: 30,
                homeToBTransit: 30,
                minHome: 20
            )
        )
        XCTAssertEqual(suggestion.kind, .stayOut)
        XCTAssertFalse(suggestion.headline.contains(String(localized: "You can go home")))
        XCTAssertTrue(suggestion.detail.contains("15 min at home"), suggestion.detail)
        XCTAssertTrue(suggestion.detail.contains("need 20"), suggestion.detail)
    }

    func testGoHomeKeepsStandingBringOnly() {
        let dentist = stop("a", "Dentist", start: time(14), end: time(15), place: "Valencia")
        let riding = stop("b", "Riding", start: time(17), end: time(18), place: "Westwind Community Barn")
        XCTAssertNil(
            advice(
                first: dentist,
                second: riding,
                aToHome: 20,
                homeToB: 25,
                aToB: 15,
                standing: ["charger", "keys"]
            ),
            "standing list is not a reason to show a go-home card"
        )
        XCTAssertEqual(
            WhatToBring.pack(
                title: riding.title,
                place: riding.displayPlace,
                kind: .goHome,
                standing: ["charger", "keys"]
            ),
            ["charger", "keys"]
        )
    }

    func testStayOutMergesStandingAndInferred() throws {
        let first = stop("a", "Class", start: time(14), end: time(15))
        let second = stop("b", "Riding", start: time(15, 40), end: time(16, 40), place: "barn")
        let suggestion = try XCTUnwrap(
            advice(
                first: first,
                second: second,
                aToHome: 20,
                homeToB: 20,
                aToB: 10,
                standing: ["charger"]
            )
        )
        XCTAssertEqual(suggestion.kind, .stayOut)
        XCTAssertEqual(suggestion.bringItems.first, "charger")
        XCTAssertTrue(suggestion.bringItems.contains { $0.localizedCaseInsensitiveContains("riding") })
    }

    func testMinutesAtHomeSubtractsEveryLegAndBufferAndBefore() {
        XCTAssertEqual(
            HomeGapLogic.minutesAtHome(gap: 60, aToHome: 15, homeToB: 15, buffer: 5, before: 10),
            15
        )
        XCTAssertEqual(
            HomeGapLogic.minutesAtHome(gap: 45, aToHome: 20, homeToB: 20, buffer: 5, before: 0),
            0
        )
    }

    func testExtraBeforeCanPushAFittingDriveBelowMinHome() throws {
        // Leave A at 3:00. Needed 15+15+5+15 = 50, gap 60 — drives fit.
        // At home = 60-15-15-5-15 = 10, below the 20 min floor.
        let first = stop("a", "Class", start: time(14), end: time(15))
        let second = stop("b", "Barn", start: time(16), end: time(17), place: "Westwind", extraBefore: 15)
        let suggestion = try XCTUnwrap(
            advice(
                first: first,
                second: second,
                aToHome: 15,
                homeToB: 15,
                aToB: 12,
                buffer: 5,
                minHome: 20
            )
        )
        XCTAssertEqual(suggestion.kind, .stayOut)
        XCTAssertTrue(suggestion.detail.contains("10 min at home"), suggestion.detail)
    }

    func testExactDriveFitWithDefaultMinHomeIsStayOut() throws {
        // Leave A at 3:15. Needed 20+20+5 = 45. B at 4:00. Gap 45. At home = 0.
        let first = stop("a", "Class", start: time(14), end: time(15), extraAfter: 15)
        let second = stop("b", "Dentist", start: time(16), end: time(17))
        let suggestion = try XCTUnwrap(
            advice(
                first: first,
                second: second,
                aToHome: 20,
                homeToB: 20,
                aToB: 12,
                buffer: 5,
                minHome: UserProfile.defaultMinimumHomeMinutes
            )
        )
        XCTAssertEqual(suggestion.kind, .stayOut)
        XCTAssertTrue(suggestion.detail.contains("0 min at home"), suggestion.detail)
    }

    func testNotifyDateIsFifteenMinutesBeforeOfficialEnd() throws {
        let first = stop("a", "Class", start: time(14), end: time(15), extraAfter: 20)
        XCTAssertEqual(HomeGapLogic.notifyDate(before: first), time(14, 45))
        XCTAssertNil(
            advice(
                first: first,
                second: stop("b", "Barn", start: time(18), end: time(19), place: "Westwind"),
                aToB: 12
            ),
            "wide gap is assumed — no go-home notification"
        )

        let stayOut = try XCTUnwrap(
            advice(
                first: first,
                second: stop("c", "Riding", start: time(15, 40), end: time(16, 40), place: "barn"),
                aToHome: 20,
                homeToB: 20,
                aToB: 10,
                standing: ["charger"]
            )
        )
        XCTAssertEqual(stayOut.kind, .stayOut)
        let stayBody = HomeGapNotifier.body(for: stayOut)
        XCTAssertTrue(stayBody.contains("Bring: charger"), stayBody)
        XCTAssertTrue(stayBody.localizedCaseInsensitiveContains("riding"), stayBody)
    }

    func testNotificationDraftsSkipPastAndKeepFuturePlan() throws {
        let first = stop("a", "Class", start: time(14), end: time(15))
        let second = stop("b", "Riding", start: time(15, 40), end: time(16, 40), place: "barn")
        let suggestion = try XCTUnwrap(
            advice(first: first, second: second, aToHome: 20, homeToB: 20, aToB: 10)
        )
        XCTAssertTrue(HomeGapNotifier.drafts(from: [suggestion], now: time(14, 50)).isEmpty)
        let drafts = HomeGapNotifier.drafts(from: [suggestion], now: time(14, 20))
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].identifier, HomeGapNotifier.idPrefix + suggestion.id)
        XCTAssertEqual(drafts[0].title, suggestion.headline)
        XCTAssertEqual(drafts[0].fire, time(14, 45))
        XCTAssertFalse(suggestion.bringItems.isEmpty)
        XCTAssertTrue(drafts[0].body.contains(suggestion.bringItems[0]), drafts[0].body)
    }

    func testTightDayDoesNotScheduleALockScreenNotification() throws {
        let first = stop("a", "Class", start: time(14), end: time(15))
        let second = stop("b", "Riding", start: time(15, 10), end: time(16, 10))
        let suggestion = try XCTUnwrap(
            advice(first: first, second: second, aToHome: 20, homeToB: 20, aToB: 25)
        )
        XCTAssertEqual(suggestion.kind, .cannotBeLived)
        XCTAssertEqual(suggestion.headline, String(localized: "Conflict"))
        XCTAssertTrue(HomeGapNotifier.drafts(from: [suggestion], now: time(14, 20)).isEmpty)
    }

    func testNavigateHandoffUsesRealMapsDirections() throws {
        let options = MapsHandoff.appleMapsLaunchOptions(mode: .drive)
        XCTAssertEqual(options[MKLaunchOptionsDirectionsModeKey], MKLaunchOptionsDirectionsModeDriving)
        XCTAssertEqual(
            MapsHandoff.appleMapsLaunchOptions(mode: .transit)[MKLaunchOptionsDirectionsModeKey],
            MKLaunchOptionsDirectionsModeTransit
        )
        let google = try XCTUnwrap(
            MapsHandoff.googleMapsWebURL(latitude: 37.3576, longitude: -122.1503, mode: .transit)
        )
        XCTAssertTrue(google.absoluteString.contains("maps.google.com"))
        XCTAssertTrue(google.absoluteString.contains("directionsmode=transit"))
        let waze = try XCTUnwrap(MapsHandoff.wazeWebURL(latitude: 37.3576, longitude: -122.1503))
        XCTAssertTrue(waze.absoluteString.contains("navigate=yes"))
    }

    func testDestinationPinIsCopiedOntoTheSuggestion() throws {
        var barn = stop("b", "Riding", start: time(15, 40), end: time(16, 40), place: "Westwind")
        barn.latitude = 37.3576
        barn.longitude = -122.1503
        let suggestion = try XCTUnwrap(
            advice(
                first: stop("a", "Dentist", start: time(14), end: time(15)),
                second: barn,
                aToHome: 20,
                homeToB: 20,
                aToB: 10
            )
        )
        XCTAssertEqual(suggestion.kind, .stayOut)
        XCTAssertEqual(suggestion.destinationLatitude, 37.3576)
        XCTAssertEqual(suggestion.destinationLongitude, -122.1503)
    }

    func testStandingBringParsesLinesAndCommas() {
        XCTAssertEqual(
            UserProfile.standingItems(from: "charger\nhelmet, keys; badge"),
            ["charger", "helmet", "keys", "badge"]
        )
        XCTAssertEqual(UserProfile.defaultMinimumHomeMinutes, 20)
        XCTAssertEqual(HomeGapLogic.notifyLeadMinutes, 15)
    }

    // MARK: - Pairing and official times

    func testConsecutivePairsAreSameDayOnly() {
        let morning = stop("a", "Class", start: time(9), end: time(10))
        let noon = stop("b", "Lunch", start: time(12), end: time(13))
        let tomorrow = HomeGapStop(
            id: "c",
            title: "Dentist",
            place: "",
            officialStart: time(9).addingTimeInterval(24 * 3600),
            officialEnd: time(10).addingTimeInterval(24 * 3600),
            extraBeforeMinutes: 0,
            extraAfterMinutes: 0,
            usesHome: false
        )
        let pairs = HomeGapLogic.consecutivePairs(from: [morning, tomorrow, noon], calendar: cal)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].0.id, "a")
        XCTAssertEqual(pairs[0].1.id, "b")
    }

    func testOfficialWindowIgnoresTravelPadding() throws {
        let officialStart = time(10, 16)
        let officialEnd = time(11, 16)
        let window = TravelEstimator.appointmentWindow(from: officialStart, to: officialEnd)
        let paddedStart = officialStart.addingTimeInterval(-25 * 60)
        let paddedEnd = officialEnd.addingTimeInterval(25 * 60)
        let parsed = try XCTUnwrap(
            OfficialAppointmentWindow.parse(window, around: paddedStart, blockEnd: paddedEnd, calendar: cal)
        )
        XCTAssertEqual(parsed.start, officialStart)
        XCTAssertEqual(parsed.end, officialEnd)

        let notes = EventNotes.body(
            forOriginal: "Riding, West wind barn",
            details: TravelEstimator.noteLines(
                appointmentStart: officialStart,
                appointmentEnd: officialEnd,
                travel: TravelEstimator.estimate(
                    minutes: 25,
                    mode: .drive,
                    start: officialStart,
                    bufferMinutes: 0,
                    returnMinutes: 25
                ),
                place: "Westwind Community Barn"
            )
        )
        let item = TodayItem(
            id: "padded",
            title: "Riding",
            start: paddedStart,
            end: paddedEnd,
            isAllDay: false,
            location: "Westwind Community Barn",
            notes: notes,
            latitude: 37.3576,
            longitude: -122.1503
        )
        XCTAssertEqual(item.officialStart, officialStart)
        XCTAssertEqual(item.officialEnd, officialEnd)
        XCTAssertEqual(item.asHomeGapStop().officialStart, officialStart)
        XCTAssertEqual(item.navigationCoordinate?.latitude, 37.3576)
    }

    func testEmptyPlaceUsesHomePin() throws {
        let home = CLLocation(latitude: 37.44, longitude: -122.14)
        let stop = stop("a", "Lunch", start: time(12), end: time(13), usesHome: true)
        let pin = try XCTUnwrap(HomeGapLogic.pin(for: stop, home: home))
        XCTAssertEqual(pin.latitude, home.coordinate.latitude, accuracy: 0.0001)
        XCTAssertTrue(HomeGapLogic.looksLikeHome("home"))
        XCTAssertTrue(HomeGapLogic.looksLikeHome("Home · 123 Main"))
        XCTAssertFalse(HomeGapLogic.looksLikeHome("Westwind Community Barn"))
    }

    func testDefaultLeavingHomeBufferIsFive() {
        XCTAssertEqual(UserProfile.defaultHomeGapMinutes, 5)
        XCTAssertEqual(HomeGapLogic.shortLeftoverMinutes, 15)
    }

    func testLeaveToNavigateFiresAtLeaveByWithGoogleAndWaze() throws {
        let officialStart = time(10, 16)
        let officialEnd = time(11, 16)
        let estimate = TravelEstimator.estimate(
            minutes: 25,
            mode: .drive,
            start: officialStart,
            bufferMinutes: 0,
            returnMinutes: 25
        )
        let notes = EventNotes.body(
            forOriginal: "school at 10:16",
            details: TravelEstimator.noteLines(
                appointmentStart: officialStart,
                appointmentEnd: officialEnd,
                travel: estimate,
                place: "school · 100 Example Ave, Springfield, IL 62701"
            )
        )
        let item = TodayItem(
            id: "school-leave",
            title: "school",
            start: estimate.leaveBy,
            end: officialEnd.addingTimeInterval(25 * 60),
            isAllDay: false,
            location: "school · 100 Example Ave, Springfield, IL 62701",
            notes: notes,
            latitude: 39.7817,
            longitude: -89.6501
        )
        XCTAssertEqual(LeaveToNavigateNotifier.leaveBy(for: item), estimate.leaveBy)
        XCTAssertEqual(LeaveToNavigateNotifier.driveMinutes(from: item.savedInfo.driveLine), 25)

        XCTAssertNil(
            LeaveToNavigateNotifier.draft(for: item, now: estimate.leaveBy.addingTimeInterval(60))
        )
        let draft = try XCTUnwrap(
            LeaveToNavigateNotifier.draft(for: item, now: time(8))
        )
        XCTAssertEqual(draft.fire, estimate.leaveBy)
        XCTAssertEqual(draft.title, String(localized: "Time to leave for school"))
        XCTAssertTrue(draft.body.contains("Google Maps"), draft.body)
        XCTAssertTrue(draft.body.contains("Waze"), draft.body)
        XCTAssertEqual(draft.latitude, 39.7817)
        XCTAssertEqual(draft.longitude, -89.6501)
        XCTAssertTrue(draft.identifier.hasPrefix(LeaveToNavigateNotifier.idPrefix))

        XCTAssertEqual(LeaveToNavigateNotifier.mapsApp(for: LeaveToNavigateNotifier.googleAction), "google")
        XCTAssertEqual(LeaveToNavigateNotifier.mapsApp(for: LeaveToNavigateNotifier.wazeAction), "waze")
        XCTAssertEqual(
            LeaveToNavigateNotifier.mapsApp(for: UNNotificationDefaultActionIdentifier),
            "google"
        )

        let google = try XCTUnwrap(
            MapsHandoff.googleMapsWebURL(latitude: draft.latitude, longitude: draft.longitude, mode: .drive)
        )
        XCTAssertTrue(google.absoluteString.contains("maps.google.com"))
        let waze = try XCTUnwrap(MapsHandoff.wazeWebURL(latitude: draft.latitude, longitude: draft.longitude))
        XCTAssertTrue(waze.absoluteString.contains("navigate=yes"))
    }

    func testLeaveToNavigateUsesTransitLeaveByNotCarLeaveBy() throws {
        let officialStart = time(10, 16)
        let officialEnd = time(11, 16)
        let drive = TravelEstimator.estimate(
            minutes: 12,
            mode: .drive,
            start: officialStart,
            bufferMinutes: 0,
            returnMinutes: 12
        )
        let transit = TravelEstimator.estimate(
            minutes: 28,
            mode: .transit,
            start: officialStart,
            bufferMinutes: 0,
            returnMinutes: 30
        )
        XCTAssertNotEqual(drive.leaveBy, transit.leaveBy)

        let notes = EventNotes.body(
            forOriginal: "mcdonalds at 10:16",
            details: TravelEstimator.noteLines(
                appointmentStart: officialStart,
                appointmentEnd: officialEnd,
                travel: transit,
                place: "McDonald's · 1100 El Camino Real, Menlo Park"
            )
        )
        let item = TodayItem(
            id: "transit-leave",
            title: "mcdonalds",
            start: transit.leaveBy,
            end: officialEnd.addingTimeInterval(30 * 60),
            isAllDay: false,
            location: "McDonald's · 1100 El Camino Real, Menlo Park",
            notes: notes,
            latitude: 37.452,
            longitude: -122.181
        )
        XCTAssertEqual(item.appointmentTravelMode, .transit)
        XCTAssertEqual(LeaveToNavigateNotifier.leaveBy(for: item), transit.leaveBy)
        XCTAssertNotEqual(LeaveToNavigateNotifier.leaveBy(for: item), drive.leaveBy)

        let draft = try XCTUnwrap(
            LeaveToNavigateNotifier.draft(for: item, now: time(8), mode: .transit)
        )
        XCTAssertEqual(draft.fire, transit.leaveBy)
        XCTAssertEqual(draft.mode, .transit)
        let destination = item.placeLabel ?? item.title
        XCTAssertTrue(
            draft.body.contains(String(localized: "Leave now — transit to \(destination).")),
            draft.body
        )
        XCTAssertFalse(draft.body.contains("Waze"), draft.body)

        let google = try XCTUnwrap(
            MapsHandoff.googleMapsWebURL(latitude: draft.latitude, longitude: draft.longitude, mode: draft.mode)
        )
        XCTAssertTrue(google.absoluteString.contains("directionsmode=transit"), google.absoluteString)
        XCTAssertEqual(
            MapsHandoff.appleMapsLaunchOptions(mode: .transit)[MKLaunchOptionsDirectionsModeKey],
            MKLaunchOptionsDirectionsModeTransit
        )
    }

    func testLeaveToNavigateNeedsAPinAndALeaveBy() {
        let officialStart = time(14)
        let item = TodayItem(
            id: "no-pin",
            title: "dentist",
            start: officialStart,
            end: time(15),
            isAllDay: false,
            location: "Valencia"
        )
        XCTAssertNil(LeaveToNavigateNotifier.leaveBy(for: item))
        XCTAssertNil(LeaveToNavigateNotifier.draft(for: item, now: time(8)))
    }
}
