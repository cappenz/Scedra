import SwiftUI
import UIKit
import XCTest
@testable import Scedra

/// Layout math for the Calendar tab's day timeline. Pure geometry — no views,
/// no EventKit — so every number the grid draws is checkable here.
final class ScedraTimelineTests: XCTestCase {
    private let cal = Calendar.current
    /// A plain mid-June day: no daylight-saving seam to skew the hour math.
    private lazy var dayStart: Date = cal.startOfDay(
        for: cal.date(from: DateComponents(year: 2026, month: 6, day: 10))!
    )
    /// 60pt hours make the expected offsets readable: 1 minute == 1 point.
    private let metrics = DayTimelineMetrics(hourHeight: 60, minimumBlockHeight: 20, columnSpacing: 4)

    private func time(_ hour: Int, _ minute: Int = 0) -> Date {
        dayStart.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
    }

    private func span(_ id: String, _ startHour: Int, _ startMinute: Int, _ endHour: Int, _ endMinute: Int) -> TimelineSpan {
        TimelineSpan(id: id, start: time(startHour, startMinute), end: time(endHour, endMinute))
    }

    private func layout(_ id: String, in blocks: [TimelineBlockLayout]) throws -> TimelineBlockLayout {
        try XCTUnwrap(blocks.first { $0.id == id }, "expected a block for \(id)")
    }

    private func blocks(_ spans: [TimelineSpan]) -> [TimelineBlockLayout] {
        DayTimelineLayout.blocks(for: spans, dayStart: dayStart, metrics: metrics)
    }

    // MARK: - Time to offset, duration to height

    func testTimeConvertsToVerticalOffset() {
        XCTAssertEqual(metrics.offset(for: dayStart, dayStart: dayStart), 0)
        XCTAssertEqual(metrics.offset(for: time(9, 30), dayStart: dayStart), 570, accuracy: 0.01)
        XCTAssertEqual(metrics.offset(for: time(18), dayStart: dayStart), 1080, accuracy: 0.01)
        XCTAssertEqual(metrics.totalHeight, 1440, accuracy: 0.01)
    }

    func testDurationConvertsToProportionalHeight() {
        XCTAssertEqual(metrics.height(forSeconds: 3600), 60, accuracy: 0.01)
        XCTAssertEqual(metrics.height(forSeconds: 90 * 60), 90, accuracy: 0.01)
        XCTAssertEqual(
            metrics.height(forSeconds: 10 * 60, contentMinimum: 68),
            68,
            accuracy: 0.01,
            "a short span still grows to hold its title, time, and location"
        )
        XCTAssertEqual(
            metrics.height(forSeconds: 90 * 60, contentMinimum: 68),
            90,
            accuracy: 0.01,
            "content minimum must not shrink a longer appointment"
        )
    }

    func testThreeHourEveningEventIsThreeHoursTall() throws {
        let placed = blocks([span("dinner", 18, 0, 21, 0)])
        let dinner = try layout("dinner", in: placed)
        XCTAssertEqual(dinner.top, 1080, accuracy: 0.01)
        XCTAssertEqual(dinner.height, 180, accuracy: 0.01, "6-9 PM should be three hours tall")
        XCTAssertFalse(dinner.continuesBeforeDay)
        XCTAssertFalse(dinner.continuesAfterDay)
    }

    // MARK: - Minimum height

    func testVeryShortEventGetsMinimumHeight() throws {
        let placed = blocks([span("checkin", 9, 0, 9, 10)])
        let checkin = try layout("checkin", in: placed)
        XCTAssertEqual(checkin.height, metrics.minimumBlockHeight, accuracy: 0.01)
        XCTAssertEqual(checkin.top, 540, accuracy: 0.01, "the minimum height must not move the start time")
    }

    func testShortEventStaysLegibleWithTheShippingMetrics() {
        let standard = DayTimelineMetrics.standard
        let fifteenMinutes = standard.height(forSeconds: 15 * 60)
        XCTAssertEqual(fifteenMinutes, standard.minimumBlockHeight, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(fifteenMinutes, 28, "a 15-minute event must stay tappable")
    }

    func testZeroLengthEventStillGetsABlock() throws {
        let placed = blocks([span("ping", 14, 0, 14, 0)])
        let ping = try layout("ping", in: placed)
        XCTAssertEqual(ping.height, metrics.minimumBlockHeight, accuracy: 0.01)
    }

    func testMinimumHeightBlockNearMidnightStaysInsideTheGrid() throws {
        let placed = blocks([span("late", 23, 55, 23, 58)])
        let late = try layout("late", in: placed)
        XCTAssertLessThanOrEqual(late.bottom, metrics.totalHeight + 0.01, "a block must not hang off the bottom")
        XCTAssertEqual(late.height, metrics.minimumBlockHeight, accuracy: 0.01)
    }

    // MARK: - Overlap clustering and columns

    func testEventsThatDoNotOverlapEachTakeTheFullWidth() throws {
        let placed = blocks([
            span("morning", 9, 0, 10, 0),
            span("afternoon", 14, 0, 15, 0)
        ])
        XCTAssertEqual(placed.count, 2)
        for id in ["morning", "afternoon"] {
            let block = try layout(id, in: placed)
            XCTAssertEqual(block.columnCount, 1)
            XCTAssertEqual(block.column, 0)
            XCTAssertEqual(block.width(inLaneWidth: 300, spacing: 4), 300, accuracy: 0.01)
            XCTAssertEqual(block.xOffset(inLaneWidth: 300), 0, accuracy: 0.01)
        }
    }

    func testBackToBackEventsDoNotCountAsOverlapping() throws {
        let placed = blocks([
            span("first", 9, 0, 10, 0),
            span("second", 10, 0, 11, 0)
        ])
        XCTAssertEqual(try layout("first", in: placed).columnCount, 1)
        XCTAssertEqual(try layout("second", in: placed).columnCount, 1)
    }

    func testTwoOverlappingEventsSitSideBySide() throws {
        let placed = blocks([
            span("dentist", 9, 0, 10, 0),
            span("standup", 9, 30, 10, 30)
        ])
        let dentist = try layout("dentist", in: placed)
        let standup = try layout("standup", in: placed)
        XCTAssertEqual(dentist.columnCount, 2)
        XCTAssertEqual(standup.columnCount, 2)
        XCTAssertEqual(Set([dentist.column, standup.column]), [0, 1], "they must not share a column")
        XCTAssertEqual(dentist.xOffset(inLaneWidth: 300), 0, accuracy: 0.01)
        XCTAssertEqual(standup.xOffset(inLaneWidth: 300), 150, accuracy: 0.01)
        XCTAssertEqual(standup.width(inLaneWidth: 300, spacing: 4), 146, accuracy: 0.01)
    }

    func testThreeMutuallyOverlappingEventsSplitIntoThreeColumns() throws {
        let placed = blocks([
            span("a", 9, 0, 12, 0),
            span("b", 9, 30, 11, 0),
            span("c", 10, 0, 10, 45)
        ])
        let columns = try ["a", "b", "c"].map { try layout($0, in: placed).column }
        XCTAssertEqual(Set(columns), [0, 1, 2])
        for id in ["a", "b", "c"] {
            XCTAssertEqual(try layout(id, in: placed).columnCount, 3)
        }
    }

    func testChainedOverlapReusesTheFreedColumn() throws {
        // A overlaps B, B overlaps C, but A and C never touch.
        let placed = blocks([
            span("a", 9, 0, 10, 0),
            span("b", 9, 30, 10, 30),
            span("c", 10, 0, 11, 0)
        ])
        let a = try layout("a", in: placed)
        let b = try layout("b", in: placed)
        let c = try layout("c", in: placed)
        XCTAssertEqual(a.columnCount, 2, "a chain only needs as many columns as the deepest pile-up")
        XCTAssertEqual(b.columnCount, 2)
        XCTAssertEqual(c.columnCount, 2)
        XCTAssertEqual(a.column, 0)
        XCTAssertEqual(b.column, 1)
        XCTAssertEqual(c.column, 0, "c should reuse the column a has finished with")
    }

    func testSeparateOverlapClustersAreSizedIndependently() throws {
        let placed = blocks([
            span("pairA", 9, 0, 10, 0),
            span("pairB", 9, 15, 10, 15),
            span("alone", 15, 0, 16, 0)
        ])
        XCTAssertEqual(try layout("pairA", in: placed).columnCount, 2)
        XCTAssertEqual(try layout("alone", in: placed).columnCount, 1, "a later event shouldn't be narrowed by an earlier clash")
    }

    // MARK: - Day boundaries

    func testEventStartingYesterdayIsClippedAtTheTopAndFlagged() throws {
        let redEye = TimelineSpan(
            id: "redEye",
            start: dayStart.addingTimeInterval(-2 * 3600),
            end: time(2, 0)
        )
        let placed = blocks([redEye])
        let block = try layout("redEye", in: placed)
        XCTAssertEqual(block.top, 0, accuracy: 0.01)
        XCTAssertEqual(block.height, 120, accuracy: 0.01, "only the part inside the day is drawn")
        XCTAssertTrue(block.continuesBeforeDay)
        XCTAssertFalse(block.continuesAfterDay)
    }

    func testEventEndingTomorrowIsClippedAtTheBottomAndFlagged() throws {
        let overnight = TimelineSpan(
            id: "overnight",
            start: time(23, 0),
            end: dayStart.addingTimeInterval(25 * 3600)
        )
        let placed = blocks([overnight])
        let block = try layout("overnight", in: placed)
        XCTAssertEqual(block.top, 1380, accuracy: 0.01)
        XCTAssertEqual(block.height, 60, accuracy: 0.01)
        XCTAssertEqual(block.bottom, metrics.totalHeight, accuracy: 0.01)
        XCTAssertTrue(block.continuesAfterDay)
        XCTAssertFalse(block.continuesBeforeDay)
    }

    func testEventSpanningTheWholeDayFillsTheGridAndIsFlaggedBothWays() throws {
        let trip = TimelineSpan(
            id: "trip",
            start: dayStart.addingTimeInterval(-6 * 3600),
            end: dayStart.addingTimeInterval(30 * 3600)
        )
        let block = try layout("trip", in: blocks([trip]))
        XCTAssertEqual(block.top, 0, accuracy: 0.01)
        XCTAssertEqual(block.height, metrics.totalHeight, accuracy: 0.01)
        XCTAssertTrue(block.continuesBeforeDay)
        XCTAssertTrue(block.continuesAfterDay)
    }

    func testEventsOutsideTheDayAreDropped() {
        let yesterday = TimelineSpan(
            id: "yesterday",
            start: dayStart.addingTimeInterval(-4 * 3600),
            end: dayStart.addingTimeInterval(-3 * 3600)
        )
        let tomorrow = TimelineSpan(
            id: "tomorrow",
            start: dayStart.addingTimeInterval(26 * 3600),
            end: dayStart.addingTimeInterval(27 * 3600)
        )
        XCTAssertTrue(blocks([yesterday, tomorrow]).isEmpty)
    }

    func testEmptyDayProducesNoBlocks() {
        XCTAssertTrue(blocks([]).isEmpty)
    }

    // MARK: - Where the day opens

    func testTodayOpensNearTheCurrentHour() {
        let hour = DayTimelineLayout.initialScrollHour(
            day: dayStart,
            now: time(15, 20),
            spans: [],
            calendar: cal
        )
        XCTAssertEqual(hour, 14, "today should open an hour above now for context")
    }

    func testAnotherDayOpensOnItsFirstEvent() {
        let hour = DayTimelineLayout.initialScrollHour(
            day: dayStart,
            now: dayStart.addingTimeInterval(-3 * 24 * 3600),
            spans: [span("late", 14, 0, 15, 0), span("later", 17, 0, 18, 0)],
            calendar: cal
        )
        XCTAssertEqual(hour, 13)
    }

    func testEmptyOtherDayOpensMidMorningRatherThanMidnight() {
        let hour = DayTimelineLayout.initialScrollHour(
            day: dayStart,
            now: dayStart.addingTimeInterval(-3 * 24 * 3600),
            spans: [],
            calendar: cal
        )
        XCTAssertEqual(hour, 8)
        XCTAssertNotEqual(hour, 0, "never open on 12:00 AM")
    }

    func testOpeningHourNeverLeavesTheGrid() {
        let earlyMorning = DayTimelineLayout.initialScrollHour(
            day: dayStart,
            now: time(0, 5),
            spans: [],
            calendar: cal
        )
        XCTAssertEqual(earlyMorning, 0)
        let lateNight = DayTimelineLayout.initialScrollHour(
            day: dayStart,
            now: time(23, 50),
            spans: [],
            calendar: cal
        )
        XCTAssertEqual(lateNight, 22)
    }

    // MARK: - What a block shows: delete must stay visible

    /// The lane a block is drawn into on a phone: screen width, less the screen
    /// padding, the timeline's own padding, the hour gutter and the lane inset.
    private let phoneLaneWidth: CGFloat = 277

    private func chrome(for block: TimelineBlockLayout, laneWidth: CGFloat? = nil) -> TimelineBlockChrome {
        let lane = laneWidth ?? phoneLaneWidth
        let width = block.width(inLaneWidth: lane, spacing: DayTimelineMetrics.standard.columnSpacing)
        return TimelineBlockChrome.forBlock(height: block.height, width: width)
    }

    private func shippingBlocks(_ spans: [TimelineSpan]) -> [TimelineBlockLayout] {
        DayTimelineLayout.blocks(for: spans, dayStart: dayStart, metrics: .standard)
    }

    func testRoomyBlockShowsTimeLocationAndTrash() {
        let chrome = TimelineBlockChrome.forBlock(height: 120, width: phoneLaneWidth)
        XCTAssertTrue(chrome.showsTime)
        XCTAssertTrue(chrome.showsLocation)
        XCTAssertTrue(chrome.showsDelete, "a full-size block must show the trash, not hide delete in a long-press")
    }

    func testShortestDrawableBlockStillShowsTheTrash() {
        let floor = DayTimelineMetrics.standard.minimumBlockHeight
        let chrome = TimelineBlockChrome.forBlock(height: floor, width: phoneLaneWidth)
        XCTAssertTrue(chrome.showsDelete, "the minimum-height block is the common short appointment — it needs a visible trash")
        XCTAssertFalse(chrome.showsTime, "there is no room for a time line at the floor height")
    }

    func testHalfHourAppointmentOnARealDayShowsTheTrash() throws {
        let placed = shippingBlocks([span("dentist", 14, 0, 14, 30)])
        let dentist = try layout("dentist", in: placed)
        XCTAssertTrue(chrome(for: dentist).showsDelete)
    }

    func testFifteenMinuteAppointmentOnARealDayShowsTheTrash() throws {
        let placed = shippingBlocks([span("pickup", 9, 0, 9, 15)])
        let pickup = try layout("pickup", in: placed)
        XCTAssertEqual(pickup.height, DayTimelineMetrics.standard.minimumBlockHeight, accuracy: 0.01)
        XCTAssertTrue(chrome(for: pickup).showsDelete)
    }

    func testTwoOverlappingEventsBothKeepTheirTrash() throws {
        let placed = shippingBlocks([
            span("dentist", 9, 0, 10, 0),
            span("standup", 9, 30, 10, 30)
        ])
        for id in ["dentist", "standup"] {
            let block = try layout(id, in: placed)
            XCTAssertEqual(block.columnCount, 2)
            XCTAssertTrue(chrome(for: block).showsDelete, "\(id) is half-width but still wide enough for a trash")
        }
    }

    func testSliverInACrowdedClusterDropsTheTrashRatherThanCoveringTheTitle() throws {
        // Four mutually overlapping events leave each block about 65pt wide.
        let placed = shippingBlocks([
            span("a", 9, 0, 12, 0),
            span("b", 9, 15, 11, 30),
            span("c", 9, 30, 11, 0),
            span("d", 9, 45, 10, 30)
        ])
        let a = try layout("a", in: placed)
        XCTAssertEqual(a.columnCount, 4)
        XCTAssertFalse(chrome(for: a).showsDelete, "a sliver falls back to the context menu")
        XCTAssertFalse(chrome(for: a).showsTime)
    }

    // MARK: - Content-minimum height: bubble grows to hold its text

    func testContentMinimumGrowsAShortEventWithoutMovingItsStart() throws {
        let placed = blocks([
            TimelineSpan(
                id: "errand",
                start: time(9, 0),
                end: time(9, 10),
                contentMinimumHeight: TimelineBlockChrome.locationMinimumHeight
            )
        ])
        let errand = try layout("errand", in: placed)
        XCTAssertEqual(errand.height, TimelineBlockChrome.locationMinimumHeight, accuracy: 0.01)
        XCTAssertEqual(errand.top, 540, accuracy: 0.01, "growing the bubble must not move the start time")
    }

    func testContentMinimumDoesNotShrinkALongEvent() throws {
        let placed = blocks([
            TimelineSpan(
                id: "dinner",
                start: time(18, 0),
                end: time(21, 0),
                contentMinimumHeight: TimelineBlockChrome.locationMinimumHeight
            )
        ])
        let dinner = try layout("dinner", in: placed)
        XCTAssertEqual(dinner.height, 180, accuracy: 0.01)
        XCTAssertEqual(dinner.top, 1080, accuracy: 0.01)
    }

    func testContentMinimumIsCappedBeforeTheNextEventInTheLane() throws {
        let placed = blocks([
            TimelineSpan(
                id: "short",
                start: time(9, 0),
                end: time(9, 10),
                contentMinimumHeight: TimelineBlockChrome.locationMinimumHeight
            ),
            span("later", 9, 40, 10, 40)
        ])
        let short = try layout("short", in: placed)
        let later = try layout("later", in: placed)
        XCTAssertEqual(later.top, 580, accuracy: 0.01)
        XCTAssertEqual(short.top, 540, accuracy: 0.01)
        XCTAssertEqual(short.height, 40, accuracy: 0.01, "grow down only until the next block in the same lane")
        XCTAssertEqual(short.columnCount, 1)
        XCTAssertEqual(later.columnCount, 1)
        XCTAssertLessThanOrEqual(short.bottom, later.top + 0.01)
    }

    func testContentMinimumDoesNotGrowIntoABackToBackEvent() throws {
        let placed = blocks([
            TimelineSpan(
                id: "first",
                start: time(9, 0),
                end: time(10, 0),
                contentMinimumHeight: 80
            ),
            span("second", 10, 0, 11, 0)
        ])
        let first = try layout("first", in: placed)
        XCTAssertEqual(first.height, 60, accuracy: 0.01, "a full-hour block already fills the gap before the next event")
        XCTAssertEqual(try layout("second", in: placed).columnCount, 1)
    }

    func testContentMinimumStillLetsOverlappingEventsSitSideBySide() throws {
        let placed = blocks([
            TimelineSpan(
                id: "dentist",
                start: time(9, 0),
                end: time(10, 0),
                contentMinimumHeight: 80
            ),
            TimelineSpan(
                id: "standup",
                start: time(9, 30),
                end: time(10, 30),
                contentMinimumHeight: 80
            )
        ])
        let dentist = try layout("dentist", in: placed)
        let standup = try layout("standup", in: placed)
        XCTAssertEqual(dentist.columnCount, 2)
        XCTAssertEqual(standup.columnCount, 2)
        XCTAssertEqual(dentist.height, 80, accuracy: 0.01, "a neighbour in another column must not cap this bubble")
        XCTAssertEqual(standup.height, 80, accuracy: 0.01)
        XCTAssertEqual(dentist.top, 540, accuracy: 0.01)
        XCTAssertEqual(standup.top, 570, accuracy: 0.01)
    }

    func testContentMinimumHeightMatchesTheChromeThatWillDraw() {
        XCTAssertEqual(TimelineBlockChrome.contentMinimumHeight(showsTime: false, showsLocation: false), 30)
        XCTAssertEqual(TimelineBlockChrome.contentMinimumHeight(showsTime: true, showsLocation: false), 46)
        XCTAssertEqual(TimelineBlockChrome.contentMinimumHeight(showsTime: true, showsLocation: true), 68)
        let grown = TimelineBlockChrome.contentMinimumHeight(showsTime: true, showsLocation: true)
        let chrome = TimelineBlockChrome.forBlock(height: grown, width: phoneLaneWidth)
        XCTAssertTrue(chrome.showsTime)
        XCTAssertTrue(chrome.showsLocation)
        XCTAssertTrue(chrome.showsDelete)
    }

    func testAnythingRoomyEnoughForATimeLabelIsAlsoRoomyEnoughForTheTrash() {
        for height in stride(from: CGFloat(20), through: 200, by: 2) {
            for width in stride(from: CGFloat(40), through: 320, by: 4) {
                let chrome = TimelineBlockChrome.forBlock(height: height, width: width)
                if chrome.showsTime {
                    XCTAssertTrue(chrome.showsDelete, "a block legible enough for a time (\(height)x\(width)) must show the trash")
                }
                if chrome.showsLocation {
                    XCTAssertTrue(chrome.showsTime, "location without a time would read oddly")
                }
            }
        }
    }

    // MARK: - Which day content the Calendar tab picks

    func testEmptyDayWithFullAccessStillDrawsTheTimeline() {
        XCTAssertEqual(
            CalendarDayPresentation.of(access: .full, hasEvents: false),
            .timeline,
            "an empty day should show the hour grid and its own note, not a bare placeholder"
        )
    }

    func testDayWithEventsDrawsTheTimeline() {
        XCTAssertEqual(CalendarDayPresentation.of(access: .full, hasEvents: true), .timeline)
        XCTAssertEqual(CalendarDayPresentation.of(access: .writeOnly, hasEvents: true), .timeline)
    }

    func testWriteOnlyEmptyDayExplainsItselfInsteadOfShowingAnEmptyGrid() {
        XCTAssertEqual(
            CalendarDayPresentation.of(access: .writeOnly, hasEvents: false),
            .writeOnlyWithoutEvents
        )
    }

    func testAccessStatesTakePrecedenceOverTheGrid() {
        XCTAssertEqual(CalendarDayPresentation.of(access: .unknown, hasEvents: false), .checkingAccess)
        XCTAssertEqual(CalendarDayPresentation.of(access: .unknown, hasEvents: true), .checkingAccess)
        XCTAssertEqual(CalendarDayPresentation.of(access: .denied, hasEvents: false), .accessDenied)
        XCTAssertEqual(CalendarDayPresentation.of(access: .denied, hasEvents: true), .accessDenied)
    }

    func testTwoTimedEventsStillQualifyForDontGoHomeCardsOnCalendar() {
        let dentist = calendarItem("a", "Dentist", start: time(14), end: time(15), place: "Valencia")
        let riding = calendarItem("b", "Riding", start: time(15, 40), end: time(16, 40), place: "Westwind")
        XCTAssertTrue(
            CalendarDayHomeGap.shouldShowNotices(for: [dentist, riding]),
            "two timed stops on the selected day must still surface stay-out / conflict cards"
        )
        XCTAssertEqual(CalendarDayHomeGap.stops(from: [dentist, riding]).count, 2)
    }

    func testAllDayOrSingleEventDoesNotReserveACalendarHomeGapSlot() {
        let allDay = calendarItem("all", "Holiday", start: dayStart, end: time(23, 59), allDay: true)
        let only = calendarItem("one", "Dentist", start: time(14), end: time(15), place: "Valencia")
        XCTAssertFalse(CalendarDayHomeGap.shouldShowNotices(for: [allDay]))
        XCTAssertFalse(CalendarDayHomeGap.shouldShowNotices(for: [only]))
        XCTAssertFalse(CalendarDayHomeGap.shouldShowNotices(for: [allDay, only]))
    }

    private func calendarItem(
        _ id: String,
        _ title: String,
        start: Date,
        end: Date,
        place: String? = nil,
        allDay: Bool = false
    ) -> TodayItem {
        TodayItem(
            id: id,
            title: title,
            start: start,
            end: end,
            isAllDay: allDay,
            location: place
        )
    }

    // MARK: - Card width: column, not the address

    /// The screenshot: "Schoool · 100 Example Avenue, Springfield,IL627001" painted
    /// past the rounded bubble. A layout that hugs the untruncated string would
    /// report a width near the address; the card must stay the column slot.
    @MainActor
    func testBlockBodyWidthIsTheColumnNotTheUntruncatedAddress() {
        let address = "Schoool · 100 Example Avenue, Springfield,IL627001"
        let addressWidth = ceil((address as NSString).size(withAttributes: [
            .font: UIFont.systemFont(ofSize: 10)
        ]).width)
        let textColumn = TimelineBlockChrome.textWidth(
            cardWidth: phoneLaneWidth,
            reservesDeleteSpace: true
        )
        XCTAssertGreaterThan(
            addressWidth,
            textColumn,
            "precondition: the screenshot zip line is wider than the text column, so the old layout spilled"
        )

        let size = measureBlockBody(title: "Schoool", location: address, columnWidth: phoneLaneWidth)
        XCTAssertEqual(
            size.width,
            phoneLaneWidth,
            accuracy: 0.5,
            "card width must be the column (\(phoneLaneWidth)), not the address (\(addressWidth))"
        )

        // A column the raw address is wider than: hugging the string would
        // report ~addressWidth; the card must still be the slot.
        let narrowColumn: CGFloat = 160
        XCTAssertGreaterThan(addressWidth, narrowColumn)
        let narrow = measureBlockBody(title: "Schoool", location: address, columnWidth: narrowColumn)
        XCTAssertEqual(
            narrow.width,
            narrowColumn,
            accuracy: 0.5,
            "card width must stay the column, not grow to the untruncated address"
        )
        XCTAssertLessThan(narrow.width, addressWidth)
    }

    @MainActor
    private func measureBlockBody(title: String, location: String, columnWidth: CGFloat) -> CGSize {
        let item = TodayItem(
            id: "school",
            title: title,
            start: time(15, 22),
            end: time(17, 26),
            isAllDay: false,
            location: location
        )
        let layout = TimelineBlockLayout(
            id: "school",
            top: 0,
            height: 120,
            column: 0,
            columnCount: 1,
            continuesBeforeDay: false,
            continuesAfterDay: false
        )
        let view = TimelineBlockLabel(
            item: item,
            layout: layout,
            hasOriginal: true,
            showsDetail: true,
            showsLocation: true,
            reservesDeleteSpace: true,
            cornerRadius: 12,
            width: columnWidth,
            height: 120
        )
        let host = UIHostingController(rootView: view)
        host.safeAreaRegions = []
        // Propose a huge width so a body that still hugs the address would
        // report that ideal size instead of the column.
        let labelSize = host.sizeThatFits(in: CGSize(width: 4000, height: 400))

        let body = TimelineBlockBody(
            item: item,
            layout: layout,
            hasOriginal: true,
            showsDetail: true,
            showsLocation: true,
            reservesDeleteSpace: true,
            width: columnWidth,
            height: 120
        )
        let bodyHost = UIHostingController(rootView: body)
        bodyHost.safeAreaRegions = []
        let bodySize = bodyHost.sizeThatFits(in: CGSize(width: 4000, height: 400))
        XCTAssertEqual(
            bodySize.width,
            columnWidth,
            accuracy: 0.5,
            "hosted body width must stay the column, not grow to the address"
        )

        return labelSize
    }
}
