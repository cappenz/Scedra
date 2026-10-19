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
    private let metrics = DayTimelineMetrics(hourHeight: 60, minimumBlockHeight: 2, columnSpacing: 4)

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
        XCTAssertEqual(metrics.height(forSeconds: 10 * 60), 10, accuracy: 0.01)
    }

    func testThreeHourEveningEventIsThreeHoursTall() throws {
        let placed = blocks([span("dinner", 18, 0, 21, 0)])
        let dinner = try layout("dinner", in: placed)
        XCTAssertEqual(dinner.top, 1080, accuracy: 0.01)
        XCTAssertEqual(dinner.height, 180, accuracy: 0.01, "6-9 PM should be three hours tall")
        XCTAssertFalse(dinner.continuesBeforeDay)
        XCTAssertFalse(dinner.continuesAfterDay)
    }

    // MARK: - Exact start and end

    /// The screenshot: "Drive home 12:30–12:50" was drawn reaching past 1 PM.
    func testTwentyMinuteDriveEndsAtItsEndTimeOnTheShippingGrid() throws {
        let standard = DayTimelineMetrics.standard
        let placed = DayTimelineLayout.blocks(
            for: [span("drive", 12, 30, 12, 50)],
            dayStart: dayStart,
            metrics: standard
        )
        let drive = try layout("drive", in: placed)
        let perMinute = standard.hourHeight / 60
        XCTAssertEqual(drive.top, standard.offset(for: time(12, 30), dayStart: dayStart), accuracy: 0.01)
        XCTAssertEqual(drive.top, 750 * perMinute, accuracy: 0.01)
        XCTAssertEqual(drive.height, 20 * perMinute, accuracy: 0.01, "12:30–12:50 is 20 minutes tall")
        XCTAssertEqual(drive.bottom, standard.offset(for: time(12, 50), dayStart: dayStart), accuracy: 0.01)
        XCTAssertLessThan(drive.bottom, standard.offset(for: time(13), dayStart: dayStart) - 9 * perMinute)
    }

    /// The screenshot cluster: 3:00–4:00, 4:00–4:21, 4:20–5:20, 5:20–5:49.
    /// 4:00–4:21 must read as about a third of an hour, not a full hour row.
    func testAfternoonClusterKeepsExactStartAndEndOnTheShippingGrid() throws {
        let standard = DayTimelineMetrics.standard
        let placed = DayTimelineLayout.blocks(
            for: [
                span("target", 15, 0, 16, 0),
                span("drive", 16, 0, 16, 21),
                span("mart", 16, 20, 17, 20),
                span("home", 17, 20, 17, 49)
            ],
            dayStart: dayStart,
            metrics: standard
        )
        let target = try layout("target", in: placed)
        let drive = try layout("drive", in: placed)
        let mart = try layout("mart", in: placed)
        let home = try layout("home", in: placed)
        let perMinute = standard.hourHeight / 60

        XCTAssertEqual(target.top, standard.offset(for: time(15), dayStart: dayStart), accuracy: 0.01)
        XCTAssertEqual(target.height, standard.hourHeight, accuracy: 0.01)
        XCTAssertEqual(target.bottom, standard.offset(for: time(16), dayStart: dayStart), accuracy: 0.01)

        XCTAssertEqual(drive.top, standard.offset(for: time(16), dayStart: dayStart), accuracy: 0.01)
        XCTAssertEqual(drive.height, 21 * perMinute, accuracy: 0.01)
        XCTAssertEqual(drive.bottom, standard.offset(for: time(16, 21), dayStart: dayStart), accuracy: 0.01)
        XCTAssertEqual(
            drive.height / standard.hourHeight,
            21.0 / 60.0,
            accuracy: 0.001,
            "4:00–4:21 must be ~1/3 of an hour row"
        )
        XCTAssertLessThan(drive.bottom, standard.offset(for: time(16, 40), dayStart: dayStart))

        XCTAssertEqual(mart.top, standard.offset(for: time(16, 20), dayStart: dayStart), accuracy: 0.01)
        XCTAssertEqual(mart.height, 60 * perMinute, accuracy: 0.01)
        XCTAssertEqual(home.top, standard.offset(for: time(17, 20), dayStart: dayStart), accuracy: 0.01)
        XCTAssertEqual(home.height, 29 * perMinute, accuracy: 0.01)
        XCTAssertEqual(home.bottom, standard.offset(for: time(17, 49), dayStart: dayStart), accuracy: 0.01)
        XCTAssertEqual(drive.columnCount, 2, "4:00–4:21 overlaps 4:20–5:20; columns keep each height")
        XCTAssertEqual(try layout("drive", in: placed).height, 21 * perMinute, accuracy: 0.01)
        XCTAssertEqual(try layout("mart", in: placed).height, standard.hourHeight, accuracy: 0.01)
    }

    func testHourLongEventIsExactlyOneHourOnTheShippingGrid() throws {
        let standard = DayTimelineMetrics.standard
        let placed = DayTimelineLayout.blocks(
            for: [span("boba", 10, 15, 11, 15)],
            dayStart: dayStart,
            metrics: standard
        )
        let boba = try layout("boba", in: placed)
        XCTAssertEqual(boba.top, standard.offset(for: time(10, 15), dayStart: dayStart), accuracy: 0.01)
        XCTAssertEqual(boba.height, standard.hourHeight, accuracy: 0.01)
        XCTAssertEqual(boba.bottom, standard.offset(for: time(11, 15), dayStart: dayStart), accuracy: 0.01)
    }

    func testShortEventsAreNotStretchedToAMinimumHeight() throws {
        let placed = blocks([
            span("checkin", 9, 0, 9, 10),
            span("drive", 11, 15, 11, 33),
            span("pickup", 14, 0, 14, 15)
        ])
        XCTAssertEqual(try layout("checkin", in: placed).height, 10, accuracy: 0.01)
        XCTAssertEqual(try layout("checkin", in: placed).top, 540, accuracy: 0.01)
        XCTAssertEqual(try layout("drive", in: placed).height, 18, accuracy: 0.01)
        XCTAssertEqual(try layout("pickup", in: placed).height, 15, accuracy: 0.01)
    }

    func testBackToBackShortBlocksTouchWithoutOverlapping() throws {
        let placed = blocks([
            span("drive", 11, 15, 11, 30),
            span("walmart", 11, 30, 12, 30),
            span("home", 12, 30, 12, 50)
        ])
        let drive = try layout("drive", in: placed)
        let walmart = try layout("walmart", in: placed)
        let home = try layout("home", in: placed)
        XCTAssertEqual(drive.bottom, walmart.top, accuracy: 0.01)
        XCTAssertEqual(walmart.bottom, home.top, accuracy: 0.01)
        XCTAssertEqual(home.bottom, 770, accuracy: 0.01)
        for block in [drive, walmart, home] {
            XCTAssertEqual(block.columnCount, 1)
        }
    }

    func testZeroLengthEventStillGetsAVisibleSliver() throws {
        let placed = blocks([span("ping", 14, 0, 14, 0)])
        let ping = try layout("ping", in: placed)
        XCTAssertEqual(ping.height, metrics.minimumBlockHeight, accuracy: 0.01)
        XCTAssertEqual(ping.top, 840, accuracy: 0.01)
        XCTAssertLessThanOrEqual(DayTimelineMetrics.standard.minimumBlockHeight, 2, "the floor is for pings, not real events")
    }

    func testFloorHeightBlockNearMidnightStaysInsideTheGrid() throws {
        let placed = blocks([span("late", 23, 59, 23, 59)])
        let late = try layout("late", in: placed)
        XCTAssertLessThanOrEqual(late.bottom, metrics.totalHeight + 0.01, "a block must not hang off the bottom")
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
        XCTAssertEqual(dentist.top, 540, accuracy: 0.01)
        XCTAssertEqual(dentist.height, 60, accuracy: 0.01)
        XCTAssertEqual(standup.top, 570, accuracy: 0.01)
        XCTAssertEqual(standup.height, 60, accuracy: 0.01)
    }

    /// The screenshot's 11 AM pile-up: a long stop beside a short drive and the
    /// next stop. Columns split the width; every block keeps its own start/end.
    func testOverlappingBlocksKeepExactHeightsInTheirColumns() throws {
        let placed = blocks([
            span("boba", 10, 15, 11, 15),
            span("home", 11, 15, 11, 33),
            span("toWalmart", 11, 15, 11, 30),
            span("walmart", 11, 30, 12, 30)
        ])
        let home = try layout("home", in: placed)
        let toWalmart = try layout("toWalmart", in: placed)
        let walmart = try layout("walmart", in: placed)
        XCTAssertEqual(home.columnCount, 2)
        XCTAssertNotEqual(home.column, toWalmart.column)
        XCTAssertEqual(home.top, 675, accuracy: 0.01)
        XCTAssertEqual(home.height, 18, accuracy: 0.01)
        XCTAssertEqual(toWalmart.top, 675, accuracy: 0.01)
        XCTAssertEqual(toWalmart.height, 15, accuracy: 0.01)
        XCTAssertEqual(walmart.top, 690, accuracy: 0.01)
        XCTAssertEqual(walmart.height, 60, accuracy: 0.01)
        XCTAssertEqual(try layout("boba", in: placed).height, 60, accuracy: 0.01)
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

    func testTwentyMinuteDriveGoesCompactInsteadOfGrowing() throws {
        let placed = shippingBlocks([span("drive", 12, 30, 12, 50)])
        let drive = try layout("drive", in: placed)
        let chrome = chrome(for: drive)
        XCTAssertTrue(chrome.isCompact, "a 20-minute block keeps its height and shrinks its label")
        XCTAssertTrue(chrome.showsTime, "compact still shows title + time on one line")
        XCTAssertFalse(chrome.showsLocation)
        XCTAssertTrue(chrome.showsDelete)
        XCTAssertLessThanOrEqual(
            chrome.compactFontSize * 1.2 + TimelineBlockChrome.compactVerticalPadding * 2,
            drive.height + 0.01,
            "the single compact line must fit inside the true height"
        )
        XCTAssertLessThanOrEqual(chrome.deleteGlyphSize, drive.height - 4 + 0.01)
    }

    func testHalfHourAppointmentOnARealDayShowsTheTrash() throws {
        let placed = shippingBlocks([span("dentist", 14, 0, 14, 30)])
        let dentist = try layout("dentist", in: placed)
        XCTAssertTrue(chrome(for: dentist).showsDelete)
        XCTAssertTrue(chrome(for: dentist).isCompact)
    }

    func testFifteenMinuteAppointmentOnARealDayShowsTheTrash() throws {
        let placed = shippingBlocks([span("pickup", 9, 0, 9, 15)])
        let pickup = try layout("pickup", in: placed)
        XCTAssertEqual(pickup.height, DayTimelineMetrics.standard.hourHeight / 4, accuracy: 0.01)
        XCTAssertTrue(chrome(for: pickup).showsDelete)
    }

    func testHourLongBlockStacksTitleOverTime() throws {
        let placed = shippingBlocks([span("boba", 10, 15, 11, 15)])
        let chrome = chrome(for: try layout("boba", in: placed))
        XCTAssertFalse(chrome.isCompact)
        XCTAssertTrue(chrome.showsTime)
        XCTAssertTrue(chrome.showsLocation)
        XCTAssertTrue(chrome.showsDelete)
    }

    func testFiveMinuteSliverKeepsDeleteInTheContextMenu() throws {
        let placed = shippingBlocks([span("ping", 9, 0, 9, 5)])
        let ping = try layout("ping", in: placed)
        XCTAssertLessThan(ping.height, TimelineBlockChrome.deleteMinimumHeight)
        XCTAssertFalse(chrome(for: ping).showsDelete, "a glyph this small would be illegible")
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

    // MARK: - Compact label fits the true height

    func testCompactFontAlwaysFitsOrBottomsOutAtTheSmallestSize() {
        for height in stride(from: CGFloat(4), to: TimelineBlockChrome.timeMinimumHeight, by: 0.5) {
            let chrome = TimelineBlockChrome.forBlock(height: height, width: phoneLaneWidth)
            XCTAssertTrue(chrome.isCompact)
            XCTAssertGreaterThanOrEqual(chrome.compactFontSize, 7)
            XCTAssertLessThanOrEqual(chrome.compactFontSize, 11)
            let line = chrome.compactFontSize * 1.2 + TimelineBlockChrome.compactVerticalPadding * 2
            if chrome.compactFontSize > 7 {
                XCTAssertLessThanOrEqual(line, height + 0.01, "compact text at \(height)pt must fit, not grow the block")
            }
        }
    }

    func testRegularBlockStackedLinesFitTheirThresholds() {
        // 4pt padding top and bottom, 12pt title line, 10pt detail lines, 1pt spacing.
        let title = UIFont.systemFont(ofSize: 12, weight: .semibold).lineHeight
        let detail = UIFont.systemFont(ofSize: 10).lineHeight
        XCTAssertLessThanOrEqual(8 + title + 1 + detail, TimelineBlockChrome.timeMinimumHeight)
        XCTAssertLessThanOrEqual(8 + title + 1 + detail + 1 + detail, TimelineBlockChrome.locationMinimumHeight)
        XCTAssertLessThanOrEqual(8 + title * 2 + 1 + detail + 1 + detail, TimelineBlockChrome.twoLineTitleMinimumHeight)
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

    // MARK: - Jumping to another day from the date header

    func testDayJumpAcrossMonthsCountsWholeDays() {
        let august = cal.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 17))!
        XCTAssertEqual(CalendarDayJump.dayDelta(from: time(9), to: august, calendar: cal), 54)
        XCTAssertEqual(CalendarDayJump.dayDelta(from: august, to: time(23, 59), calendar: cal), -54)
    }

    func testDayJumpToTheSameDayIgnoresTimeOfDay() {
        XCTAssertEqual(CalendarDayJump.dayDelta(from: time(0), to: time(23, 59), calendar: cal), 0)
    }

    func testDayJumpAcrossADaylightSavingSeamIsStillOneDay() {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let before = pacific.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12))!
        let after = pacific.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        XCTAssertEqual(CalendarDayJump.dayDelta(from: before, to: after, calendar: pacific), 1)
    }

    func testTodayButtonKnowsWhenItIsAlreadyToday() {
        XCTAssertTrue(CalendarDayJump.isToday(time(8), now: time(20), calendar: cal))
        XCTAssertFalse(CalendarDayJump.isToday(time(8), now: time(8).addingTimeInterval(86_400), calendar: cal))
    }

    func testChooseADayIsTranslated() {
        XCTAssertEqual(ScedraString("Choose a day", locale: Locale(identifier: "en")), "Choose a day")
        XCTAssertEqual(ScedraString("Choose a day", locale: Locale(identifier: "fr")), "Choisir un jour")
        XCTAssertEqual(ScedraString("Choose a day", locale: Locale(identifier: "es")), "Elige un día")
        XCTAssertEqual(ScedraString("Choose a day", locale: Locale(identifier: "de")), "Tag wählen")
    }

    func testJumpToTodayAndTodayAreTranslated() {
        XCTAssertEqual(ScedraString("Jump to today", locale: Locale(identifier: "en")), "Jump to today")
        XCTAssertEqual(ScedraString("Jump to today", locale: Locale(identifier: "fr")), "Aller à aujourd’hui")
        XCTAssertEqual(ScedraString("Jump to today", locale: Locale(identifier: "es")), "Ir a hoy")
        XCTAssertEqual(ScedraString("Jump to today", locale: Locale(identifier: "de")), "Zu heute springen")
        XCTAssertEqual(ScedraString("Today", locale: Locale(identifier: "fr")), "Aujourd’hui")
        XCTAssertEqual(ScedraString("Today", locale: Locale(identifier: "es")), "Hoy")
        XCTAssertEqual(ScedraString("Today", locale: Locale(identifier: "de")), "Heute")
    }

    func testChooseAMonthIsTranslated() {
        XCTAssertEqual(ScedraString("Choose a month", locale: Locale(identifier: "en")), "Choose a month")
        XCTAssertEqual(ScedraString("Choose a month", locale: Locale(identifier: "fr")), "Choisir un mois")
        XCTAssertEqual(ScedraString("Choose a month", locale: Locale(identifier: "es")), "Elige un mes")
        XCTAssertEqual(ScedraString("Choose a month", locale: Locale(identifier: "de")), "Monat wählen")
    }

    func testMonthJumpKeepsTheDayOfMonth() {
        let august = cal.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        let jumped = CalendarDayJump.preservingDay(from: dayStart, monthYearOf: august, calendar: cal)
        XCTAssertEqual(cal.component(.year, from: jumped), 2026)
        XCTAssertEqual(cal.component(.month, from: jumped), 8)
        XCTAssertEqual(cal.component(.day, from: jumped), 10)
    }

    func testMonthJumpClampsJanuary31IntoFebruary() {
        let january31 = cal.date(from: DateComponents(year: 2026, month: 1, day: 31))!
        let february = cal.date(from: DateComponents(year: 2026, month: 2, day: 1))!
        let jumped = CalendarDayJump.preservingDay(from: january31, monthYearOf: february, calendar: cal)
        XCTAssertEqual(cal.component(.month, from: jumped), 2)
        XCTAssertEqual(cal.component(.day, from: jumped), 28)
    }

    func testGridTapIsADayPickAndMonthBrowseIsNot() {
        let june20 = cal.date(byAdding: .day, value: 10, to: dayStart)!
        XCTAssertTrue(CalendarDayJump.isDayPick(from: dayStart, to: june20, calendar: cal))
        let july10 = cal.date(byAdding: .month, value: 1, to: dayStart)!
        XCTAssertFalse(CalendarDayJump.isDayPick(from: dayStart, to: july10, calendar: cal))
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

    func testOverlappingEventsWithoutPlacesStillShowTheseOverlapOnCalendar() throws {
        let chemistry = calendarItem("a", "Chemistry", start: time(14), end: time(16))
        let dentist = calendarItem("b", "Dentist", start: time(15), end: time(17))
        XCTAssertTrue(CalendarDayHomeGap.shouldShowNotices(for: [chemistry, dentist]))
        let stops = CalendarDayHomeGap.stops(from: [chemistry, dentist])
        XCTAssertEqual(stops.count, 2)
        let overlap = try XCTUnwrap(HomeGapLogic.overlapSuggestion(first: stops[0], second: stops[1]))
        XCTAssertEqual(overlap.collapsedHeadline, String(localized: "These overlap"))
        XCTAssertEqual(overlap.collapsedSubtitle, "Chemistry / Dentist")
        XCTAssertNotEqual(overlap.kind, .goHome)
    }

    func testNoticeHintStaysHiddenWhileCardsIntersectTheViewport() {
        let cards = CGRect(x: 0, y: 0, width: 320, height: 80)
        let visible = CGRect(x: 0, y: 0, width: 320, height: 500)
        XCTAssertEqual(CalendarNoticeHint.of(noticeFrameInContent: cards, visibleRect: visible), .hidden)
    }

    func testNoticeHintSaysScrollUpWhenCardsHaveLeftTheTop() {
        let cards = CGRect(x: 0, y: 0, width: 320, height: 80)
        let visible = CGRect(x: 0, y: 200, width: 320, height: 500)
        XCTAssertEqual(CalendarNoticeHint.of(noticeFrameInContent: cards, visibleRect: visible), .scrollUp)
        XCTAssertEqual(
            CalendarNoticeHint.scrollUp.message,
            ScedraString("Scroll up to see problems")
        )
    }

    func testNoticeHintSaysScrollDownWhenCardsSitBelowTheViewport() {
        let cards = CGRect(x: 0, y: 600, width: 320, height: 80)
        let visible = CGRect(x: 0, y: 0, width: 320, height: 500)
        XCTAssertEqual(CalendarNoticeHint.of(noticeFrameInContent: cards, visibleRect: visible), .scrollDown)
        XCTAssertEqual(
            CalendarNoticeHint.scrollDown.message,
            ScedraString("Scroll down to see problems")
        )
    }

    func testNoticeHintHiddenWhenTheCardStackHasNoHeight() {
        let empty = CGRect(x: 0, y: -40, width: 320, height: 0)
        let visible = CGRect(x: 0, y: 0, width: 320, height: 500)
        XCTAssertEqual(CalendarNoticeHint.of(noticeFrameInContent: empty, visibleRect: visible), .hidden)
    }

    func testNoticeHintCopyIsTranslated() {
        XCTAssertEqual(
            ScedraString("Scroll up to see problems", locale: Locale(identifier: "de")),
            "Nach oben zu den Problemen"
        )
        XCTAssertEqual(
            ScedraString("Scroll down to see problems", locale: Locale(identifier: "fr")),
            "Descendre vers les problèmes"
        )
        XCTAssertEqual(
            ScedraString("Scroll up to see problems", locale: Locale(identifier: "es")),
            "Sube para ver los problemas"
        )
        XCTAssertEqual(
            ScedraString("Scroll down to see problems", locale: Locale(identifier: "en")),
            "Scroll down to see problems"
        )
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
