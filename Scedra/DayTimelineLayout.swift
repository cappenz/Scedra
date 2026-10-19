import CoreGraphics
import Foundation

/// Geometry for the hour grid. Kept apart from the view so every number the
/// timeline draws can be checked in a unit test without rendering anything.
struct DayTimelineMetrics: Equatable {
    /// Height of one hour row.
    var hourHeight: CGFloat
    /// Visibility floor for zero- or one-minute pings only. Anything longer than
    /// this is drawn at its true length, so a block's bottom is its end time.
    var minimumBlockHeight: CGFloat
    /// Gap between blocks sitting side by side in an overlapping cluster.
    var columnSpacing: CGFloat

    init(hourHeight: CGFloat = 58, minimumBlockHeight: CGFloat = 2, columnSpacing: CGFloat = 4) {
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

    /// Drawn height of a duration: the same points-per-minute as the hour rules.
    /// Short events shrink their label to fit; they never grow past their end.
    func height(forSeconds seconds: TimeInterval) -> CGFloat {
        max(length(forSeconds: max(seconds, 0)), minimumBlockHeight)
    }
}

/// A start/end pair to place on the grid. Deliberately free of EventKit so the
/// layout can be exercised with plain dates.
struct TimelineSpan: Identifiable, Equatable {
    let id: String
    let start: Date
    let end: Date
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
    /// One line — title then time — in a smaller font, for blocks too short to
    /// stack title over time. The block keeps its true height; the text shrinks.
    let isCompact: Bool
    /// The start–end text: its own line, or inline after the title when compact.
    let showsTime: Bool
    let showsLocation: Bool
    /// The tappable trash glyph. Delete must never be long-press-only when it fits.
    let showsDelete: Bool
    /// Point size for the compact single line, fitted to the block's height.
    let compactFontSize: CGFloat
    /// Trash glyph point size; compact blocks get a smaller, background-free glyph.
    let deleteGlyphSize: CGFloat

    /// Title (12pt) over the start–end line (10pt), plus 4pt top and bottom padding.
    static let timeMinimumHeight: CGFloat = 36
    /// Title, time, and one location line.
    static let locationMinimumHeight: CGFloat = 50
    /// Room for the title to wrap to two lines above time and location.
    static let twoLineTitleMinimumHeight: CGFloat = 64
    /// Shortest block (about 11 minutes) whose trash glyph is still legible.
    /// Anything shorter keeps delete in the long-press menu.
    static let deleteMinimumHeight: CGFloat = 11
    /// Below this a block is a sliver in a crowded cluster; the glyph would cover
    /// the title, so the context menu carries delete on its own.
    static let deleteMinimumWidth: CGFloat = 74
    static let detailMinimumWidth: CGFloat = 110
    /// Trailing room the trash takes in a regular block / a compact block.
    static let deleteReserve: CGFloat = 28
    static let compactDeleteReserve: CGFloat = 22
    static let compactVerticalPadding: CGFloat = 1.5
    /// Below this (about 8 minutes) even 7pt text would be sliced by the clip,
    /// so the block is just its outline and accent bar; tap still opens details.
    static let compactTextMinimumHeight: CGFloat = 8

    static func forBlock(height: CGFloat, width: CGFloat) -> TimelineBlockChrome {
        let compact = height < timeMinimumHeight
        let wide = width >= detailMinimumWidth
        return TimelineBlockChrome(
            isCompact: compact,
            showsTime: wide,
            showsLocation: !compact && wide && height >= locationMinimumHeight,
            showsDelete: height >= deleteMinimumHeight && width >= deleteMinimumWidth,
            compactFontSize: compactFontSize(height: height),
            deleteGlyphSize: compact ? min(max(height - 4, 7), 11) : 11
        )
    }

    /// Largest font (7–11pt) whose single line fits inside `height`.
    static func compactFontSize(height: CGFloat) -> CGFloat {
        let available = height - compactVerticalPadding * 2
        return min(max((available / 1.2).rounded(.down), 7), 11)
    }

    static func titleLineLimit(height: CGFloat) -> Int {
        height >= twoLineTitleMinimumHeight ? 2 : 1
    }

    /// Title / time / location column inside a card of `cardWidth`.
    /// Leading pad 6 + accent bar 3 + gap 6 + trailing pad (trash reserve, else 6).
    static func textWidth(cardWidth: CGFloat, reservesDeleteSpace: Bool, compact: Bool = false) -> CGFloat {
        let trailing: CGFloat = reservesDeleteSpace ? (compact ? compactDeleteReserve : deleteReserve) : 6
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
        for cluster in clusters(of: clipped) {
            let columns = assignColumns(in: cluster)
            let columnCount = max(columns.max().map { $0 + 1 } ?? 1, 1)
            for (index, piece) in cluster.enumerated() {
                let height = metrics.height(forSeconds: piece.end.timeIntervalSince(piece.start))
                // A floor-height ping at 11:59 PM would hang off the grid, so pull it back up.
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
            }
        }
        return result
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
                continuesAfter: rawEnd > dayEnd
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
