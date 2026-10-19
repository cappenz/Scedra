import CoreLocation
import EventKit
import Foundation

struct TodayItem: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    var notes: String? = nil
    var latitude: Double? = nil
    var longitude: Double? = nil

    /// Scedra's local map first, then the wording stored in the event's notes.
    var originalText: String? {
        OriginalTextStore.text(for: id) ?? EventNotes.original(from: notes)
    }

    /// Photo capture keeps the image locally; voice and type stay nil.
    var originalImageURL: URL? {
        OriginalTextStore.imageURL(for: id)
    }

    var hasOriginal: Bool {
        originalText != nil || originalImageURL != nil
    }

    var originalIndicatorSymbol: String {
        originalImageURL == nil ? "doc.text" : "photo"
    }

    var savedInfo: SavedAppointmentInfo {
        EventNotes.savedInfo(from: notes)
    }

    /// Recurring events share an EventKit identifier; the occurrence she tapped does not.
    var occurrenceKey: String {
        "\(id)-\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)"
    }

    var placeLabel: String? {
        if let location, !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return location
        }
        let fromNotes = savedInfo.placeFromNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fromNotes.isEmpty ? nil : fromNotes
    }

    /// Official appointment window from notes when the calendar block was travel-padded.
    var officialTimeLabel: String {
        if isAllDay { return ScedraString("All day") }
        if let window = savedInfo.appointmentWindow, !window.isEmpty {
            return window
        }
        return TravelEstimator.appointmentWindow(from: start, to: end)
    }

    /// True when the EventKit block is wider than the official appointment (drive padding).
    var calendarBlockCaption: String? {
        guard savedInfo.appointmentWindow != nil, !isAllDay else { return nil }
        let block = TravelEstimator.appointmentWindow(from: start, to: end)
        guard block != officialTimeLabel else { return nil }
        return TravelEstimator.localizedBlockCaption(window: block, mode: savedInfo.resolvedTravelMode)
    }

    var showsDriveSection: Bool {
        !isAllDay && placeLabel != nil && !isDriveEvent
    }

    /// Linked outbound drive block — not an appointment to estimate or send home-gap about.
    var isDriveEvent: Bool {
        DriveTimeLogic.isDriveEvent(title: title, notes: notes)
    }

    var contributesToHomeGap: Bool {
        !isAllDay && !isDriveEvent
    }

    var driveDisplay: String? {
        guard let line = savedInfo.driveLine else { return nil }
        return TravelEstimator.labeledSavedLine(line, mode: appointmentTravelMode)
    }
    var leaveByDisplay: String? { savedInfo.leaveByLine }
    var appointmentTravelMode: TravelMode { savedInfo.resolvedTravelMode }

    /// Today list clock: leave-by when notes recorded travel, else the official window.
    var todayTimeLabel: String {
        if let leave = leaveByDisplay, !leave.isEmpty {
            return TravelEstimator.localizedLeaveByLine(leave)
        }
        return officialTimeLabel
    }

    /// Official window under leave-by so the list still says when the thing is.
    var todayAppointmentCaption: String? {
        guard leaveByDisplay != nil, !isAllDay else { return nil }
        return ScedraString("Appointment \(officialTimeLabel)")
    }

    /// Stated appointment start, not the travel-padded EventKit start.
    var officialStart: Date {
        officialWindow?.start ?? start
    }

    /// Stated appointment end, not the travel-padded EventKit end.
    var officialEnd: Date {
        officialWindow?.end ?? end
    }

    var navigationCoordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        let pin = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(pin) ? pin : nil
    }

    func asHomeGapStop() -> HomeGapStop {
        let place = placeLabel ?? ""
        return HomeGapStop(
            id: occurrenceKey,
            title: title,
            place: place,
            officialStart: officialStart,
            officialEnd: officialEnd,
            extraBeforeMinutes: 0,
            extraAfterMinutes: 0,
            latitude: latitude,
            longitude: longitude,
            usesHome: place.isEmpty || HomeGapLogic.looksLikeHome(place),
            notes: notes ?? "",
            isDriveEvent: isDriveEvent,
            calendarEventID: id
        )
    }

    private var officialWindow: (start: Date, end: Date)? {
        OfficialAppointmentWindow.parse(savedInfo.appointmentWindow, around: start, blockEnd: end)
    }
}

/// Sheet identity for a tapped occurrence. Recurring events share `TodayItem.id`.
struct SelectedAppointment: Identifiable, Equatable {
    var item: TodayItem
    var id: String { item.occurrenceKey }
}

/// Confirm's date+time gate. A Review card that already shows a clock window
/// (`hasDisplayedDateAndTime`) is ready to save even when the extractor left
/// `hasDate`/`hasTime` false.
enum CalendarSaveGate {
    static func readyToSave(_ draft: DraftEvent) -> DraftEvent? {
        var draft = draft
        if draft.hasDisplayedDateAndTime {
            draft.acceptDisplayedDateAndTime()
        }
        guard draft.hasDate, draft.hasTime else { return nil }
        return draft
    }

    /// Event edits use the displayed day + clock. Same rule as Confirm: both required.
    static func readyToSave(start: Date, end: Date) -> Bool {
        end > start
    }
}

/// Maps a user-initiated appointment edit onto the existing EventKit event.
/// Never invents a new identifier — CalendarStore saves the event she tapped.
enum EventScheduleEdit {
    struct Prepared: Equatable {
        var identifier: String
        var title: String
        var start: Date
        var end: Date
        var location: String?
        var notes: String?
    }

    static func prepare(
        item: TodayItem,
        officialStart: Date,
        officialEnd: Date,
        title: String? = nil,
        location: String? = nil,
        placement: DriveTimePlacement = .resolved()
    ) throws -> Prepared {
        guard CalendarSaveGate.readyToSave(start: officialStart, end: officialEnd) else {
            throw CalendarStoreError.missingDateOrTime
        }
        let blockStart: Date
        let blockEnd: Date
        let applied = DriveTimeLogic.source(for: item) == .existingCalendarEvent
            ? DriveTimePlacement.separateEvent
            : placement
        switch applied {
        case .separateEvent:
            blockStart = officialStart
            blockEnd = officialEnd
        case .partOfEvent:
            let padBefore = item.officialStart.timeIntervalSince(item.start)
            let padAfter = item.end.timeIntervalSince(item.officialEnd)
            blockStart = officialStart.addingTimeInterval(-max(padBefore, 0))
            blockEnd = officialEnd.addingTimeInterval(max(padAfter, 0))
        }
        guard blockEnd > blockStart else {
            throw CalendarStoreError.missingDateOrTime
        }
        let nextTitle = title ?? item.title
        let nextLocation = normalizedLocation(location ?? item.location)
        var notes = replacingAppointmentWindow(in: item.notes, start: officialStart, end: officialEnd)
        notes = replacingPlaceLine(in: notes, oldPlace: item.placeLabel, newPlace: nextLocation ?? "")
        return Prepared(
            identifier: item.id,
            title: nextTitle,
            start: blockStart,
            end: blockEnd,
            location: nextLocation,
            notes: notes
        )
    }

    static func normalizedLocation(_ location: String?) -> String? {
        let trimmed = (location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Time-only edits must not look like a new place (whitespace / nil vs "").
    static func locationTextChanged(from original: String?, to edited: String?) -> Bool {
        normalizedLocation(original) != normalizedLocation(edited)
    }

    /// Rewrites a details place line. Original wording stays raw.
    static func replacingPlaceLine(in notes: String?, oldPlace: String?, newPlace: String) -> String? {
        guard var notes, !notes.isEmpty else { return notes }
        let old = (oldPlace ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let next = newPlace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty, old != next else { return notes }
        var lines = notes.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == old
                && !$0.contains(EventNotes.originalPrefix)
        }) else {
            return notes
        }
        if next.isEmpty {
            lines.remove(at: index)
        } else {
            lines[index] = next
        }
        return lines.joined(separator: "\n")
    }

    /// Rewrites the Appointment: clock line. Original wording stays raw.
    static func replacingAppointmentWindow(in notes: String?, start: Date, end: Date) -> String? {
        guard var notes, !notes.isEmpty else { return notes }
        let window = TravelEstimator.appointmentWindow(from: start, to: end)
        let prefixes = ["Appointment:", "Rendez-vous :", "Rendez-vous:", "Cita:", "Termin:"]
        for prefix in prefixes {
            if let prefixRange = notes.range(of: prefix) {
                let after = prefixRange.upperBound
                let rest = notes[after...]
                let lineEnd = rest.firstIndex(of: "\n") ?? notes.endIndex
                let replacement = " \(window)"
                notes.replaceSubrange(after..<lineEnd, with: replacement)
                return notes
            }
        }
        return notes
    }
}

enum CalendarAccess: Equatable {
    case unknown
    case full
    case writeOnly
    case denied
}

enum CalendarStoreError: LocalizedError {
    case noAccess
    case noCalendar
    case missingDateOrTime
    case saveFailed(String)
    case deleteFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAccess:
            return ScedraString("Calendar access needed to save.")
        case .noCalendar:
            return ScedraString("No default calendar is available on this device.")
        case .missingDateOrTime:
            return ScedraString("This needs a date and a time before it can be saved.")
        case .saveFailed(let message):
            return message
        case .deleteFailed(let message):
            return message
        }
    }
}

/// EventKit is not thread-safe. Access prompts and `save(..., commit: true)` must
/// stay on the main actor — an `async` hop off-main is how Confirm used to
/// "succeed" without a real Apple Calendar event.
@MainActor
@Observable
final class CalendarStore: TaskCalendarWriter {
    var today: [TodayItem] = []
    var selectedDay = Calendar.current.startOfDay(for: Date())
    var selectedDayEvents: [TodayItem] = []
    var access: CalendarAccess = .unknown

    private var store = EKEventStore()
    private var storeChangedObserver: (any NSObjectProtocol)?
    /// Keeps a just-saved today event visible if EventKit’s query is still stale.
    private var recentlySavedToday: [TodayItem] = []
    /// Calendar Confirm last wrote to — Today queries include it even if EventKit’s default is nil.
    private var lastSavedCalendar: EKCalendar?
    /// IDs (and title/start/end) of events we already removed, so a stale EventKit
    /// query cannot put them back on Today or the timeline.
    private var forgottenIDs: Set<String> = []
    private var forgottenAppointments: [ForgottenAppointment] = []
    /// EKEvent objects Confirm just wrote, so write-only delete can still call remove().
    private var retainedEvents: [String: EKEvent] = [:]
    /// Coalesces Maps + notification reschedule after Today / store-changed reloads.
    private var homeGapNotifyTask: Task<Void, Never>?
    private var appActiveObserver: (any NSObjectProtocol)?
    /// Calendar UI / Apple Calendar deletions of a task EventKit event.
    var deletedEventIDsHandler: (([String]) -> Void)?
    /// Fired after EventKit notifies that the store changed.
    var storeChangedHandler: (() -> Void)?
    /// Fired after Confirm's EventKit save commits. Onboarding observes this only.
    var savedAppointmentHandler: (() -> Void)?

    private struct ForgottenAppointment: Equatable {
        var title: String
        var start: Date
        var end: Date
    }

    func requestAccessAndLoad() async {
        do {
            let granted = try await store.requestFullAccessToEvents()
            if granted {
                access = .full
            } else if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                let writeOnly = try await store.requestWriteOnlyAccessToEvents()
                access = writeOnly ? .writeOnly : mappedAccess()
            } else {
                access = mappedAccess()
            }
        } catch {
            access = mappedAccess()
        }
        // A store created before the prompt does not see the new permission.
        resetStore()
        listenForAppActive()
        loadToday()
        loadSelectedDay()
    }

    func loadToday() {
        switch access {
        case .full:
            store.refreshSourcesIfNecessary()
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: Date())
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
                today = recentlySavedToday
                refreshHomeGapNotifications()
                return
            }
            let predicate = store.predicateForEvents(
                withStart: start,
                end: end,
                calendars: calendarsForTodayQuery()
            )
            today = store.events(matching: predicate)
                .sorted { $0.startDate < $1.startDate }
                .map(todayItem(from:))
            mergeRecentlySavedToday()
            today.removeAll(where: isForgotten)
        case .writeOnly:
            today = recentlySavedToday
                .filter { TodayWindow.contains(start: $0.start, end: $0.end) }
                .filter { !isForgotten($0) }
                .sorted { $0.start < $1.start }
        default:
            today = []
        }
        refreshHomeGapNotifications()
    }

    /// Rebuild local home-gap reminders and retry missing pins / drive minutes.
    /// 1.5s debounce coalesces Today appear, Calendar appear, selected-day
    /// changes, store updates, and becoming active so Maps is not blasted.
    func refreshHomeGapNotifications() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        homeGapNotifyTask?.cancel()
        homeGapNotifyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            await HomeGapNotificationPlanner.refresh(using: self)
        }
    }

    func loadSelectedDay() {
        selectedDayEvents = events(on: selectedDay)
        refreshHomeGapNotifications()
    }

    /// Persist a geocoded pin onto an existing EKEvent that only had location text.
    func attachResolvedPin(to item: TodayItem, latitude: Double, longitude: Double) {
        guard access == .full || access == .writeOnly else { return }
        let pin = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(pin) else { return }
        func patched(_ existing: TodayItem) -> TodayItem {
            TodayItem(
                id: existing.id,
                title: existing.title,
                start: existing.start,
                end: existing.end,
                isAllDay: existing.isAllDay,
                location: existing.location,
                notes: existing.notes,
                latitude: latitude,
                longitude: longitude
            )
        }
        if let index = recentlySavedToday.firstIndex(where: { $0.id == item.id || sameAppointment($0, item) }) {
            recentlySavedToday[index] = patched(recentlySavedToday[index])
        }
        if let index = today.firstIndex(where: { $0.id == item.id || sameAppointment($0, item) }) {
            today[index] = patched(today[index])
        }
        if let index = selectedDayEvents.firstIndex(where: { $0.id == item.id || sameAppointment($0, item) }) {
            selectedDayEvents[index] = patched(selectedDayEvents[index])
        }
        guard let event = eventMatching(item) else { return }
        if event.structuredLocation?.geoLocation != nil { return }
        guard event.calendar?.allowsContentModifications ?? true else { return }
        let title = event.location ?? item.placeLabel ?? item.title
        let structured = EKStructuredLocation(title: title)
        structured.geoLocation = CLLocation(latitude: latitude, longitude: longitude)
        event.structuredLocation = structured
        try? store.save(event, span: .thisEvent, commit: true)
    }

    func shiftSelectedDay(by days: Int) {
        if let next = Calendar.current.date(byAdding: .day, value: days, to: selectedDay) {
            selectedDay = Calendar.current.startOfDay(for: next)
            loadSelectedDay()
        }
    }

    func events(on day: Date) -> [TodayItem] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        switch access {
        case .full:
            store.refreshSourcesIfNecessary()
            let predicate = store.predicateForEvents(
                withStart: start,
                end: end,
                calendars: calendarsForTodayQuery()
            )
            var items = store.events(matching: predicate)
                .sorted { $0.startDate < $1.startDate }
                .map(todayItem(from:))
            for pending in recentlySavedToday where pending.start < end && pending.end > start {
                if !items.contains(where: { $0.id == pending.id || sameAppointment($0, pending) }) {
                    items.append(pending)
                }
            }
            items.sort { $0.start < $1.start }
            return items.filter { !isForgotten($0) }
        case .writeOnly:
            return recentlySavedToday
                .filter { $0.start < end && $0.end > start }
                .filter { !isForgotten($0) }
                .sorted { $0.start < $1.start }
        default:
            return []
        }
    }

    /// Every Scedra Drive to / Drive home / Drive from on this day, including
    /// just-written siblings EventKit has not yet returned and old For:/Leg: notes.
    func driveSiblings(on day: Date) -> [TodayItem] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        var items: [TodayItem] = []
        var seen = Set<String>()
        func add(_ item: TodayItem) {
            guard DriveTimeLogic.isScedraLinkedDrive(title: item.title, notes: item.notes, identifier: item.id)
            else { return }
            if seen.insert(item.id).inserted {
                items.append(item)
            }
        }
        if access == .full {
            store.refreshSourcesIfNecessary()
            let predicate = store.predicateForEvents(
                withStart: start,
                end: end,
                calendars: nil
            )
            for event in store.events(matching: predicate) where !event.isAllDay {
                add(todayItem(from: event))
            }
        }
        for pending in recentlySavedToday where pending.start < end && pending.end > start {
            add(pending)
        }
        for event in retainedEvents.values where !event.isAllDay {
            let item = todayItem(from: event)
            if item.start < end && item.end > start {
                add(item)
            }
        }
        for id in DriveEventLinkStore.allDriveIdentifiers() {
            if let event = eventForTaskIdentifier(id), !event.isAllDay {
                let item = todayItem(from: event)
                if item.start < end && item.end > start {
                    add(item)
                }
            }
        }
        return items.sorted { $0.start < $1.start }
    }

    /// Overlapping timed events already on Apple Calendar. Never used to move those events.
    func conflicts(overlapping start: Date, end: Date, excluding identifier: String? = nil) -> [CalendarConflict] {
        guard access == .full, end > start else { return [] }
        store.refreshSourcesIfNecessary()
        let predicate = store.predicateForEvents(
            withStart: start,
            end: end,
            calendars: calendarsForTodayQuery()
        )
        return store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .filter { event in
                let id = stableID(for: event)
                if let identifier, !identifier.isEmpty,
                   id == identifier
                    || event.eventIdentifier == identifier
                    || event.calendarItemIdentifier == identifier {
                    return false
                }
                return true
            }
            .filter { ConflictLogic.overlaps(start: start, end: end, otherStart: $0.startDate, otherEnd: $0.endDate) }
            .map {
                CalendarConflict(
                    id: stableID(for: $0),
                    title: $0.title ?? "Untitled",
                    start: $0.startDate,
                    end: $0.endDate
                )
            }
    }

    /// Writes a real EKEvent to Apple Calendar (`commit: true`), then refreshes Today.
    /// `travel` is whatever estimate the Review screen already had in hand — nil when it
    /// wasn't ready, because Confirm never waits on it.
    func save(_ draft: DraftEvent, travel: TravelEstimate? = nil) async throws {
        // A displayed 10:16–11:16 window is a date and a time. Extractor flags
        // must not refuse Confirm when the card is already showing a clock.
        guard let draft = CalendarSaveGate.readyToSave(draft) else {
            throw CalendarStoreError.missingDateOrTime
        }
        if access != .full && access != .writeOnly {
            await requestAccessAndLoad()
        }
        guard access == .full || access == .writeOnly else {
            throw CalendarStoreError.noAccess
        }
        let calendar = try calendarForSaving()

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = draft.calendarTitle
        let place = draft.locationToSave
        // Appointment times only. Never write inbound/outbound siblings here —
        // `reconcileDrives` owns the day's Drive to / Drive home / Drive to B from A chain.
        let placement = DriveTimePlacement.resolved()
        if placement == .partOfEvent,
           let travel, travel.minutes > 0,
           !HomeGapLogic.looksLikeHome(place) {
            var inbound = travel
            inbound.returnMinutes = nil
            let block = TravelEstimator.calendarBlock(
                start: draft.arrivalTarget,
                end: draft.end,
                travel: inbound,
                extraBeforeMinutes: draft.extraBeforeMinutes,
                extraAfterMinutes: draft.extraAfterMinutes
            )
            event.startDate = block.start
            event.endDate = block.end
        } else {
            event.startDate = draft.arrivalTarget
            event.endDate = draft.end
        }
        event.timeZone = TimeZone.current
        event.location = place.isEmpty ? nil : place
        if let latitude = draft.locationLatitude,
           let longitude = draft.locationLongitude,
           !place.isEmpty {
            let structured = EKStructuredLocation(title: place)
            structured.geoLocation = CLLocation(latitude: latitude, longitude: longitude)
            event.structuredLocation = structured
        }
        event.notes = EventNotes.body(
            forOriginal: draft.sourceText,
            details: TravelEstimator.noteLines(
                appointmentStart: draft.start,
                appointmentEnd: draft.end,
                travel: travel,
                place: place,
                extraBeforeMinutes: draft.extraBeforeMinutes,
                arriveBy: draft.arriveBy
            ) + draft.details
        )
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarStoreError.saveFailed(error.localizedDescription)
        }

        lastSavedCalendar = calendar
        store.refreshSourcesIfNecessary()
        let identifier = event.eventIdentifier
        let fetched = identifier.flatMap { store.event(withIdentifier: $0) }
        guard CalendarPersistCheck.accepted(
            eventIdentifier: identifier,
            access: access,
            canFetch: fetched != nil
        ) else {
            throw CalendarStoreError.saveFailed(
                ScedraString("Calendar did not accept this appointment. Check Calendar access in Settings.")
            )
        }
        // Write-only cannot read the event back; the in-memory object is only
        // used after EventKit assigned a real identifier (the save committed).
        let committed = fetched ?? event
        let savedID = stableID(for: committed)
        retainedEvents[savedID] = committed
        forgottenIDs.remove(savedID)
        OriginalTextStore.save(draft.sourceText, for: savedID, imageURL: draft.originalImageURL)
        PlaceMemory.remember(
            title: draft.calendarTitle,
            location: draft.locationToSave,
            latitude: draft.locationLatitude,
            longitude: draft.locationLongitude
        )
        reloadTodayAfterSave(committed)
        loadSelectedDay()
        var seeded = DriveChainEstimates()
        if let travel, travel.minutes > 0 {
            seeded.fromHome[savedID] = travel.minutes
        }
        if let back = travel?.routedReturnMinutes, back > 0 {
            seeded.toHome[savedID] = back
        }
        // Appointment first, then the same day-level chain Calendar refresh uses.
        await reconcileDrives(on: committed.startDate, seeded: seeded)
        if !Calendar.current.isDate(committed.startDate, inSameDayAs: committed.endDate) {
            await reconcileDrives(on: committed.endDate, seeded: seeded)
        }
        if TodayWindow.contains(start: committed.startDate, end: committed.endDate) {
            loadToday()
        }
        loadSelectedDay()
        savedAppointmentHandler?()
    }

    /// True when this device already has an appointment Scedra wrote (`Added by Scedra`).
    func hasScedraCreatedEvent() -> Bool {
        if OriginalTextStore.hasAny { return true }
        if (today + selectedDayEvents).contains(where: { $0.savedInfo.isScedraEvent }) {
            return true
        }
        guard access == .full else { return false }
        let calendar = Calendar.current
        let now = Date()
        guard let start = calendar.date(byAdding: .year, value: -2, to: now),
              let end = calendar.date(byAdding: .year, value: 1, to: now) else {
            return false
        }
        let predicate = store.predicateForEvents(
            withStart: start,
            end: end,
            calendars: calendarsForTodayQuery()
        )
        return store.events(matching: predicate).contains { event in
            (event.notes ?? "").contains(EventNotes.marker)
        }
    }

    private func inferredNeighbors(for item: TodayItem, travel: TravelEstimate) -> DriveNeighborContext {
        let candidates = (today + selectedDayEvents)
            .filter { !$0.isAllDay && !$0.isDriveEvent }
            .sorted { $0.officialStart < $1.officialStart }
        let previous = candidates.last {
            $0.occurrenceKey != item.occurrenceKey && $0.officialStart < item.officialStart
        }
        let next = candidates.first {
            $0.occurrenceKey != item.occurrenceKey && $0.officialStart > item.officialStart
        }
        let homeLabel = (UserDefaults.standard.string(forKey: PlaceResolver.homeAddressKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return DriveTimeLogic.neighborsForExistingReturn(
            previousPlace: previous?.placeLabel,
            homeIsSet: PlaceResolver.isHomeAddressSet,
            homeLabel: homeLabel,
            nextPlace: next?.placeLabel,
            travel: travel
        )
    }

    /// Places a task block on Apple Calendar. Updates the existing EventKit event when
    /// `existingIdentifier` is set so edits do not create a duplicate.
    func upsertTaskEvent(
        existingIdentifier: String?,
        title: String,
        start: Date,
        end: Date,
        location: String,
        notes: String
    ) async throws -> String {
        guard end > start else {
            throw CalendarStoreError.missingDateOrTime
        }
        if access != .full && access != .writeOnly {
            await requestAccessAndLoad()
        }
        guard access == .full || access == .writeOnly else {
            throw CalendarStoreError.noAccess
        }

        let event: EKEvent
        if let existingIdentifier, !existingIdentifier.isEmpty,
           let existing = eventForTaskIdentifier(existingIdentifier) {
            event = existing
        } else {
            let calendar = try calendarForSaving()
            event = EKEvent(eventStore: store)
            event.calendar = calendar
            lastSavedCalendar = calendar
        }

        event.title = title
        event.startDate = start
        event.endDate = end
        event.timeZone = TimeZone.current
        let place = location.trimmingCharacters(in: .whitespacesAndNewlines)
        event.location = place.isEmpty ? nil : place
        event.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarStoreError.saveFailed(error.localizedDescription)
        }

        lastSavedCalendar = event.calendar ?? lastSavedCalendar
        store.refreshSourcesIfNecessary()
        let identifier = event.eventIdentifier
        let fetched = identifier.flatMap { store.event(withIdentifier: $0) }
        guard CalendarPersistCheck.accepted(
            eventIdentifier: identifier,
            access: access,
            canFetch: fetched != nil
        ) else {
            throw CalendarStoreError.saveFailed(
                ScedraString("Calendar did not accept this appointment. Check Calendar access in Settings.")
            )
        }
        let committed = fetched ?? event
        let savedID = stableID(for: committed)
        retainedEvents[savedID] = committed
        forgottenIDs.remove(savedID)
        reloadTodayAfterSave(committed)
        loadSelectedDay()
        return savedID
    }

    /// User-initiated edit on the event she tapped. Saves the existing EventKit event
    /// (`commit: true`). Never silently moves a different event.
    func updateEventTimes(
        _ item: TodayItem,
        start: Date,
        end: Date,
        title: String? = nil,
        location: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) async throws {
        let prepared = try EventScheduleEdit.prepare(
            item: item,
            officialStart: start,
            officialEnd: end,
            title: title,
            location: location
        )
        if access != .full && access != .writeOnly {
            await requestAccessAndLoad()
        }
        guard access == .full || access == .writeOnly else {
            throw CalendarStoreError.noAccess
        }
        store.refreshSourcesIfNecessary()
        guard let event = eventMatching(item) else {
            throw CalendarStoreError.saveFailed(
                ScedraString("Couldn’t find “\(item.title)” in Calendar. It may already be gone.")
            )
        }
        guard event.calendar?.allowsContentModifications ?? true else {
            let name = event.calendar?.title ?? ScedraString("that calendar")
            throw CalendarStoreError.saveFailed(
                ScedraString("“\(item.title)” is in “\(name)”, which is read-only. Edit it at the source.")
            )
        }

        event.title = prepared.title
        event.startDate = prepared.start
        event.endDate = prepared.end
        event.isAllDay = false
        event.timeZone = TimeZone.current
        event.location = prepared.location
        if let latitude, let longitude, let place = prepared.location {
            let structured = EKStructuredLocation(title: place)
            structured.geoLocation = CLLocation(latitude: latitude, longitude: longitude)
            event.structuredLocation = structured
        } else if prepared.location == nil {
            event.structuredLocation = nil
        }
        if let notes = prepared.notes {
            event.notes = notes
        }

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarStoreError.saveFailed(error.localizedDescription)
        }

        lastSavedCalendar = event.calendar ?? lastSavedCalendar
        store.refreshSourcesIfNecessary()
        let identifier = event.eventIdentifier
        let fetched = identifier.flatMap { store.event(withIdentifier: $0) }
        guard CalendarPersistCheck.accepted(
            eventIdentifier: identifier,
            access: access,
            canFetch: fetched != nil
        ) else {
            throw CalendarStoreError.saveFailed(
                ScedraString("Calendar did not accept this appointment. Check Calendar access in Settings.")
            )
        }
        let committed = fetched ?? event
        let savedID = stableID(for: committed)
        retainedEvents[savedID] = committed
        forgottenIDs.remove(savedID)
        PlaceMemory.remember(
            title: prepared.title,
            location: prepared.location ?? "",
            latitude: latitude ?? item.latitude,
            longitude: longitude ?? item.longitude
        )
        reloadTodayAfterSave(committed)
        loadSelectedDay()
        await reconcileDrives(on: committed.startDate)
        if !Calendar.current.isDate(committed.startDate, inSameDayAs: committed.endDate) {
            await reconcileDrives(on: committed.endDate)
        }
        loadSelectedDay()
    }

    /// Removes only the EventKit event Scedra created for a task.
    func deleteTaskEvent(identifier: String) async throws {
        guard !identifier.isEmpty else { return }
        if access != .full && access != .writeOnly {
            await requestAccessAndLoad()
        }
        guard access == .full || access == .writeOnly else {
            throw CalendarStoreError.noAccess
        }
        store.refreshSourcesIfNecessary()
        guard let event = eventForTaskIdentifier(identifier) else {
            forgottenIDs.insert(identifier)
            today.removeAll { $0.id == identifier }
            selectedDayEvents.removeAll { $0.id == identifier }
            recentlySavedToday.removeAll { $0.id == identifier }
            retainedEvents.removeValue(forKey: identifier)
            return
        }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarStoreError.deleteFailed(error.localizedDescription)
        }
        let item = todayItem(from: event)
        try? removeLinkedDriveEvent(for: item, eventID: identifier)
        forget(item, eventID: identifier)
        notifyDeletedEventIDs([identifier])
        store.refreshSourcesIfNecessary()
        loadToday()
        loadSelectedDay()
    }

    private func eventForTaskIdentifier(_ identifier: String) -> EKEvent? {
        if let event = store.event(withIdentifier: identifier) { return event }
        if let event = store.calendarItem(withIdentifier: identifier) as? EKEvent { return event }
        return retainedEvents[identifier]
    }

    /// Writes travel onto the appointment notes (and Settings padding for new Scedra events).
    /// Does not write per-event Drive to / Drive home siblings — `reconcileDrives`
    /// owns the day chain after Confirm and Calendar refresh.
    /// Existing Apple Calendar events keep EventKit start/end untouched.
    /// Never moves a different appointment — overlaps stay as alerts.
    func updateTravelNotes(
        for item: TodayItem,
        travel: TravelEstimate,
        latitude: Double? = nil,
        longitude: Double? = nil,
        neighbors: DriveNeighborContext? = nil
    ) throws {
        let write = DriveTimeLogic.write(
            item: item,
            travel: travel,
            neighbors: neighbors ?? inferredNeighbors(for: item, travel: travel),
            placement: DriveTimePlacement.resolved(),
            existingDriveEventIdentifier: linkedDriveIdentifier(for: item, leg: .inbound),
            existingReturnDriveEventIdentifier: linkedDriveIdentifier(for: item, leg: .onward)
        )
        if let event = eventMatching(item), access == .full || access == .writeOnly {
            event.notes = write.notes
            if write.writesOriginalTimes {
                event.startDate = write.eventStart
                event.endDate = write.eventEnd
            }
            if let latitude, let longitude {
                let title = event.location ?? item.placeLabel ?? item.title
                let structured = EKStructuredLocation(title: title)
                structured.geoLocation = CLLocation(latitude: latitude, longitude: longitude)
                event.structuredLocation = structured
            }
            try store.save(event, span: .thisEvent, commit: true)
        }
        func patched(_ existing: TodayItem) -> TodayItem {
            TodayItem(
                id: existing.id,
                title: existing.title,
                start: write.eventStart,
                end: write.eventEnd,
                isAllDay: existing.isAllDay,
                location: existing.location,
                notes: write.notes,
                latitude: latitude ?? existing.latitude,
                longitude: longitude ?? existing.longitude
            )
        }
        if let index = recentlySavedToday.firstIndex(where: { $0.id == item.id || sameAppointment($0, item) }) {
            recentlySavedToday[index] = patched(recentlySavedToday[index])
        }
        if let index = today.firstIndex(where: { $0.id == item.id || sameAppointment($0, item) }) {
            today[index] = patched(today[index])
        }
        if let index = selectedDayEvents.firstIndex(where: { $0.id == item.id || sameAppointment($0, item) }) {
            selectedDayEvents[index] = patched(selectedDayEvents[index])
        }
        refreshHomeGapNotifications()
    }

    func delete(_ item: TodayItem) throws {
        guard access == .full || access == .writeOnly else {
            throw CalendarStoreError.noAccess
        }
        store.refreshSourcesIfNecessary()
        guard let event = eventMatching(item) else {
            if access != .full {
                throw CalendarStoreError.deleteFailed(
                    ScedraString("Full Calendar access needed to delete. Turn it on in Settings.")
                )
            }
            throw CalendarStoreError.deleteFailed(
                ScedraString("Couldn’t find “\(item.title)” in Calendar. It may already be gone.")
            )
        }
        guard event.calendar?.allowsContentModifications ?? true else {
            let name = event.calendar?.title ?? ScedraString("that calendar")
            throw CalendarStoreError.deleteFailed(
                ScedraString("“\(item.title)” is in “\(name)”, which is read-only. Delete it at the source.")
            )
        }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarStoreError.deleteFailed(error.localizedDescription)
        }
        let eventID = stableID(for: event)
        try? removeLinkedDriveEvent(for: item, eventID: eventID)
        forget(item, eventID: eventID)
        notifyDeletedEventIDs([item.id, eventID])
        store.refreshSourcesIfNecessary()
        loadToday()
        loadSelectedDay()
        let day = item.start
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reconcileDrives(on: day)
        }
    }

    /// Timed events occupancy can reason about. Merges EventKit queries with
    /// in-memory Today / selected-day lists so a stale query cannot hide a block.
    func occupancyItems(from start: Date, dayCount: Int) -> [TodayItem] {
        let calendar = Calendar.current
        let day0 = calendar.startOfDay(for: start)
        var items: [TodayItem] = []
        var seen = Set<String>()
        func append(_ extra: [TodayItem]) {
            for item in extra where !item.isAllDay {
                if seen.insert(item.occurrenceKey).inserted {
                    items.append(item)
                }
            }
        }
        for offset in 0..<max(dayCount, 0) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: day0) else { continue }
            append(events(on: day))
        }
        append(today)
        append(selectedDayEvents)
        return items.sorted { $0.start < $1.start }
    }

    /// `true` / `false` when EventKit can answer. `nil` when we must not guess
    /// (write-only / no access) — missing-task cleanup skips those.
    func eventExists(_ identifier: String) -> Bool? {
        let id = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        if forgottenIDs.contains(id) { return false }
        switch access {
        case .full:
            if store.event(withIdentifier: id) != nil { return true }
            if store.calendarItem(withIdentifier: id) as? EKEvent != nil { return true }
            if retainedEvents[id] != nil { return true }
            return false
        case .writeOnly:
            if retainedEvents[id] != nil { return true }
            if recentlySavedToday.contains(where: { $0.id == id }) { return true }
            if today.contains(where: { $0.id == id }) { return true }
            if selectedDayEvents.contains(where: { $0.id == id }) { return true }
            return nil
        default:
            return nil
        }
    }

    private func notifyDeletedEventIDs(_ identifiers: [String]) {
        let ids = identifiers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        deletedEventIDsHandler?(ids)
    }

    /// Same day-level chain Calendar refresh uses after Confirm / edits / delete.
    func reconcileDrives(on day: Date, seeded: DriveChainEstimates = DriveChainEstimates()) async {
        await CalendarTravelBackfill.reconcileDriveChain(
            items: dayItemsForDriveChain(on: day),
            using: self,
            seeded: seeded
        )
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            await LeaveToNavigatePlanner.refresh(using: self)
        }
    }

    /// Appointments plus every Scedra drive sibling EventKit or memory still holds.
    func dayItemsForDriveChain(on day: Date) -> [TodayItem] {
        occupancyItems(from: Calendar.current.startOfDay(for: day), dayCount: 1)
            + driveSiblings(on: day)
    }

    func applyDriveChain(_ plan: DriveChainPlan, calendar: EKCalendar?, covering day: Date? = nil) throws {
        let sweepDay = day ?? plan.legs.first?.start ?? plan.legs.first?.end
        let removing = Set(
            plan.removeIdentifiers
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        // Never wipe the day's drives first. A throttled Maps pass must leave
        // the last good "Drive to B from A" on the calendar.
        for identifier in removing {
            try? deleteLinkedEvent(identifier: identifier)
            DriveEventLinkStore.remove(driveID: identifier)
        }
        var kept = Set<String>()
        for leg in plan.legs {
            let notes = DriveTimeLogic.driveNotes(
                chainKey: leg.chainKey,
                fromID: leg.fromID,
                toID: leg.toID,
                linkedAppointmentID: leg.toID ?? leg.fromID,
                leg: leg.driveLeg
            )
            let savedID = try upsertLinkedEvent(
                existingIdentifier: leg.existingIdentifier,
                title: leg.title,
                start: leg.start,
                end: leg.end,
                location: leg.location,
                notes: notes,
                calendar: calendar
            )
            kept.insert(savedID)
            if let existing = leg.existingIdentifier {
                kept.insert(existing)
            }
            DriveEventLinkStore.save(savedID, forChainKey: leg.chainKey)
            if leg.kind == .fromHome, let toID = leg.toID {
                DriveEventLinkStore.save(savedID, for: toID, leg: .inbound)
            }
            if leg.kind == .toHome, let fromID = leg.fromID {
                DriveEventLinkStore.save(savedID, for: fromID, leg: .onward)
            }
        }
        if let sweepDay {
            removeStaleDriveSiblings(
                on: sweepDay,
                keeping: kept,
                removing: removing,
                writtenKeys: Set(plan.legs.map(\.chainKey))
            )
        }
    }

    private func removeStaleDriveSiblings(
        on day: Date,
        keeping kept: Set<String>,
        removing: Set<String>,
        writtenKeys: Set<String>
    ) {
        store.refreshSourcesIfNecessary()
        for event in scedraDriveEKEvents(on: day) {
            let id = stableID(for: event)
            if kept.contains(id) { continue }
            if removing.contains(id) {
                removeDriveEKEvent(event)
                continue
            }
            let key = DriveTimeLogic.chainKey(fromNotes: event.notes)
            if let key, writtenKeys.contains(key) {
                removeDriveEKEvent(event)
                continue
            }
            if key == nil {
                removeDriveEKEvent(event)
            }
        }
        for sibling in driveSiblings(on: day) where !kept.contains(sibling.id) {
            if removing.contains(sibling.id) {
                removeDriveSibling(sibling)
                continue
            }
            let key = DriveTimeLogic.chainKey(fromNotes: sibling.notes)
            if let key, writtenKeys.contains(key) {
                removeDriveSibling(sibling)
                continue
            }
            if key == nil {
                removeDriveSibling(sibling)
            }
        }
    }

    private func scedraDriveEKEvents(on day: Date) -> [EKEvent] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).filter { event in
            guard !event.isAllDay else { return false }
            return DriveTimeLogic.isScedraLinkedDrive(
                title: event.title ?? "",
                notes: event.notes,
                identifier: stableID(for: event)
            )
        }
    }

    private func removeDriveEKEvent(_ event: EKEvent) {
        let id = stableID(for: event)
        if event.calendar?.allowsContentModifications ?? true {
            do {
                try store.remove(event, span: .thisEvent, commit: true)
                forgottenIDs.insert(id)
                forgottenIDs.insert(event.eventIdentifier ?? id)
                retainedEvents.removeValue(forKey: id)
            } catch {
                DriveEventLinkStore.remove(driveID: id)
                return
            }
        }
        DriveEventLinkStore.remove(driveID: id)
        today.removeAll { $0.id == id }
        selectedDayEvents.removeAll { $0.id == id }
        recentlySavedToday.removeAll { $0.id == id }
    }

    private func removeDriveSibling(_ item: TodayItem) {
        let event = eventMatching(item)
            ?? eventForTaskIdentifier(item.id)
            ?? eventMatchingDriveNotes(item.id)
            ?? eventMatchingDriveWindow(item)
        if let event {
            removeDriveEKEvent(event)
            return
        }
        DriveEventLinkStore.remove(driveID: item.id)
        today.removeAll { $0.id == item.id || sameAppointment($0, item) }
        selectedDayEvents.removeAll { $0.id == item.id || sameAppointment($0, item) }
        recentlySavedToday.removeAll { $0.id == item.id || sameAppointment($0, item) }
    }

    private func eventMatchingDriveWindow(_ item: TodayItem) -> EKEvent? {
        guard access == .full else { return nil }
        store.refreshSourcesIfNecessary()
        let predicate = store.predicateForEvents(
            withStart: item.start.addingTimeInterval(-120),
            end: item.end.addingTimeInterval(120),
            calendars: calendarsForTodayQuery()
        )
        return store.events(matching: predicate).first { event in
            DriveTimeLogic.isScedraLinkedDrive(
                title: event.title ?? "",
                notes: event.notes,
                identifier: stableID(for: event)
            )
            && (event.title ?? "Untitled") == item.title
            && abs(event.startDate.timeIntervalSince(item.start)) < 2
            && abs(event.endDate.timeIntervalSince(item.end)) < 2
        }
    }

    private func writeLinkedDriveEvent(
        _ plan: DriveTimePlan,
        appointmentID: String,
        calendar: EKCalendar?
    ) throws {
        if let remove = plan.removeDriveEventIdentifier {
            try? deleteLinkedEvent(identifier: remove)
            DriveEventLinkStore.remove(for: appointmentID, leg: .inbound)
        }
        if let remove = plan.removeReturnDriveEventIdentifier {
            try? deleteLinkedEvent(identifier: remove)
            DriveEventLinkStore.remove(for: appointmentID, leg: .onward)
        }
        if let drive = plan.driveEvent {
            let savedID = try upsertLinkedEvent(
                existingIdentifier: drive.existingIdentifier,
                title: drive.title,
                start: drive.start,
                end: drive.end,
                location: drive.location,
                notes: DriveTimeLogic.driveNotes(forAppointment: appointmentID, leg: .inbound),
                calendar: calendar
            )
            DriveEventLinkStore.save(savedID, for: appointmentID, leg: .inbound)
        }
        if let back = plan.returnDriveEvent {
            let savedID = try upsertLinkedEvent(
                existingIdentifier: back.existingIdentifier,
                title: back.title,
                start: back.start,
                end: back.end,
                location: back.location,
                notes: DriveTimeLogic.driveNotes(forAppointment: appointmentID, leg: .onward),
                calendar: calendar
            )
            DriveEventLinkStore.save(savedID, for: appointmentID, leg: .onward)
        }
    }

    private func syncDriveEventAfterTimeChange(
        appointmentID: String,
        officialStart: Date,
        officialEnd: Date,
        item: TodayItem,
        calendar: EKCalendar?,
        title: String? = nil,
        location: String? = nil
    ) throws {
        let source = DriveTimeLogic.source(for: item)
        let placement = DriveTimePlacement.resolved()
        if source == .newScedraEvent, placement == .partOfEvent {
            if let existing = linkedDriveIdentifier(for: item, leg: .inbound)
                ?? DriveEventLinkStore.identifier(for: appointmentID, leg: .inbound) {
                try? deleteLinkedEvent(identifier: existing)
                DriveEventLinkStore.remove(for: appointmentID, leg: .inbound)
            }
        }
        let place = location ?? item.placeLabel ?? ""
        if let driveID = linkedDriveIdentifier(for: item, leg: .inbound)
            ?? DriveEventLinkStore.identifier(for: appointmentID, leg: .inbound),
           let drive = eventForTaskIdentifier(driveID) {
            let duration = drive.endDate.timeIntervalSince(drive.startDate)
            if duration > 0 {
                drive.endDate = officialStart
                drive.startDate = officialStart.addingTimeInterval(-duration)
                drive.title = DriveTimeLogic.driveEventTitle(
                    place: place,
                    appointmentTitle: title ?? item.title
                )
                drive.location = EventScheduleEdit.normalizedLocation(place)
                drive.calendar = drive.calendar ?? calendar
                try store.save(drive, span: .thisEvent, commit: true)
                DriveEventLinkStore.save(driveID, for: appointmentID, leg: .inbound)
                retainedEvents[driveID] = drive
            }
        }
        if let backID = linkedDriveIdentifier(for: item, leg: .onward)
            ?? DriveEventLinkStore.identifier(for: appointmentID, leg: .onward),
           let back = eventForTaskIdentifier(backID) {
            let duration = back.endDate.timeIntervalSince(back.startDate)
            guard duration > 0 else { return }
            back.startDate = officialEnd
            back.endDate = officialEnd.addingTimeInterval(duration)
            back.title = DriveTimeLogic.onwardEventTitle(
                from: place,
                goingHome: PlaceResolver.isHomeAddressSet,
                mode: item.appointmentTravelMode
            )
            let homeLabel = (UserDefaults.standard.string(forKey: PlaceResolver.homeAddressKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            back.location = EventScheduleEdit.normalizedLocation(
                PlaceResolver.isHomeAddressSet
                    ? (homeLabel.isEmpty ? ScedraString("Home") : homeLabel)
                    : place
            )
            back.calendar = back.calendar ?? calendar
            try store.save(back, span: .thisEvent, commit: true)
            DriveEventLinkStore.save(backID, for: appointmentID, leg: .onward)
            retainedEvents[backID] = back
        }
    }

    private func linkedDriveIdentifier(for item: TodayItem, leg: DriveLeg = .inbound) -> String? {
        if let stored = DriveEventLinkStore.identifier(for: item.id, leg: leg) {
            return stored
        }
        let around = leg == .inbound ? item.officialStart : item.officialEnd
        return findDriveEventIdentifier(forAppointment: item.id, around: around, leg: leg)
    }

    private func findDriveEventIdentifier(
        forAppointment appointmentID: String,
        around start: Date,
        leg: DriveLeg = .inbound
    ) -> String? {
        guard !appointmentID.isEmpty, access == .full || access == .writeOnly else { return nil }
        let searchStart = start.addingTimeInterval(-EventMatchLogic.paddingSlop)
        let searchEnd = start.addingTimeInterval(EventMatchLogic.paddingSlop)
        let predicate = store.predicateForEvents(
            withStart: searchStart,
            end: searchEnd,
            calendars: calendarsForTodayQuery()
        )
        return store.events(matching: predicate).first { event in
            DriveTimeLogic.appointmentIdentifier(fromDriveNotes: event.notes) == appointmentID
                && DriveTimeLogic.driveLeg(fromNotes: event.notes) == leg
        }.flatMap { event in
            let id = stableID(for: event)
            return id.isEmpty ? nil : id
        }
    }

    private func upsertLinkedEvent(
        existingIdentifier: String?,
        title: String,
        start: Date,
        end: Date,
        location: String,
        notes: String,
        calendar: EKCalendar?
    ) throws -> String {
        let event: EKEvent
        if let existingIdentifier, !existingIdentifier.isEmpty,
           let existing = eventForTaskIdentifier(existingIdentifier) {
            event = existing
            let place = location.trimmingCharacters(in: .whitespacesAndNewlines)
            let sameTitle = (existing.title ?? "") == title
            let sameStart = abs(existing.startDate.timeIntervalSince(start)) < 1
            let sameEnd = abs(existing.endDate.timeIntervalSince(end)) < 1
            let samePlace = (existing.location ?? "") == place
            let sameNotes = (existing.notes ?? "") == notes
            if sameTitle && sameStart && sameEnd && samePlace && sameNotes {
                let id = stableID(for: existing)
                retainedEvents[id] = existing
                forgottenIDs.remove(id)
                return id
            }
        } else {
            event = EKEvent(eventStore: store)
            event.calendar = try calendar ?? calendarForSaving()
        }
        event.title = title
        event.startDate = start
        event.endDate = end
        event.timeZone = TimeZone.current
        let place = location.trimmingCharacters(in: .whitespacesAndNewlines)
        event.location = place.isEmpty ? nil : place
        event.notes = notes
        try store.save(event, span: .thisEvent, commit: true)
        let identifier = event.eventIdentifier
        let fetched = identifier.flatMap { store.event(withIdentifier: $0) }
        let committed = fetched ?? event
        let savedID = stableID(for: committed)
        retainedEvents[savedID] = committed
        forgottenIDs.remove(savedID)
        let item = todayItem(from: committed)
        recentlySavedToday.removeAll { $0.id == item.id || sameAppointment($0, item) }
        recentlySavedToday.append(item)
        return savedID
    }

    private func deleteLinkedEvent(identifier: String) throws {
        guard !identifier.isEmpty else { return }
        guard let event = eventForTaskIdentifier(identifier) ?? eventMatchingDriveNotes(identifier) else {
            DriveEventLinkStore.remove(driveID: identifier)
            retainedEvents.removeValue(forKey: identifier)
            return
        }
        try store.remove(event, span: .thisEvent, commit: true)
        forgottenIDs.insert(identifier)
        forgottenIDs.insert(stableID(for: event))
        retainedEvents.removeValue(forKey: identifier)
        retainedEvents.removeValue(forKey: stableID(for: event))
        today.removeAll { $0.id == identifier || $0.id == stableID(for: event) }
        selectedDayEvents.removeAll { $0.id == identifier || $0.id == stableID(for: event) }
        recentlySavedToday.removeAll { $0.id == identifier || $0.id == stableID(for: event) }
    }

    private func eventMatchingDriveNotes(_ identifier: String) -> EKEvent? {
        let id = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, access == .full else { return nil }
        store.refreshSourcesIfNecessary()
        let start = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let end = Calendar.current.date(byAdding: .day, value: 400, to: Date()) ?? Date()
        let predicate = store.predicateForEvents(
            withStart: start,
            end: end,
            calendars: calendarsForTodayQuery()
        )
        return store.events(matching: predicate).first { event in
            stableID(for: event) == id
                || event.eventIdentifier == id
                || event.calendarItemIdentifier == id
                || (event.notes ?? "").contains(id)
        }
    }

    private func removeLinkedDriveEvent(for item: TodayItem, eventID: String) throws {
        if item.isDriveEvent {
            if let appointmentID = DriveTimeLogic.appointmentIdentifier(fromDriveNotes: item.notes)
                ?? DriveEventLinkStore.appointmentID(forDrive: eventID)
                ?? DriveEventLinkStore.appointmentID(forDrive: item.id) {
                let leg = DriveTimeLogic.driveLeg(fromNotes: item.notes)
                DriveEventLinkStore.remove(for: appointmentID, leg: leg)
            }
            return
        }
        var driveIDs: [String] = []
        for leg in [DriveLeg.inbound, DriveLeg.onward] {
            let around = leg == .inbound ? item.start : item.end
            if let driveID = DriveEventLinkStore.identifier(for: eventID, leg: leg)
                ?? DriveEventLinkStore.identifier(for: item.id, leg: leg)
                ?? findDriveEventIdentifier(forAppointment: eventID, around: around, leg: leg) {
                driveIDs.append(driveID)
            }
        }
        for (key, driveID) in DriveEventLinkStore.allChainEntries()
        where key.contains(eventID) || key.contains(item.id) {
            driveIDs.append(driveID)
        }
        for driveID in Set(driveIDs) {
            try? deleteLinkedEvent(identifier: driveID)
        }
        DriveEventLinkStore.remove(for: eventID)
        DriveEventLinkStore.remove(for: item.id)
    }

    private func eventMatching(_ item: TodayItem) -> EKEvent? {
        if let event = store.event(withIdentifier: item.id),
           EventMatchLogic.isShownOccurrence(
            eventStart: event.startDate,
            itemStart: item.start,
            isRecurring: event.hasRecurrenceRules
           ) {
            return event
        }
        if let event = store.calendarItem(withIdentifier: item.id) as? EKEvent,
           EventMatchLogic.isShownOccurrence(
            eventStart: event.startDate,
            itemStart: item.start,
            isRecurring: event.hasRecurrenceRules
           ) {
            return event
        }
        if let retained = retainedEvents[item.id],
           EventMatchLogic.isShownOccurrence(
            eventStart: retained.startDate,
            itemStart: item.start,
            isRecurring: retained.hasRecurrenceRules
           ) {
            return retained
        }
        if let retained = retainedEvents.values.first(where: {
            EventMatchLogic.isSameEvent(
                itemTitle: item.title,
                itemStart: item.start,
                itemEnd: item.end,
                eventTitle: $0.title ?? "Untitled",
                eventStart: $0.startDate,
                eventEnd: $0.endDate
            )
        }) {
            return retained
        }

        let searchStart = item.start.addingTimeInterval(-EventMatchLogic.paddingSlop)
        let searchEnd = item.end.addingTimeInterval(EventMatchLogic.paddingSlop)
        let predicate = store.predicateForEvents(
            withStart: searchStart,
            end: searchEnd,
            calendars: calendarsForTodayQuery()
        )
        let candidates = store.events(matching: predicate).filter { candidate in
            EventMatchLogic.isSameEvent(
                itemTitle: item.title,
                itemStart: item.start,
                itemEnd: item.end,
                eventTitle: candidate.title ?? "Untitled",
                eventStart: candidate.startDate,
                eventEnd: candidate.endDate
            ) && EventMatchLogic.isShownOccurrence(
                eventStart: candidate.startDate,
                itemStart: item.start,
                isRecurring: candidate.hasRecurrenceRules
            )
        }
        if candidates.count == 1 { return candidates[0] }
        return candidates.min {
            abs($0.startDate.timeIntervalSince(item.start)) < abs($1.startDate.timeIntervalSince(item.start))
        }
    }

    /// Reloads EventKit, then keeps the just-saved event visible on Today / the
    /// Calendar tab even when the store query is briefly stale or write-only.
    private func reloadTodayAfterSave(_ event: EKEvent) {
        let item = todayItem(from: event)
        recentlySavedToday.removeAll { $0.id == item.id || sameAppointment($0, item) }
        recentlySavedToday.append(item)
        loadToday()
    }

    private func mergeRecentlySavedToday() {
        for item in recentlySavedToday where TodayWindow.contains(start: item.start, end: item.end) {
            if !today.contains(where: { $0.id == item.id || sameAppointment($0, item) }) {
                today.append(item)
            }
        }
        today.sort { $0.start < $1.start }
        recentlySavedToday.removeAll { pending in
            today.contains(where: { $0.id == pending.id || sameAppointment($0, pending) })
                && store.event(withIdentifier: pending.id) != nil
        }
    }

    /// Prefer Apple’s default calendar, then any writable calendar, then create one.
    /// Write-only cannot list or create calendars — do not invent a hidden "Scedra"
    /// calendar the user will never see in Apple Calendar.
    private func calendarForSaving() throws -> EKCalendar {
        if let calendar = store.defaultCalendarForNewEvents, calendar.allowsContentModifications {
            return calendar
        }
        if let calendar = lastSavedCalendar, calendar.allowsContentModifications {
            return calendar
        }
        if access == .full,
           let calendar = store.calendars(for: .event).first(where: { $0.allowsContentModifications }) {
            return calendar
        }
        if access == .full {
            return try makeWritableCalendar()
        }
        throw CalendarStoreError.noCalendar
    }

    /// Apple: recreate the store after the user grants access, or writes miss.
    private func resetStore() {
        if let observer = storeChangedObserver {
            NotificationCenter.default.removeObserver(observer)
            storeChangedObserver = nil
        }
        let previousID = lastSavedCalendar?.calendarIdentifier
        store = EKEventStore()
        if let previousID {
            lastSavedCalendar = store.calendar(withIdentifier: previousID)
        }
        listenForStoreChanges()
    }

    private func makeWritableCalendar() throws -> EKCalendar {
        guard let source = sourceForNewCalendar() else {
            throw CalendarStoreError.noCalendar
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "Scedra"
        calendar.source = source
        do {
            try store.saveCalendar(calendar, commit: true)
            return calendar
        } catch {
            throw CalendarStoreError.saveFailed(error.localizedDescription)
        }
    }

    private func sourceForNewCalendar() -> EKSource? {
        let sources = store.sources
        if let local = sources.first(where: { $0.sourceType == .local }) {
            return local
        }
        if let calDAV = sources.first(where: { $0.sourceType == .calDAV }) {
            return calDAV
        }
        return store.defaultCalendarForNewEvents?.source ?? sources.first
    }

    private func calendarsForTodayQuery() -> [EKCalendar]? {
        var calendars = store.calendars(for: .event)
        for extra in [store.defaultCalendarForNewEvents, lastSavedCalendar] {
            if let extra,
               !calendars.contains(where: { $0.calendarIdentifier == extra.calendarIdentifier }) {
                calendars.append(extra)
            }
        }
        return calendars.isEmpty ? nil : calendars
    }

    private func todayItem(from event: EKEvent) -> TodayItem {
        let geo = event.structuredLocation?.geoLocation
        return TodayItem(
            id: stableID(for: event),
            title: event.title ?? "Untitled",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            location: event.location,
            notes: event.notes,
            latitude: geo?.coordinate.latitude,
            longitude: geo?.coordinate.longitude
        )
    }

    private func stableID(for event: EKEvent) -> String {
        for candidate in [event.eventIdentifier, event.calendarItemIdentifier] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return "pending-\(event.title ?? "event")-\(event.startDate.timeIntervalSince1970)"
    }

    private func forget(_ item: TodayItem, eventID: String) {
        forgottenIDs.insert(item.id)
        forgottenIDs.insert(eventID)
        forgottenAppointments.append(
            ForgottenAppointment(title: item.title, start: item.start, end: item.end)
        )
        recentlySavedToday.removeAll { $0.id == item.id || sameAppointment($0, item) }
        retainedEvents.removeValue(forKey: item.id)
        retainedEvents.removeValue(forKey: eventID)
        OriginalTextStore.remove(item.id)
        OriginalTextStore.remove(eventID)
        DriveEventLinkStore.remove(for: item.id)
        DriveEventLinkStore.remove(for: eventID)
        today.removeAll { $0.id == item.id || sameAppointment($0, item) }
        selectedDayEvents.removeAll { $0.id == item.id || sameAppointment($0, item) }
    }

    private func isForgotten(_ item: TodayItem) -> Bool {
        if forgottenIDs.contains(item.id) { return true }
        return forgottenAppointments.contains { forgotten in
            EventMatchLogic.isSameEvent(
                itemTitle: forgotten.title,
                itemStart: forgotten.start,
                itemEnd: forgotten.end,
                eventTitle: item.title,
                eventStart: item.start,
                eventEnd: item.end
            )
        }
    }

    private func sameAppointment(_ lhs: TodayItem, _ rhs: TodayItem) -> Bool {
        lhs.title == rhs.title && lhs.start == rhs.start && lhs.end == rhs.end
            || EventMatchLogic.isSameEvent(
                itemTitle: lhs.title,
                itemStart: lhs.start,
                itemEnd: lhs.end,
                eventTitle: rhs.title,
                eventStart: rhs.start,
                eventEnd: rhs.end
            )
    }

    private func listenForStoreChanges() {
        guard storeChangedObserver == nil else { return }
        storeChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.loadToday()
                self.loadSelectedDay()
                self.storeChangedHandler?()
            }
        }
        listenForAppActive()
    }

    /// Calendar / Today appear plus becoming active retry missing pins and drive minutes.
    private func listenForAppActive() {
        guard appActiveObserver == nil else { return }
        appActiveObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("UIApplicationDidBecomeActiveNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.loadToday()
                self.loadSelectedDay()
            }
        }
    }

    private func mappedAccess() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return .full
        case .writeOnly:
            return .writeOnly
        case .denied, .restricted:
            return .denied
        default:
            return .unknown
        }
    }
}

/// Confirm must not treat an in-memory EKEvent as saved. Write-only cannot
/// fetch the event back, so a non-empty identifier after `commit: true` is enough.
enum CalendarPersistCheck {
    static func accepted(eventIdentifier: String?, access: CalendarAccess, canFetch: Bool) -> Bool {
        guard let eventIdentifier, !eventIdentifier.isEmpty else { return false }
        if access == .full { return canFetch }
        return true
    }
}

enum TodayWindow {
    static func contains(start: Date, end: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let dayStart = calendar.startOfDay(for: now)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return calendar.isDate(start, inSameDayAs: now)
        }
        return start < dayEnd && end > dayStart
    }
}
