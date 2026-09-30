import SwiftUI

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
/// Calendar pins these under the date header, outside the hour-grid ScrollView.
enum CalendarDayHomeGap {
    static func stops(from items: [TodayItem]) -> [HomeGapStop] {
        items.filter { !$0.isAllDay }.map { $0.asHomeGapStop() }
    }

    static func shouldShowNotices(for items: [TodayItem]) -> Bool {
        !HomeGapLogic.consecutivePairs(from: stops(from: items)).isEmpty
    }
}

struct CalendarTabView: View {
    var calendar: CalendarStore
    @State private var pendingDelete: TodayItem?
    @State private var selectedAppointment: SelectedAppointment?
    @State private var actionError: String?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                ScedraTheme.background.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 16) {
                    ScedraScreenHeader(title: "Calendar") {
                        showSettings = true
                    }
                    dayPicker
                    if showsDayNotices {
                        HomeGapSection(stops: CalendarDayHomeGap.stops(from: calendar.selectedDayEvents))
                    }
                    eventList
                }
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
            VStack(spacing: 2) {
                Text(calendar.selectedDay.scedraDisplay(date: .complete, time: .omitted))
                    .font(.system(size: 18, weight: .semibold, design: .serif))
                    .foregroundStyle(ScedraTheme.deepPurple)
                Text("Synced from Apple Calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    /// Collapsed notices sit under the date — never inside the hour-grid scroll.
    private var showsDayNotices: Bool {
        CalendarDayPresentation.of(
            access: calendar.access,
            hasEvents: !calendar.selectedDayEvents.isEmpty
        ) == .timeline
            && CalendarDayHomeGap.shouldShowNotices(for: calendar.selectedDayEvents)
    }

    private var rows: some View {
        DayTimelineView(
            day: calendar.selectedDay,
            items: calendar.selectedDayEvents,
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
    @State private var editError: String?
    @State private var isSavingEdit = false
    @State private var editConflicts: [CalendarConflict] = []

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
                        if let original = displayed.originalText {
                            originalCard(original)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Appointment")
            .navigationBarTitleDisplayMode(.inline)
            .scedraUsesSelectedTheme()
            .toolbar {
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
            if selectedMode == .transit {
                recalculateTravel(mode: .transit)
            }
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
            DatePicker("Date", selection: $editStart, displayedComponents: .date)
                .tint(ScedraTheme.purple)
                .onChange(of: editStart) { _, newDay in
                    editEnd = combining(day: newDay, time: editEnd)
                }
            DatePicker("Start", selection: $editStart, displayedComponents: .hourAndMinute)
                .tint(ScedraTheme.purple)
            DatePicker("End", selection: $editEnd, displayedComponents: [.date, .hourAndMinute])
                .tint(ScedraTheme.purple)
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

    private func recalculateTravel(mode: TravelMode) {
        travelTask?.cancel()
        guard let latitude = displayed.latitude, let longitude = displayed.longitude else {
            travel = .unavailable(TravelEstimator.noPinMessage)
            return
        }
        travel = .estimating
        travelTask = Task {
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
                try? calendar?.updateTravelNotes(for: displayed, travel: estimate)
            } else {
                travel = .unavailable(TravelEstimator.noRouteMessage(for: mode))
            }
        }
    }

    private func originalCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Original")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ScedraTheme.deepPurple)
            Text(text)
                .font(.body)
                .foregroundStyle(ScedraTheme.deepPurple)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        editStart = displayed.officialStart
        editEnd = displayed.officialEnd
        editError = nil
        isEditing = true
        refreshEditConflicts()
    }

    private func cancelEdit() {
        editStart = displayed.officialStart
        editEnd = displayed.officialEnd
        editError = nil
        editConflicts = []
        isEditing = false
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
        isSavingEdit = true
        editError = nil
        Task { @MainActor in
            do {
                try await calendar.updateEventTimes(displayed, start: editStart, end: editEnd)
                if let updated = calendar.today.first(where: { $0.id == displayed.id })
                    ?? calendar.selectedDayEvents.first(where: { $0.id == displayed.id }) {
                    displayed = updated
                } else if let prepared = try? EventScheduleEdit.prepare(
                    item: displayed,
                    officialStart: editStart,
                    officialEnd: editEnd
                ) {
                    displayed = TodayItem(
                        id: displayed.id,
                        title: displayed.title,
                        start: prepared.start,
                        end: prepared.end,
                        isAllDay: false,
                        location: displayed.location,
                        notes: prepared.notes ?? displayed.notes,
                        latitude: displayed.latitude,
                        longitude: displayed.longitude
                    )
                }
                isEditing = false
            } catch {
                editError = error.localizedDescription
            }
            isSavingEdit = false
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
                    hasOriginal: item.originalText != nil,
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
                    Image(systemName: "doc.text")
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
