import SwiftUI

/// One day, drawn as an hour grid: hour labels down the left, a rule per hour,
/// and each event as a block sized by how long it actually runs.
///
/// Read-only apart from the two actions the list rows already had — tap a block to
/// see title, place, official times, drive, and original; tap its trash to delete
/// (long-press still offers both). Nothing here ever moves an event; Apple Calendar
/// stays the source of truth.
struct DayTimelineView: View {
    let day: Date
    let items: [TodayItem]
    var metrics: DayTimelineMetrics = .standard
    /// Don’t-go-home / Conflict / These overlap / Take transit — same ScrollView as the hours.
    var noticeStops: [HomeGapStop] = []
    var onSelect: (TodayItem) -> Void
    var onDelete: (TodayItem) -> Void
    /// Signed number of days to move by, so the view can drive the existing day picker.
    var onShiftDay: (Int) -> Void

    private let gutterWidth: CGFloat = 52
    private let laneInset: CGFloat = 4
    private let cornerRadius: CGFloat = 12
    private let contentSpace = "scedraTimelineContent"

    private var cal: Calendar { .current }
    private var dayStart: Date { cal.startOfDay(for: day) }
    private var dayEnd: Date { dayStart.addingTimeInterval(DayTimelineLayout.secondsPerDay) }
    private var isToday: Bool { cal.isDateInToday(dayStart) }

    private var allDayItems: [TodayItem] { items.filter { $0.isAllDay } }
    private var timedItems: [TodayItem] { items.filter { !$0.isAllDay } }

    @State private var noticeContentFrame: CGRect = .zero
    @State private var visibleRect: CGRect = .zero
    @State private var noticeHint: CalendarNoticeHint = .hidden

    var body: some View {
        // One ScrollView: problem cards above the hours, then the 24-hour grid.
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if !noticeStops.isEmpty {
                        HomeGapSection(stops: noticeStops)
                            .onGeometryChange(for: CGRect.self) { geo in
                                geo.frame(in: .named(contentSpace))
                            } action: { _, frame in
                                noticeContentFrame = frame
                                refreshNoticeHint()
                            }
                            .padding(.bottom, noticeContentFrame.height > 1 ? 16 : 0)
                            .id(CalendarNoticeChrome.noticeAnchor)
                    }
                    timelineCard
                }
                .coordinateSpace(.named(contentSpace))
            }
            .onScrollGeometryChange(for: CGRect.self) { geo in
                geo.visibleRect
            } action: { _, rect in
                visibleRect = rect
                refreshNoticeHint()
            }
            .overlay(alignment: noticeHint == .scrollDown ? .bottom : .top) {
                noticeHintChip(proxy)
                    .animation(.easeInOut(duration: 0.2), value: noticeHint)
            }
            .overlay(alignment: .bottom) { todayButton }
            .overlay(alignment: .center) { emptyDayNote }
            .onAppear { restInterestingPlace(proxy) }
            .onChange(of: dayStart) { _, _ in restInterestingPlace(proxy) }
            .onChange(of: noticeStops.isEmpty) { _, empty in
                if empty {
                    noticeContentFrame = .zero
                    noticeHint = .hidden
                }
                restInterestingPlace(proxy)
            }
        }
        .simultaneousGesture(daySwipe)
    }

    private var timelineCard: some View {
        VStack(spacing: 0) {
            if !allDayItems.isEmpty {
                allDayStrip
            }
            hourLane
        }
        .background(ScedraTheme.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: ScedraTheme.purple.opacity(0.12), radius: 18, y: 8)
    }

    @ViewBuilder
    private func noticeHintChip(_ proxy: ScrollViewProxy) -> some View {
        if noticeHint != .hidden {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(CalendarNoticeChrome.noticeAnchor, anchor: .top)
                }
            } label: {
                Text(noticeHint.message)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ScedraTheme.deepPurple)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        ScedraTheme.card.opacity(0.94),
                        in: Capsule()
                    )
                    .overlay(Capsule().stroke(ScedraTheme.lavender.opacity(0.8), lineWidth: 1))
                    .shadow(color: ScedraTheme.purple.opacity(0.12), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.top, noticeHint == .scrollUp ? 8 : 0)
            .padding(.bottom, noticeHint == .scrollDown ? (isToday ? 14 : 54) : 0)
            .accessibilityLabel(noticeHint.message)
        }
    }

    private func refreshNoticeHint() {
        guard !noticeStops.isEmpty else {
            noticeHint = .hidden
            return
        }
        noticeHint = CalendarNoticeHint.of(
            noticeFrameInContent: noticeContentFrame,
            visibleRect: visibleRect
        )
    }

    // MARK: - Grid

    private var hourLane: some View {
        GeometryReader { geometry in
            let laneWidth = max(geometry.size.width - gutterWidth - laneInset, 60)
            ZStack(alignment: .topLeading) {
                hourGrid
                ForEach(placedEvents) { placed in
                    eventBlock(placed, laneWidth: laneWidth)
                }
                if isToday {
                    nowIndicator
                }
            }
            .frame(width: geometry.size.width, height: metrics.totalHeight, alignment: .topLeading)
        }
        .frame(height: metrics.totalHeight)
        .padding(.horizontal, 10)
        // Room for the 12 AM label, which is centred on the very first rule.
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    /// Each row's top edge is its hour rule, at exactly `hour * hourHeight` —
    /// the same scale the blocks use. The label is an overlay so its text height
    /// can't push the rule down off the hour.
    private var hourGrid: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(ScedraTheme.lavender.opacity(0.55))
                        .frame(height: 1)
                    Rectangle()
                        .fill(ScedraTheme.lavender.opacity(0.3))
                        .frame(height: 1)
                        .offset(y: metrics.hourHeight / 2)
                }
                .padding(.leading, gutterWidth)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: metrics.hourHeight, alignment: .top)
                .overlay(alignment: .topLeading) {
                    Text(hourLabel(hour))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ScedraTheme.purple.opacity(0.55))
                        .fixedSize()
                        .frame(width: gutterWidth - 8, height: 1, alignment: .trailing)
                }
                .id(hourAnchor(hour))
            }
        }
        .accessibilityHidden(true)
    }

    private var nowIndicator: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 0) {
                Circle()
                    .fill(ScedraTheme.conflict)
                    .frame(width: 7, height: 7)
                Rectangle()
                    .fill(ScedraTheme.conflict.opacity(0.75))
                    .frame(height: 1.5)
            }
            .padding(.leading, gutterWidth - 3)
            .offset(y: metrics.offset(for: context.date, dayStart: dayStart) - 3.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityLabel("Current time")
        }
    }

    // MARK: - Event blocks

    /// An event paired with the slot the layout gave it. Identified by position
    /// rather than event id, since repeating events can share an identifier.
    private struct PlacedEvent: Identifiable {
        let id: String
        let item: TodayItem
        let layout: TimelineBlockLayout
    }

    private var placedEvents: [PlacedEvent] {
        let timed = timedItems
        let spans = timed.enumerated().map {
            TimelineSpan(id: String($0.offset), start: $0.element.start, end: $0.element.end)
        }
        return DayTimelineLayout.blocks(for: spans, dayStart: dayStart, dayEnd: dayEnd, metrics: metrics)
            .compactMap { block in
                guard let index = Int(block.id), timed.indices.contains(index) else { return nil }
                return PlacedEvent(id: block.id, item: timed[index], layout: block)
            }
    }

    private func eventBlock(_ placed: PlacedEvent, laneWidth: CGFloat) -> some View {
        let layout = placed.layout
        let item = placed.item
        let width = layout.width(inLaneWidth: laneWidth, spacing: metrics.columnSpacing)
        let original = item.hasOriginal
        let chrome = TimelineBlockChrome.forBlock(height: layout.height, width: width)
        let leading = gutterWidth + laneInset + layout.xOffset(inLaneWidth: laneWidth)
        let radius = min(cornerRadius, layout.height / 2)

        let bubble = RoundedRectangle(cornerRadius: radius, style: .continuous)

        return Button {
            onSelect(item)
        } label: {
            // Clip the filled card here — on the Button label. A clipShape
            // on a wrapper ZStack never reaches Button drawing, and a clip only
            // inside TimelineBlockBody still let title/time/address paint
            // past the rounded fill (the Rideing / Schoool screenshot).
            TimelineBlockLabel(
                item: item,
                layout: layout,
                hasOriginal: original,
                showsDetail: chrome.showsTime,
                showsLocation: chrome.showsLocation,
                reservesDeleteSpace: chrome.showsDelete,
                cornerRadius: radius,
                width: width,
                height: layout.height,
                isCompact: chrome.isCompact,
                compactFontSize: chrome.compactFontSize
            )
        }
        .buttonStyle(TimelineBlockButtonStyle(cornerRadius: radius))
        .frame(width: width, height: layout.height, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            // Overlay so the glyph cannot grow the block past its end time.
            if chrome.showsDelete {
                deleteGlyph(item, chrome: chrome, blockHeight: layout.height)
            }
        }
        .clipped()
        .contentShape(bubble)
        .contextMenu {
            Button {
                onSelect(item)
            } label: {
                Label("View details", systemImage: "doc.text")
            }
            Button(role: .destructive) {
                onDelete(item)
            } label: {
                Label("Delete from Calendar", systemImage: "trash")
            }
        }
        // Padding, not offset: offset moved the drawing without moving the tap
        // target, so trash sat on a later hour while hits still landed at midnight.
        .padding(.leading, leading)
        .padding(.top, layout.top)
        .accessibilityElement(children: .combine)
        .accessibilityHint(blockHint(showsDelete: chrome.showsDelete))
        .accessibilityAction(named: "Delete from Calendar") { onDelete(item) }
    }

    private func blockHint(showsDelete: Bool) -> String {
        let delete = showsDelete ? "Tap the trash to delete." : "Touch and hold to delete."
        return "Tap to view appointment details. \(delete)"
    }

    /// The always-visible way out of an appointment. Routes to the same
    /// confirmation and the same EventKit delete the list rows use.
    ///
    /// Compact blocks get a smaller glyph centred in a full-height trailing strip,
    /// so it stays tappable without making the block taller than its event.
    @ViewBuilder
    private func deleteGlyph(_ item: TodayItem, chrome: TimelineBlockChrome, blockHeight: CGFloat) -> some View {
        if chrome.isCompact {
            Button {
                onDelete(item)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: chrome.deleteGlyphSize, weight: .semibold))
                    .foregroundStyle(ScedraTheme.conflict)
                    .frame(width: TimelineBlockChrome.compactDeleteReserve, height: blockHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(item.title)")
        } else {
            Button {
                onDelete(item)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: chrome.deleteGlyphSize, weight: .semibold))
                    .foregroundStyle(ScedraTheme.conflict)
                    .padding(8)
                    .background(ScedraTheme.card.opacity(0.94), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(2)
            .accessibilityLabel("Delete \(item.title)")
        }
    }

    // MARK: - All-day strip

    private var allDayStrip: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                Text("All day")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ScedraTheme.purple.opacity(0.6))
                    .frame(width: gutterWidth - 8, alignment: .trailing)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(allDayItems.enumerated()), id: \.offset) { _, item in
                            allDayChip(item)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
            .padding(.vertical, 10)
            .padding(.leading, 10)
            Rectangle()
                .fill(ScedraTheme.lavender.opacity(0.55))
                .frame(height: 1)
        }
    }

    private func allDayChip(_ item: TodayItem) -> some View {
        let original = item.hasOriginal
        return HStack(spacing: 6) {
            HStack(spacing: 4) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ScedraTheme.deepPurple)
                    .lineLimit(1)
                if original {
                    Image(systemName: item.originalIndicatorSymbol)
                        .font(.system(size: 9))
                        .foregroundStyle(ScedraTheme.purple.opacity(0.7))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect(item)
            }

            // The strip has room, so all-day events get the same visible trash
            // the timed blocks and the list rows have.
            Button(role: .destructive) {
                onDelete(item)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ScedraTheme.conflict)
                    .padding(2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(item.title)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(ScedraTheme.mist, in: Capsule())
        .overlay(Capsule().stroke(ScedraTheme.lavender.opacity(0.8), lineWidth: 1))
        .contextMenu {
            Button {
                onSelect(item)
            } label: {
                Label("View details", systemImage: "doc.text")
            }
            Button(role: .destructive) {
                onDelete(item)
            } label: {
                Label("Delete from Calendar", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), all day")
        .accessibilityAction(named: "Delete from Calendar") { onDelete(item) }
    }

    // MARK: - Chrome

    @ViewBuilder
    private var emptyDayNote: some View {
        if items.isEmpty {
            VStack(spacing: 3) {
                Text("Nothing this day.")
                    .font(.subheadline)
                    .foregroundStyle(ScedraTheme.deepPurple)
                Text("Swipe for another day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(
                ScedraTheme.card.opacity(0.94),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .shadow(color: ScedraTheme.purple.opacity(0.1), radius: 10, y: 4)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var todayButton: some View {
        if !isToday {
            Button {
                onShiftDay(daysFromToday)
            } label: {
                Text("Today")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(ScedraTheme.purple, in: Capsule())
                    .shadow(color: ScedraTheme.purple.opacity(0.35), radius: 8, y: 3)
            }
            .padding(.bottom, 14)
            .accessibilityLabel("Jump to today")
        }
    }

    private var daySwipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                // Only a clearly sideways flick turns the day; everything else is scrolling.
                guard abs(horizontal) > 60, abs(horizontal) > abs(vertical) * 1.5 else { return }
                onShiftDay(horizontal < 0 ? 1 : -1)
            }
    }

    // MARK: - Helpers

    private var daysFromToday: Int {
        let today = cal.startOfDay(for: Date())
        return cal.dateComponents([.day], from: dayStart, to: today).day ?? 0
    }

    private func hourAnchor(_ hour: Int) -> String { "scedra-hour-\(hour)" }

    /// 12h or 24h, whichever the phone is set to.
    private func hourLabel(_ hour: Int) -> String {
        guard let date = cal.date(byAdding: .hour, value: hour, to: dayStart) else { return "" }
        return date.scedraHourLabel()
    }

    private func restInterestingPlace(_ proxy: ScrollViewProxy) {
        #if DEBUG
        // `-scedra-timeline-scroll-hour 14` pins the opening hour for simulator screenshots.
        if let debugHour = UserDefaults.standard.string(forKey: "scedra-timeline-scroll-hour").flatMap(Int.init) {
            DispatchQueue.main.async {
                proxy.scrollTo(hourAnchor(min(max(debugHour, 0), 23)), anchor: .top)
            }
            return
        }
        #endif
        // Cards sit above the hours so they aren't buried after 11pm. Skip the
        // usual jump-to-event when this day has problem cards to show.
        if !noticeStops.isEmpty {
            DispatchQueue.main.async {
                proxy.scrollTo(CalendarNoticeChrome.noticeAnchor, anchor: .top)
            }
            return
        }
        let spans = timedItems.enumerated().map {
            TimelineSpan(id: String($0.offset), start: $0.element.start, end: $0.element.end)
        }
        let hour = DayTimelineLayout.initialScrollHour(day: dayStart, spans: spans, calendar: cal)
        // After layout, otherwise the proxy has nothing to scroll to yet.
        DispatchQueue.main.async {
            proxy.scrollTo(hourAnchor(hour), anchor: .top)
        }
    }
}

/// The live calendar card: theme fill clipped to the column slot.
///
/// This is the Button label. SwiftUI Button drawing ignores a clipShape on the
/// ZStack around the Button, so the filled rounded rect and its clip live here.
struct TimelineBlockLabel: View {
    let item: TodayItem
    let layout: TimelineBlockLayout
    let hasOriginal: Bool
    let showsDetail: Bool
    let showsLocation: Bool
    let reservesDeleteSpace: Bool
    let cornerRadius: CGFloat
    let width: CGFloat
    let height: CGFloat
    var isCompact: Bool = false
    var compactFontSize: CGFloat = 11

    private var bubble: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        TimelineBlockBody(
            item: item,
            layout: layout,
            hasOriginal: hasOriginal,
            showsDetail: showsDetail,
            showsLocation: showsLocation,
            reservesDeleteSpace: reservesDeleteSpace,
            width: width,
            height: height,
            isCompact: isCompact,
            compactFontSize: compactFontSize
        )
        .frame(minWidth: 0, maxWidth: width, minHeight: 0, maxHeight: height)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(ScedraTheme.card)
        .overlay(bubble.stroke(ScedraTheme.lavender, lineWidth: 1))
        .compositingGroup()
        .clipShape(bubble)
        .contentShape(bubble)
    }
}

/// Clips the Button label as Button actually draws it. `.plain` leaves the
/// label unclipped, which is how the address walked off the rounded fill.
private struct TimelineBlockButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        let bubble = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        configuration.label
            .compositingGroup()
            .clipShape(bubble)
            .contentShape(bubble)
            .opacity(configuration.isPressed ? 0.92 : 1)
    }
}

/// Title / time / location inside one event block. Trims what it shows as the
/// block gets smaller so a 15-minute event still reads as a real appointment.
///
/// Width is the column slot, never the untruncated address. A no-space zip
/// like `Springfield,IL627001` still has to stay inside the label's rounded rect.
struct TimelineBlockBody: View {
    let item: TodayItem
    let layout: TimelineBlockLayout
    let hasOriginal: Bool
    let showsDetail: Bool
    let showsLocation: Bool
    /// Keeps the title from sliding under the trash glyph drawn over the corner.
    let reservesDeleteSpace: Bool
    let width: CGFloat
    let height: CGFloat
    /// Single line, smaller font: the block is too short to stack title over time.
    var isCompact: Bool = false
    var compactFontSize: CGFloat = 11

    /// Title / time / location column: card width minus the accent bar and padding.
    private var textWidth: CGFloat {
        TimelineBlockChrome.textWidth(
            cardWidth: width,
            reservesDeleteSpace: reservesDeleteSpace,
            compact: isCompact
        )
    }

    private var trailingPadding: CGFloat {
        guard reservesDeleteSpace else { return 6 }
        return isCompact ? TimelineBlockChrome.compactDeleteReserve : TimelineBlockChrome.deleteReserve
    }

    var body: some View {
        Group {
            if isCompact {
                compactContent
                    .padding(.vertical, TimelineBlockChrome.compactVerticalPadding)
            } else {
                cardContent
                    .padding(.vertical, 4)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, trailingPadding)
        .frame(minWidth: 0, maxWidth: width, minHeight: 0, maxHeight: height)
        .frame(width: width, height: height, alignment: isCompact ? .leading : .topLeading)
        .clipped()
        .overlay(alignment: .top) { continuationMark("chevron.up", shown: layout.continuesBeforeDay && !isCompact) }
        .overlay(alignment: .bottom) { continuationMark("chevron.down", shown: layout.continuesAfterDay && !isCompact) }
    }

    /// Title then time on one line, clipped by the label's rounded rect.
    private var compactContent: some View {
        HStack(alignment: .center, spacing: 6) {
            Capsule()
                .fill(ScedraTheme.purple.opacity(0.85))
                .frame(width: 3)
                .frame(maxHeight: .infinity)
            if height >= TimelineBlockChrome.compactTextMinimumHeight {
                // Full range, then start time, then a truncated title — whichever fits the column.
                ViewThatFits(in: .horizontal) {
                    if showsDetail {
                        compactLine(time: timeLabel)
                        compactLine(time: item.start.scedraDisplay(date: .omitted, time: .shortened))
                    }
                    compactTitle
                }
                .frame(minWidth: 0, maxWidth: textWidth, alignment: .leading)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var compactTitle: some View {
        Text(item.title)
            .font(.system(size: compactFontSize, weight: .semibold))
            .foregroundStyle(ScedraTheme.deepPurple)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func compactLine(time: String) -> some View {
        HStack(spacing: 4) {
            compactTitle
                .fixedSize()
            Text(time)
                .font(.system(size: compactFontSize))
                .foregroundStyle(ScedraTheme.purple.opacity(0.85))
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var cardContent: some View {
        HStack(alignment: .top, spacing: 6) {
            Capsule()
                .fill(ScedraTheme.purple.opacity(0.85))
                .frame(width: 3)
            lines
                .frame(minWidth: 0, maxWidth: textWidth, alignment: .leading)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 1) {
            titleLine
            if showsDetail {
                cappedLine(timeLabel, color: ScedraTheme.purple.opacity(0.85))
            }
            if showsLocation, let location = item.location, !location.isEmpty {
                cappedLine(location, color: .secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(minWidth: 0, maxWidth: textWidth, alignment: .leading)
    }

    private var titleLine: some View {
        HStack(spacing: 4) {
            Text(item.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ScedraTheme.deepPurple)
                .lineLimit(showsDetail ? TimelineBlockChrome.titleLineLimit(height: height) : 1)
                .truncationMode(.tail)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            if hasOriginal {
                Image(systemName: item.originalIndicatorSymbol)
                    .font(.system(size: 8))
                    .foregroundStyle(ScedraTheme.purple.opacity(0.7))
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private func cappedLine(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    /// Marks an event that started yesterday or runs into tomorrow.
    @ViewBuilder
    private func continuationMark(_ symbol: String, shown: Bool) -> some View {
        if shown {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(ScedraTheme.purple.opacity(0.75), in: Capsule())
        }
    }

    private var timeLabel: String {
        if item.isAllDay { return ScedraString("All day") }
        let start = item.start.scedraDisplay(date: .omitted, time: .shortened)
        let end = item.end.scedraDisplay(date: .omitted, time: .shortened)
        return "\(start)–\(end)"
    }
}
