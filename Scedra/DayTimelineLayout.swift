import CoreGraphics
import Foundation

/// Geometry for the hour grid. Kept apart from the view so every number the
/// timeline draws can be checked in a unit test without rendering anything.
struct DayTimelineMetrics: Equatable {
    /// Height of one hour row.
    var hourHeight: CGFloat
    /// Shortest a block may be drawn, so a 15-minute event stays readable and tappable.
    var minimumBlockHeight: CGFloat
    /// Gap between blocks sitting side by side in an overlapping cluster.
    var columnSpacing: CGFloat

    init(hourHeight: CGFloat = 58, minimumBlockHeight: CGFloat = 30, columnSpacing: CGFloat = 4) {
        self.hourHeight = hourHeight
        self.minimumBlockHeight = minimumBlockHeight
        self.columnSpacing = columnSpacing
    }

    static let standard = DayTimelineMetrics()

    var totalHeight: CGFloat { hourHeight * 24 }

    /// Unclamped: how far down a stretch of time reaches.
    func length(forSeconds seconds: TimeInterval) -> CGFloat {
        CGFloat(seconds / 3600) * hourHeight
    }

    /// Vertical position of a moment, clamped to the day's grid.
    func offset(for date: Date, dayStart: Date) -> CGFloat {
        min(max(length(forSeconds: date.timeIntervalSince(dayStart)), 0), totalHeight)
    }

    /// Drawn height of a duration, never below `minimumBlockHeight` or the
    /// space the block's own title/time/location need. Extra height grows
    /// downward from the real start; EventKit times are not moved.
    func height(forSeconds seconds: TimeInterval, contentMinimum: CGFloat = 0) -> CGFloat {
        max(length(forSeconds: max(seconds, 0)), minimumBlockHeight, contentMinimum)
    }
}

/// A start/end pair to place on the grid. Deliberately free of EventKit so the
/// layout can be exercised with plain dates.
struct TimelineSpan: Identifiable, Equatable {
    let id: String
    let start: Date
    let end: Date
    /// Extra floor so title, time, and location fit inside the bubble when
    /// the appointment itself is shorter than that text.
    let contentMinimumHeight: CGFloat

    init(id: String, start: Date, end: Date, contentMinimumHeight: CGFloat = 0) {
        self.id = id
        self.start = start
        self.end = end
        self.contentMinimumHeight = contentMinimumHeight
    }
}

/// Where one event block lands: vertical position, height, and which slice of
/// the width it owns when it overlaps its neighbours.
struct TimelineBlockLayout: Identifiable, Equatable {
    let id: String
    let top: CGFloat
    let height: CGFloat
    /// Zero-based slot within the overlapping cluster.
    let column: Int
    /// How many slots the cluster was split into.
    let columnCount: Int
    /// The event began before this day and is clipped at the top.
    let continuesBeforeDay: Bool
    /// The event runs past this day and is clipped at the bottom.
    let continuesAfterDay: Bool

    var bottom: CGFloat { top + height }

    func withHeight(_ height: CGFloat) -> TimelineBlockLayout {
        TimelineBlockLayout(
            id: id,
            top: top,
            height: height,
            column: column,
            columnCount: columnCount,
            continuesBeforeDay: continuesBeforeDay,
            continuesAfterDay: continuesAfterDay
        )
    }

    /// True when the two blocks occupy overlapping slices of the lane, so
    /// growing one downward would paint over the other.
    func sharesHorizontalLane(with other: TimelineBlockLayout) -> Bool {
        let left = CGFloat(column) / CGFloat(max(columnCount, 1))
        let right = CGFloat(column + 1) / CGFloat(max(columnCount, 1))
        let otherLeft = CGFloat(other.column) / CGFloat(max(other.columnCount, 1))
        let otherRight = CGFloat(other.column + 1) / CGFloat(max(other.columnCount, 1))
        return left < otherRight && otherLeft < right
    }

    func xOffset(inLaneWidth laneWidth: CGFloat) -> CGFloat {
        laneWidth / CGFloat(max(columnCount, 1)) * CGFloat(column)
    }

    func width(inLaneWidth laneWidth: CGFloat, spacing: CGFloat) -> CGFloat {
        let slot = laneWidth / CGFloat(max(columnCount, 1))
        return max(slot - (columnCount > 1 ? spacing : 0), 1)
    }
}

/// Which pieces of chrome fit legibly inside a drawn block. Kept out of the view
/// so the thresholds can be checked without rendering anything.
struct TimelineBlockChrome: Equatable {
    /// The start–end line under the title.
    let showsTime: Bool
    let showsLocation: Bool
    /// The tappable trash glyph. Delete must never be long-press-only when it fits.
    let showsDelete: Bool

    /// Shortest block that can still hold a legible, tappable trash glyph. Matches
    /// `DayTimelineMetrics.minimumBlockHeight`, so every block drawn at the floor
    /// still gets one.
    static let deleteMinimumHeight: CGFloat = 30
    /// Title plus the start–end line, including the block's vertical padding.
    static let timeMinimumHeight: CGFloat = 46
    /// Title, time, and a single location line without painting past the bubble.
    static let locationMinimumHeight: CGFloat = 68
    /// Below this a block is a sliver in a crowded cluster; the glyph would cover
    /// the title, so the context menu carries delete on its own.
    static let deleteMinimumWidth: CGFloat = 74
    static let detailMinimumWidth: CGFloat = 110

    static func forBlock(height: CGFloat, width: CGFloat) -> TimelineBlockChrome {
        TimelineBlockChrome(
            showsTime: height >= timeMinimumHeight && width >= detailMinimumWidth,
            showsLocation: height >= locationMinimumHeight && width >= detailMinimumWidth,
            showsDelete: height >= deleteMinimumHeight && width >= deleteMinimumWidth
        )
    }

    /// Height the bubble should grow to so the chrome it wants can sit inside
    /// the rounded rect. Used as `TimelineSpan.contentMinimumHeight`.
    static func contentMinimumHeight(showsTime: Bool, showsLocation: Bool) -> CGFloat {
        if showsLocation { return locationMinimumHeight }
        if showsTime { return timeMinimumHeight }
        return deleteMinimumHeight
    }

    /// Title / time / location column inside a card of `cardWidth`.
    /// Leading pad 6 + accent bar 3 + gap 6 + trailing pad (28 with trash, else 6).
    static func textWidth(cardWidth: CGFloat, reservesDeleteSpace: Bool) -> CGFloat {
        let trailing: CGFloat = reservesDeleteSpace ? 28 : 6
        let used: CGFloat = 6 + 3 + 6 + trailing
        return max(cardWidth - used, 0)
    }
}

enum DayTimelineLayout {
    static let secondsPerDay: TimeInterval = 24 * 60 * 60

    /// Places every span that touches the day on the grid, splitting the width
    /// between spans that overlap each other.
    static func blocks(
        for spans: [TimelineSpan],
        dayStart: Date,
        dayEnd: Date? = nil,
        metrics: DayTimelineMetrics = .standard
    ) -> [TimelineBlockLayout] {
        let boundaryEnd = dayEnd ?? dayStart.addingTimeInterval(secondsPerDay)
        let clipped = clip(spans, dayStart: dayStart, dayEnd: boundaryEnd)
        guard !clipped.isEmpty else { return [] }

        var result: [TimelineBlockLayout] = []
        var durationFloors: [String: CGFloat] = [:]
        for cluster in clusters(of: clipped) {
            let columns = assignColumns(in: cluster)
            let columnCount = max(columns.max().map { $0 + 1 } ?? 1, 1)
            for (index, piece) in cluster.enumerated() {
                let durationHeight = metrics.height(forSeconds: piece.end.timeIntervalSince(piece.start))
                let height = metrics.height(
                    forSeconds: piece.end.timeIntervalSince(piece.start),
                    contentMinimum: piece.contentMinimumHeight
                )
                // A minimum-height block near midnight would hang off the grid, so pull it back up.
                let rawTop = metrics.offset(for: piece.start, dayStart: dayStart)
                let top = max(min(rawTop, metrics.totalHeight - height), 0)
                result.append(
                    TimelineBlockLayout(
                        id: piece.id,
                        top: top,
                        height: height,
                        column: columns[index],
                        columnCount: columnCount,
                        continuesBeforeDay: piece.continuesBefore,
                        continuesAfterDay: piece.continuesAfter
                    )
                )
                durationFloors[piece.id] = durationHeight
            }
        }
        return capContentGrowth(result, durationFloors: durationFloors)
    }

    /// Content-min extra height grows down from the real start. If that would
    /// paint over a later block in the same lane, stop at that block's top —
    /// time-overlapping neighbours already sit in different columns, so they
    /// keep the existing side-by-side layout.
    private static func capContentGrowth(
        _ blocks: [TimelineBlockLayout],
        durationFloors: [String: CGFloat]
    ) -> [TimelineBlockLayout] {
        blocks.map { block in
            let floor = durationFloors[block.id] ?? block.height
            guard block.height > floor + 0.01 else { return block }
            let nextTop = blocks
                .filter { other in
                    other.id != block.id
                        && other.top > block.top + 0.5
                        && block.sharesHorizontalLane(with: other)
                }
                .map(\.top)
                .min()
            guard let nextTop else { return block }
            let room = nextTop - block.top
            let capped = max(floor, min(block.height, room))
            return abs(capped - block.height) < 0.01 ? block : block.withHeight(capped)
        }
    }

    /// The hour to rest on when the day first appears: the current hour on
    /// today, otherwise the first event, otherwise a calm mid-morning.
    static func initialScrollHour(
        day: Date,
        now: Date = Date(),
        spans: [TimelineSpan],
        calendar: Calendar = .current,
        fallbackHour: Int = 8
    ) -> Int {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = dayStart.addingTimeInterval(secondsPerDay)
        let anchor: Date
        if now >= dayStart && now < dayEnd {
            anchor = now
        } else if let earliest = clip(spans, dayStart: dayStart, dayEnd: dayEnd).first?.start {
            anchor = earliest
        } else {
            return clampHour(fallbackHour)
        }
        // Leave an hour of context above so the anchor isn't jammed against the top edge.
        return clampHour(calendar.component(.hour, from: anchor) - 1)
    }

    private static func clampHour(_ hour: Int) -> Int {
        min(max(hour, 0), 23)
    }

    // MARK: - Clipping

    struct ClippedSpan: Identifiable, Equatable {
        let id: String
        let start: Date
        let end: Date
        let continuesBefore: Bool
        let continuesAfter: Bool
        let contentMinimumHeight: CGFloat
    }

    /// Trims spans to the day's boundaries, dropping anything that never lands
    /// on it and flagging the ones that spill past either edge.
    static func clip(_ spans: [TimelineSpan], dayStart: Date, dayEnd: Date) -> [ClippedSpan] {
        spans.compactMap { span -> ClippedSpan? in
            // A zero-length event still deserves a spot on the grid.
            let rawEnd = max(span.end, span.start.addingTimeInterval(1))
            let start = max(span.start, dayStart)
            let end = min(rawEnd, dayEnd)
            guard end > start else { return nil }
            return ClippedSpan(
                id: span.id,
                start: start,
                end: end,
                continuesBefore: span.start < dayStart,
                continuesAfter: rawEnd > dayEnd,
                contentMinimumHeight: span.contentMinimumHeight
            )
        }
        .sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            // Longest first so wide-spanning events take the leftmost column.
            if lhs.end != rhs.end { return lhs.end > rhs.end }
            return lhs.id < rhs.id
        }
    }

    // MARK: - Overlap grouping

    /// Splits sorted spans into runs of mutual or chained overlap. A chain where
    /// A overlaps B and B overlaps C counts as one cluster even if A and C don't
    /// touch, so the whole run shares one width budget.
    private static func clusters(of spans: [ClippedSpan]) -> [[ClippedSpan]] {
        var clusters: [[ClippedSpan]] = []
        var current: [ClippedSpan] = []
        var reach = Date.distantPast
        for span in spans {
            if current.isEmpty || span.start < reach {
                current.append(span)
                reach = max(reach, span.end)
            } else {
                clusters.append(current)
                current = [span]
                reach = span.end
            }
        }
        if !current.isEmpty { clusters.append(current) }
        return clusters
    }

    /// Greedy packing: reuse the leftmost column whose last event has already
    /// finished, so a chain of overlaps only needs as many columns as the
    /// deepest pile-up.
    private static func assignColumns(in cluster: [ClippedSpan]) -> [Int] {
        var columnEnds: [Date] = []
        var assignment: [Int] = []
        for span in cluster {
            if let free = columnEnds.indices.first(where: { columnEnds[$0] <= span.start }) {
                columnEnds[free] = span.end
                assignment.append(free)
            } else {
                columnEnds.append(span.end)
                assignment.append(columnEnds.count - 1)
            }
        }
        return assignment
    }
}
