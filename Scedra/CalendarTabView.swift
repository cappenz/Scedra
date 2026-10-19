import SwiftUI
import UIKit

/// What the Calendar tab shows for the selected day. Split out of the view so the
/// empty-day decision is checkable in a test.
///
/// An empty day still gets the timeline: she asked for the hour grid, and the grid
/// carries its own "nothing on the calendar" note plus the swipe to another day, so
/// a bare placeholder would only take the calendar away when she needs it least.
enum CalendarDayPresentation: Equatable {
    case checkingAccess
    case accessDenied
    /// Write-only access can save but cannot read events back, so an empty day is
    /// indistinguishable from a day we simply aren't allowed to see. Say so instead
    /// of drawing a grid that will always look empty.
    case writeOnlyWithoutEvents
    case timeline

    static func of(access: CalendarAccess, hasEvents: Bool) -> CalendarDayPresentation {
        switch access {
        case .unknown:
            return .checkingAccess
        case .denied:
            return .accessDenied
        case .writeOnly:
            return hasEvents ? .timeline : .writeOnlyWithoutEvents
        case .full:
            return .timeline
        }
    }
}

/// Don’t-go-home / Conflict / These overlap / Take transit for the selected day.
/// Calendar draws these at the top of the same hour-grid ScrollView.
enum CalendarDayHomeGap {
    static func stops(from items: [TodayItem]) -> [HomeGapStop] {
        items.filter { !$0.isAllDay }.map { $0.asHomeGapStop() }
    }

    static func shouldShowNotices(for items: [TodayItem]) -> Bool {
        !HomeGapLogic.consecutivePairs(from: stops(from: items)).isEmpty
    }
}

/// Shared spacing / scroll target for calendar problem cards.
enum CalendarNoticeChrome {
    static let cardSpacing: CGFloat = 12
    static let noticeAnchor = "scedra-day-notices"
}

/// Sticky label when the problem cards have left the hour-grid viewport.
enum CalendarNoticeHint: Equatable {
    case hidden
    case scrollUp
    case scrollDown

    /// A sliver of card still on screen is enough — no separate peek strip.
    static let minVisibleHeight: CGFloat = 12

    var message: String {
        switch self {
        case .hidden:
            ""
        case .scrollUp:
            ScedraString("Scroll up to see problems")
        case .scrollDown:
            ScedraString("Scroll down to see problems")
        }
    }

    /// `noticeFrameInContent` and `visibleRect` share the scroll content space.
    static func of(noticeFrameInContent: CGRect, visibleRect: CGRect) -> CalendarNoticeHint {
        guard noticeFrameInContent.height > 1, visibleRect.height > 1 else {
            return .hidden
        }
        let overlap = noticeFrameInContent.intersection(visibleRect).height
        if overlap >= minVisibleHeight {
            return .hidden
        }
        if noticeFrameInContent.maxY <= visibleRect.minY + minVisibleHeight {
            return .scrollUp
        }
        if noticeFrameInContent.minY >= visibleRect.maxY - minVisibleHeight {
            return .scrollDown
        }
        return noticeFrameInContent.midY < visibleRect.midY ? .scrollUp : .scrollDown
    }
}

/// Jumping from the selected day to any other day. Kept as a day count so the jump
/// goes through `shiftSelectedDay(by:)` — the same reload the chevrons use.
enum CalendarDayJump {
    static func dayDelta(from selected: Date, to picked: Date, calendar: Calendar = .current) -> Int {
        let from = calendar.startOfDay(for: selected)
        let to = calendar.startOfDay(for: picked)
        return calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    static func isToday(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        calendar.isDate(day, inSameDayAs: now)
    }

    /// Month/year wheels report the 1st of that month. Keep the day-of-month she
    /// was already on, clamped for short months (31 Jan → 28 Feb).
    static func preservingDay(
        from selected: Date,
        monthYearOf picked: Date,
        calendar: Calendar = .current
    ) -> Date {
        let year = calendar.component(.year, from: picked)
        let month = calendar.component(.month, from: picked)
        guard let startOfMonth = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: startOfMonth)
        else {
            return calendar.startOfDay(for: picked)
        }
        let day = min(calendar.component(.day, from: selected), range.count)
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
            .map { calendar.startOfDay(for: $0) }
            ?? calendar.startOfDay(for: picked)
    }

    /// A grid tap changes the day-of-month. Browsing to another month keeps it.
    static func isDayPick(from selected: Date, to picked: Date, calendar: Calendar = .current) -> Bool {
        calendar.component(.day, from: selected) != calendar.component(.day, from: picked)
    }
}

/// Fast month + year wheels. `yearAndMonth` only works with `.wheels`.
private struct CalendarMonthYearPicker: UIViewRepresentable {
    @Binding var date: Date

    func makeCoordinator() -> Coordinator {
        Coordinator(date: $date)
    }

    func makeUIView(context: Context) -> UIDatePicker {
        let picker = UIDatePicker()
        picker.datePickerMode = .yearAndMonth
        picker.preferredDatePickerStyle = .wheels
        picker.locale = .autoupdatingCurrent
        picker.calendar = .current
        picker.tintColor = UIColor(ScedraTheme.purple)
        picker.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        picker.setContentHuggingPriority(.required, for: .vertical)
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        picker.setContentCompressionResistancePriority(.required, for: .vertical)
        return picker
    }

    func updateUIView(_ picker: UIDatePicker, context: Context) {
        context.coordinator.date = $date
        picker.tintColor = UIColor(ScedraTheme.purple)
        if !Calendar.current.isDate(picker.date, equalTo: date, toGranularity: .month) {
            picker.setDate(date, animated: false)
        }
    }

    final class Coordinator: NSObject {
        var date: Binding<Date>

        init(date: Binding<Date>) {
            self.date = date
        }

        @objc func changed(_ sender: UIDatePicker) {
            date.wrappedValue = CalendarDayJump.preservingDay(
                from: date.wrappedValue,
                monthYearOf: sender.date
            )
        }
    }
}

struct CalendarTabView: View {
    var calendar: CalendarStore
    @State private var pendingDelete: TodayItem?
    @State private var selectedAppointment: SelectedAppointment?
    @State private var actionError: String?
    @State private var showSettings = false
    @State private var showDayPicker = false
    @State private var pickerDay = Date()

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                ScedraTheme.background.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 16) {
                    ScedraScreenHeader(title: "Calendar") {
                        showSettings = true
                    }
                    dayPicker
                    dayContents
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .scedraUsesSelectedTheme()
            .sheet(isPresented: $showSettings, onDismiss: {
                calendar.refreshHomeGapNotifications()
            }) {
                SettingsView()
            }
            .sheet(item: $selectedAppointment) { selected in
                EventDetailsSheet(
                    item: selected.item,
                    dayItems: calendar.selectedDayEvents,
                    calendar: calendar
                ) { item in
                    selectedAppointment = nil
                    delete(item)
                }
            }
            .scedraDeleteConfirmation(item: $pendingDelete, onConfirm: delete)
            .onAppear {
                calendar.loadSelectedDay()
            }
        }
    }

    private var dayPicker: some View {
        HStack {
            Button {
                calendar.shiftSelectedDay(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ScedraTheme.purple)
                    .padding(8)
            }
            .accessibilityLabel("Previous day")

            Spacer()
            Button {
                pickerDay = calendar.selectedDay
                showDayPicker = true
            } label: {
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        Text(calendar.selectedDay.scedraDisplay(date: .complete, time: .omitted))
                            .font(.system(size: 18, weight: .semibold, design: .serif))
                            .foregroundStyle(ScedraTheme.deepPurple)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(ScedraTheme.purple.opacity(0.8))
                    }
                    Text("Synced from Apple Calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(calendar.selectedDay.scedraDisplay(date: .complete, time: .omitted))
            .accessibilityHint(Text("Choose a day"))
            // Sheet on this control, not a popover: compact iPhone popovers were
            // easy to miss, and a parent `.sheet` would collide with Settings.
            .sheet(isPresented: $showDayPicker) {
                dayPickerSheet
            }
            Spacer()

            Button {
                calendar.shiftSelectedDay(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ScedraTheme.purple)
                    .padding(8)
            }
            .accessibilityLabel("Next day")
        }
    }

    /// Month/year wheels plus a month grid. Spinning months stays open; tapping a
    /// different day, Today, or Done jumps the way the chevrons do.
    private var dayPickerSheet: some View {
        let onToday = CalendarDayJump.isToday(pickerDay)
        let canCommit = CalendarDayJump.dayDelta(from: calendar.selectedDay, to: pickerDay) != 0
        return VStack(spacing: 12) {
            HStack {
                Text("Choose a day")
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundStyle(ScedraTheme.deepPurple)
                Spacer()
                Button {
                    jump(to: Date())
                } label: {
                    Text("Today")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(onToday ? ScedraTheme.purple.opacity(0.6) : .white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            onToday ? ScedraTheme.mist : ScedraTheme.purple,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(onToday)
                .accessibilityLabel("Jump to today")
            }
            CalendarMonthYearPicker(date: $pickerDay)
                .frame(maxWidth: .infinity, minHeight: 108, maxHeight: 124)
                .accessibilityLabel(Text("Choose a month"))
            DatePicker(
                "Choose a day",
                selection: Binding(
                    get: { pickerDay },
                    set: { newValue in
                        let commit = CalendarDayJump.isDayPick(from: pickerDay, to: newValue)
                        pickerDay = newValue
                        if commit { jump(to: newValue) }
                    }
                ),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .tint(ScedraTheme.purple)
            Button {
                jump(to: pickerDay)
            } label: {
                Text("Done")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(canCommit ? .white : ScedraTheme.purple.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        canCommit ? ScedraTheme.purple : ScedraTheme.mist,
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done")
        }
        .padding(16)
        .background(ScedraTheme.card)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(ScedraTheme.card)
        .scedraUsesSelectedTheme()
    }

    private func jump(to day: Date) {
        let delta = CalendarDayJump.dayDelta(from: calendar.selectedDay, to: day)
        if delta != 0 {
            calendar.shiftSelectedDay(by: delta)
        }
        showDayPicker = false
    }

    @ViewBuilder
    private var eventList: some View {
        switch CalendarDayPresentation.of(access: calendar.access, hasEvents: !calendar.selectedDayEvents.isEmpty) {
        case .checkingAccess:
            placeholder(ScedraString("Checking Calendar access…"))
        case .accessDenied:
            placeholder(ScedraString("Calendar access is off. Enable it in Settings."))
        case .writeOnlyWithoutEvents:
            placeholder(ScedraString("Grant full Calendar access to list events."))
        case .timeline:
            rows
        }
        if let actionError {
            Text(actionError)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    /// Problem cards ride the hour-grid scroll, starting above the hours.
    private var showsDayNotices: Bool {
        CalendarDayPresentation.of(
            access: calendar.access,
            hasEvents: !calendar.selectedDayEvents.isEmpty
        ) == .timeline
            && CalendarDayHomeGap.shouldShowNotices(for: calendar.selectedDayEvents)
    }

    private var dayContents: some View {
        eventList
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var rows: some View {
        DayTimelineView(
            day: calendar.selectedDay,
            items: calendar.selectedDayEvents,
            noticeStops: showsDayNotices
                ? CalendarDayHomeGap.stops(from: calendar.selectedDayEvents)
                : [],
            onSelect: { selectedAppointment = SelectedAppointment(item: $0) },
            onDelete: { pendingDelete = $0 },
            onShiftDay: { calendar.shiftSelectedDay(by: $0) }
        )
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scedraCard()
    }

    private func delete(_ item: TodayItem) {
        do {
            try calendar.delete(item)
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
        pendingDelete = nil
    }
}

struct EventDetailsSheet: View {
    let item: TodayItem
    var dayItems: [TodayItem] = []
    var calendar: CalendarStore?
    var onDelete: (TodayItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UserProfile.homeGapKey) private var homeGap = UserProfile.defaultHomeGapMinutes
    @State private var confirmDelete = false
    @State private var selectedMode: TravelMode
    @State private var travel: TravelState = .idle
    @State private var travelTask: Task<Void, Never>?
    @State private var placeResolver = PlaceResolver()
    @State private var displayed: TodayItem
    @State private var isEditing = false
    @State private var editStart: Date
    @State private var editEnd: Date
    @State private var editTitle = ""
    @State private var editLocation = ""
    @State private var locationAtEditStart = ""
    @State private var editStartText = ""
    @State private var editEndText = ""
    @State private var editError: String?
    @State private var isSavingEdit = false
    @State private var isResolvingEditLocation = false
    @State private var editConflicts: [CalendarConflict] = []
    @FocusState private var editField: EditField?

    private enum EditField: Hashable {
        case title, location, start, end
    }

    init(
        item: TodayItem,
        dayItems: [TodayItem] = [],
        calendar: CalendarStore? = nil,
        onDelete: @escaping (TodayItem) -> Void
    ) {
        self.item = item
        self.dayItems = dayItems
        self.calendar = calendar
        self.onDelete = onDelete
        _selectedMode = State(initialValue: item.appointmentTravelMode)
        _displayed = State(initialValue: item)
        _editStart = State(initialValue: item.officialStart)
        _editEnd = State(initialValue: item.officialEnd)
        _editTitle = State(initialValue: item.title)
        _editLocation = State(initialValue: item.placeLabel ?? "")
        _locationAtEditStart = State(initialValue: item.placeLabel ?? "")
        _editStartText = State(initialValue: item.officialStart.scedraDisplay(date: .omitted, time: .shortened))
        _editEndText = State(initialValue: item.officialEnd.scedraDisplay(date: .omitted, time: .shortened))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScedraTheme.background.ignoresSafeArea(edges: .top)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        detailsCard
                        if isEditing {
                            editTimeCard
                            editConflictCard
                        }
                        HomeGapSection(
                            stops: detailStops,
                            involving: [displayed.occurrenceKey]
                        )
                        if let original = ReviewOriginal.presentation(for: displayed) {
                            originalCard(original, ocrText: displayed.originalText)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Appointment")
            .navigationBarTitleDisplayMode(.inline)
            .scedraUsesSelectedTheme()
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        commitEditClocks()
                        editField = nil
                        ScedraKeyboard.resign()
                    }
                }
                if isEditing {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { cancelEdit() }
                            .foregroundStyle(ScedraTheme.purple)
                            .disabled(isSavingEdit)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { saveEdit() }
                            .foregroundStyle(ScedraTheme.purple)
                            .disabled(!canSaveEdit || isSavingEdit)
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Edit") { beginEdit() }
                            .foregroundStyle(ScedraTheme.purple)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .foregroundStyle(ScedraTheme.purple)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                deleteFooter
            }
            .alert("Delete this appointment?", isPresented: $confirmDelete) {
                Button("Delete from Calendar", role: .destructive) {
                    onDelete(displayed)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes “\(displayed.title)” from Apple Calendar.")
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            if displayed.showsDriveSection {
                recalculateTravel(mode: selectedMode)
            }
        }
            .onChange(of: editField) { oldValue, _ in
                _ = commitEditClockField(oldValue)
            }
            .onChange(of: editStart) { _, _ in refreshEditConflicts() }
            .onChange(of: editEnd) { _, _ in refreshEditConflicts() }
    }

    /// Don't show a saved Drive: line after she picked Public transport.
    private var savedTravelLine: String? {
        guard selectedMode == displayed.appointmentTravelMode else { return nil }
        return displayed.driveDisplay
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !isEditing {
                Text(displayed.title)
                    .font(.system(size: 28, weight: .regular, design: .serif))
                    .foregroundStyle(ScedraTheme.deepPurple)

                if let place = displayed.placeLabel {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place)
                            .font(.body.weight(.medium))
                            .foregroundStyle(ScedraTheme.deepPurple)
                        Text("Place")
                            .font(.caption)
                            .foregroundStyle(ScedraTheme.purple)
                    }
                    if displayed.showsDriveSection {
                        AppointmentTravelModeToggle(mode: $selectedMode)
                    }
                }
            } else if displayed.showsDriveSection || !editLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                AppointmentTravelModeToggle(mode: $selectedMode)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(displayed.officialTimeLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(ScedraTheme.deepPurple)
                if let caption = displayed.calendarBlockCaption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(ScedraTheme.purple)
                } else {
                    Text("Appointment")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if displayed.showsDriveSection {
                driveSection
            }
            if let pin = displayed.navigationCoordinate {
                NavigateRow(
                    latitude: pin.latitude,
                    longitude: pin.longitude,
                    name: displayed.placeLabel ?? displayed.title,
                    mode: displayedMode
                )
            }
        }
        .scedraCard()
        .onChange(of: selectedMode) { _, newValue in
            recalculateTravel(mode: newValue)
        }
    }

    private var editTimeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            editTextField("Title", text: $editTitle, field: .title, prompt: "Title")
            editTextField("Location", text: $editLocation, field: .location, prompt: "Location (optional)")
            if isResolvingEditLocation {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(ScedraTheme.purple)
                    Text("Finding nearby…")
                }
                .font(.caption)
                .foregroundStyle(ScedraTheme.purple)
            }
            DatePicker("Date", selection: editDayBinding, displayedComponents: .date)
                .tint(ScedraTheme.purple)
            editTextField("Start", text: $editStartText, field: .start, prompt: "2:00 PM")
            editTextField("End", text: $editEndText, field: .end, prompt: "3:00 PM")
            if let editError {
                Text(editError)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if !canSaveEdit {
                Text("This needs a date and a time before it can be saved.")
                    .font(.caption)
                    .foregroundStyle(ScedraTheme.purple)
            }
        }
        .font(.body.weight(.medium))
        .foregroundStyle(ScedraTheme.deepPurple)
        .scedraCard()
    }

    private func editTextField(
        _ title: LocalizedStringKey,
        text: Binding<String>,
        field: EditField,
        prompt: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ScedraTheme.purple)
            TextField(title, text: text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .keyboardType(field == .start || field == .end ? .numbersAndPunctuation : .default)
                .textInputAutocapitalization(field == .start || field == .end ? .never : .sentences)
                .autocorrectionDisabled(field == .start || field == .end)
                .focused($editField, equals: field)
                .submitLabel(.done)
                .onSubmit {
                    _ = commitEditClockField(field)
                    editField = nil
                    ScedraKeyboard.resign()
                    syncEditClockTexts()
                }
                .disabled(field == .location && isResolvingEditLocation)
                .padding(10)
                .background(ScedraTheme.blush, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    @ViewBuilder
    private var editConflictCard: some View {
        if !editConflicts.isEmpty {
            CollapsibleNoticeCard(headline: ScedraString("Conflict"), accent: ScedraTheme.conflict) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(editConflicts) { conflict in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Overlaps \(conflict.title)")
                                .font(.system(size: 20, weight: .regular, design: .serif))
                                .foregroundStyle(ScedraTheme.deepPurple)
                            Text(conflictTime(conflict))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Won’t move that event. Save still updates this one.")
                        .font(.caption)
                        .foregroundStyle(ScedraTheme.purple)
                }
            }
        }
    }

    private var detailStops: [HomeGapStop] {
        let items = dayItems.isEmpty ? [displayed] : dayItems.map { $0.id == displayed.id ? displayed : $0 }
        return items.filter { !$0.isAllDay }.map { $0.asHomeGapStop() }
    }

    private var displayedMode: TravelMode {
        if case .ready(let estimate) = travel {
            return estimate.fellBackToDriving ? .drive : estimate.mode
        }
        return selectedMode
    }

    @ViewBuilder
    private var driveSection: some View {
        switch travel {
        case .estimating:
            HStack(spacing: 8) {
                ProgressView()
                    .tint(ScedraTheme.purple)
                Text(TravelEstimator.loadingMessage(for: selectedMode))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(ScedraTheme.purple)
        case .ready(let estimate):
            VStack(alignment: .leading, spacing: 2) {
                Label(TravelEstimator.line(for: estimate), systemImage: travelIcon(displayedMode))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ScedraTheme.purple)
                if let note = TravelEstimator.note(for: estimate) {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case .unavailable(let reason):
            Label(reason, systemImage: selectedMode == .transit ? "tram" : "car")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        case .idle:
            if let drive = savedTravelLine {
                VStack(alignment: .leading, spacing: 2) {
                    Label(
                        TravelEstimator.labeledSavedLine(drive, mode: selectedMode),
                        systemImage: travelIcon(selectedMode)
                    )
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ScedraTheme.purple)
                    if let leave = displayed.leaveByDisplay {
                        Text(TravelEstimator.localizedLeaveByLine(leave))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Label(
                    selectedMode == .transit
                        ? "No transit time saved."
                        : "No drive time saved.",
                    systemImage: selectedMode == .transit ? "tram" : "car"
                )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func travelIcon(_ mode: TravelMode) -> String {
        switch mode {
        case .drive: "car.fill"
        case .transit: "tram.fill"
        case .walk: "figure.walk"
        }
    }

    private func recalculateTravel(mode: TravelMode, searchPlaceIfPinMissing: Bool = true) {
        travelTask?.cancel()
        travel = .estimating
        travelTask = Task {
            var latitude = displayed.latitude
            var longitude = displayed.longitude
            if searchPlaceIfPinMissing, latitude == nil || longitude == nil {
                let query = displayed.placeLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !query.isEmpty,
                   let place = await placeResolver.resolve(query),
                   let lat = place.latitude,
                   let lng = place.longitude {
                    latitude = lat
                    longitude = lng
                    displayed = TodayItem(
                        id: displayed.id,
                        title: displayed.title,
                        start: displayed.start,
                        end: displayed.end,
                        isAllDay: displayed.isAllDay,
                        location: displayed.location,
                        notes: displayed.notes,
                        latitude: lat,
                        longitude: lng
                    )
                }
            }
            guard !Task.isCancelled else { return }
            guard let latitude, let longitude else {
                travel = .unavailable(TravelEstimator.noPinMessage)
                return
            }
            let pin = await placeResolver.resolvedTravelOrigin()
            guard !Task.isCancelled else { return }
            guard let pin else {
                travel = .unavailable(TravelEstimator.noOriginMessage)
                return
            }
            let estimate = await TravelEstimator.roundTripEstimate(
                from: pin.location,
                toLatitude: latitude,
                longitude: longitude,
                mode: mode,
                start: displayed.officialStart,
                end: displayed.officialEnd,
                bufferMinutes: homeGap,
                fromHome: pin.fromHome
            )
            guard !Task.isCancelled else { return }
            if let estimate {
                travel = .ready(estimate)
                try? calendar?.updateTravelNotes(
                    for: displayed,
                    travel: estimate,
                    latitude: latitude,
                    longitude: longitude
                )
            } else {
                travel = .unavailable(TravelEstimator.noRouteMessage(for: mode))
            }
        }
    }

    private func originalCard(_ original: ReviewOriginal, ocrText: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Original")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ScedraTheme.deepPurple)
            switch original {
            case .photo(let url):
                if let image = OriginalImageStore.image(at: url) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityLabel("Original photo")
                }
                if let ocrText, !ocrText.isEmpty {
                    DisclosureGroup("Read text") {
                        Text(ocrText)
                            .font(.body)
                            .foregroundStyle(ScedraTheme.deepPurple)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                    .foregroundStyle(ScedraTheme.deepPurple)
                }
            case .text(let text):
                Text(text)
                    .font(.body)
                    .foregroundStyle(ScedraTheme.deepPurple)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scedraCard()
    }

    private var deleteFooter: some View {
        Button(role: .destructive) {
            confirmDelete = true
        } label: {
            Label("Delete from Calendar", systemImage: "trash")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
        .background(ScedraTheme.conflict, in: Capsule())
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background {
            ScedraTheme.background
                .ignoresSafeArea(edges: .bottom)
        }
        .accessibilityLabel("Delete \(displayed.title)")
    }

    private var canSaveEdit: Bool {
        CalendarSaveGate.readyToSave(start: editStart, end: editEnd)
    }

    private func beginEdit() {
        editTitle = displayed.title
        locationAtEditStart = displayed.placeLabel ?? ""
        editLocation = locationAtEditStart
        editStart = displayed.officialStart
        editEnd = displayed.officialEnd
        syncEditClockTexts()
        editError = nil
        isResolvingEditLocation = false
        isEditing = true
        refreshEditConflicts()
    }

    private func cancelEdit() {
        travelTask?.cancel()
        editTitle = displayed.title
        editLocation = displayed.placeLabel ?? ""
        locationAtEditStart = editLocation
        editStart = displayed.officialStart
        editEnd = displayed.officialEnd
        syncEditClockTexts()
        editError = nil
        editConflicts = []
        isResolvingEditLocation = false
        isSavingEdit = false
        isEditing = false
        editField = nil
    }

    private func saveEdit() {
        guard canSaveEdit else {
            editError = CalendarStoreError.missingDateOrTime.errorDescription
            return
        }
        guard let calendar else {
            editError = CalendarStoreError.noAccess.errorDescription
            return
        }
        commitEditClocks()
        guard canSaveEdit else {
            editError = CalendarStoreError.missingDateOrTime.errorDescription
            return
        }
        isSavingEdit = true
        editError = nil
        editField = nil
        ScedraKeyboard.resign()
        travelTask?.cancel()
        let title = editTitle
        let locationQuery = editLocation
        let locationChanged = EventScheduleEdit.locationTextChanged(
            from: locationAtEditStart,
            to: locationQuery
        )
        Task { @MainActor in
            defer {
                isResolvingEditLocation = false
                isSavingEdit = false
            }
            var latitude = displayed.latitude
            var longitude = displayed.longitude
            var resolvedLocation = EventScheduleEdit.normalizedLocation(locationQuery)
            if locationChanged {
                if resolvedLocation == nil {
                    latitude = nil
                    longitude = nil
                } else if let query = resolvedLocation {
                    isResolvingEditLocation = true
                    if let place = await placeResolver.resolve(query) {
                        resolvedLocation = place.displayLine
                        editLocation = place.displayLine
                        latitude = place.latitude
                        longitude = place.longitude
                    }
                    isResolvingEditLocation = false
                }
            }
            do {
                try await calendar.updateEventTimes(
                    displayed,
                    start: editStart,
                    end: editEnd,
                    title: title,
                    location: resolvedLocation,
                    latitude: latitude,
                    longitude: longitude
                )
                if let updated = calendar.today.first(where: { $0.id == displayed.id })
                    ?? calendar.selectedDayEvents.first(where: { $0.id == displayed.id }) {
                    displayed = TodayItem(
                        id: updated.id,
                        title: updated.title,
                        start: updated.start,
                        end: updated.end,
                        isAllDay: updated.isAllDay,
                        location: updated.location,
                        notes: updated.notes,
                        latitude: updated.latitude ?? latitude,
                        longitude: updated.longitude ?? longitude
                    )
                } else if let prepared = try? EventScheduleEdit.prepare(
                    item: displayed,
                    officialStart: editStart,
                    officialEnd: editEnd,
                    title: title,
                    location: resolvedLocation
                ) {
                    displayed = TodayItem(
                        id: displayed.id,
                        title: prepared.title,
                        start: prepared.start,
                        end: prepared.end,
                        isAllDay: false,
                        location: prepared.location,
                        notes: prepared.notes ?? displayed.notes,
                        latitude: latitude ?? displayed.latitude,
                        longitude: longitude ?? displayed.longitude
                    )
                }
                locationAtEditStart = displayed.placeLabel ?? ""
                editLocation = locationAtEditStart
                isEditing = false
                if displayed.showsDriveSection {
                    recalculateTravel(
                        mode: selectedMode,
                        searchPlaceIfPinMissing: locationChanged && displayed.navigationCoordinate == nil
                    )
                } else {
                    travel = .idle
                }
            } catch {
                editError = error.localizedDescription
            }
        }
    }

    private func refreshEditConflicts() {
        guard isEditing, let calendar, canSaveEdit else {
            editConflicts = []
            return
        }
        guard let prepared = try? EventScheduleEdit.prepare(
            item: displayed,
            officialStart: editStart,
            officialEnd: editEnd
        ) else {
            editConflicts = []
            return
        }
        editConflicts = calendar.conflicts(
            overlapping: prepared.start,
            end: prepared.end,
            excluding: displayed.id
        )
    }

    private func conflictTime(_ conflict: CalendarConflict) -> String {
        let start = conflict.start.scedraDisplay(date: .omitted, time: .shortened)
        let end = conflict.end.scedraDisplay(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    private var editDayBinding: Binding<Date> {
        Binding(
            get: { editStart },
            set: { newDay in
                editStart = combining(day: newDay, time: editStart)
                editEnd = combining(day: newDay, time: editEnd)
                syncEditClockTexts()
                refreshEditConflicts()
            }
        )
    }

    private func formatEditClock(_ date: Date) -> String {
        date.scedraDisplay(date: .omitted, time: .shortened)
    }

    private func syncEditClockTexts() {
        if editField != .start {
            editStartText = formatEditClock(editStart)
        }
        if editField != .end {
            editEndText = formatEditClock(editEnd)
        }
    }

    private func commitEditClocks() {
        _ = commitEditClockField(.start)
        _ = commitEditClockField(.end)
        syncEditClockTexts()
    }

    @discardableResult
    private func commitEditClockField(_ field: EditField?) -> Bool {
        switch field {
        case .start:
            return applyEditClock(editStartText, asEnd: false)
        case .end:
            return applyEditClock(editEndText, asEnd: true)
        default:
            return true
        }
    }

    private func applyEditClock(_ text: String, asEnd: Bool) -> Bool {
        let canonical = formatEditClock(asEnd ? editEnd : editStart)
        if ReviewTimeTyping.normalize(text).isEmpty
            || ReviewTimeTyping.clocksMatch(text, formatted: canonical) {
            return true
        }
        guard let parsed = ReviewTimeTyping.parseAppointment(text) else { return false }
        switch parsed {
        case .clock(let hour, let minute, _):
            let calendar = Calendar.current
            let day = asEnd ? editEnd : editStart
            guard let next = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else {
                return false
            }
            if asEnd {
                editEnd = next
            } else {
                editStart = next
            }
        case .window(let startHour, let startMinute, let endHour, let endMinute):
            let calendar = Calendar.current
            if let start = calendar.date(bySettingHour: startHour, minute: startMinute, second: 0, of: editStart) {
                editStart = start
            }
            if let end = calendar.date(bySettingHour: endHour, minute: endMinute, second: 0, of: editStart) {
                editEnd = end < editStart ? end.addingTimeInterval(24 * 3600) : end
            }
        }
        refreshEditConflicts()
        return true
    }

    private func combining(day: Date, time: Date) -> Date {
        let calendar = Calendar.current
        let clock = calendar.dateComponents([.hour, .minute, .second], from: time)
        return calendar.date(
            bySettingHour: clock.hour ?? 0,
            minute: clock.minute ?? 0,
            second: clock.second ?? 0,
            of: day
        ) ?? time
    }
}

/// Plain rows, not a List: both screens place this inside a ScrollView, where a nested
/// List's `.swipeActions` never receive the gesture. Delete is an always-visible trash
/// button instead — still no ••• menu, and tapping a row opens Review-style details.
struct EventListView: View {
    let items: [TodayItem]
    var onSelect: (TodayItem) -> Void
    var onDelete: (TodayItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                if offset > 0 {
                    Divider()
                        .padding(.vertical, 2)
                }
                EventRowView(
                    item: item,
                    hasOriginal: item.hasOriginal,
                    onTap: { onSelect(item) },
                    onDelete: { onDelete(item) }
                )
            }
        }
    }
}

struct EventRowView: View {
    let item: TodayItem
    var hasOriginal: Bool
    var onTap: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(ScedraTheme.deepPurple)
                    if let location = item.location, !location.isEmpty {
                        Text(location)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(item.todayTimeLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ScedraTheme.purple)
                    if let caption = item.todayAppointmentCaption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.trailing)
                if hasOriginal {
                    Image(systemName: item.originalIndicatorSymbol)
                        .font(.caption)
                        .foregroundStyle(ScedraTheme.purple.opacity(0.7))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityHint("Tap to view appointment details.")
            .onTapGesture {
                onTap()
            }

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.body)
                    .foregroundStyle(ScedraTheme.conflict)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(item.title)")
        }
        .padding(.vertical, 8)
    }
}

/// Trash tap copies the appointment into `snapshot` and shows an alert whose
/// Delete button uses that copy. Tying the alert to `pendingDelete != nil` was
/// wiping the item as the sheet dismissed, so Confirm never reached EventKit.
struct ScedraDeleteConfirmation: ViewModifier {
    @Binding var item: TodayItem?
    var onConfirm: (TodayItem) -> Void

    @State private var snapshot: TodayItem?
    @State private var show = false

    func body(content: Content) -> some View {
        content
            .onChange(of: item) { _, newValue in
                if let newValue {
                    snapshot = newValue
                    show = true
                }
            }
            .alert("Delete this appointment?", isPresented: $show) {
                Button("Delete from Calendar", role: .destructive) {
                    if let snapshot {
                        onConfirm(snapshot)
                    }
                    snapshot = nil
                    item = nil
                }
                Button("Cancel", role: .cancel) {
                    snapshot = nil
                    item = nil
                }
            } message: {
                if let snapshot {
                    Text("Removes “\(snapshot.title)” from Apple Calendar.")
                } else {
                    Text("Removes this from Apple Calendar.")
                }
            }
    }
}

extension View {
    func scedraDeleteConfirmation(
        item: Binding<TodayItem?>,
        onConfirm: @escaping (TodayItem) -> Void
    ) -> some View {
        modifier(ScedraDeleteConfirmation(item: item, onConfirm: onConfirm))
    }
}
