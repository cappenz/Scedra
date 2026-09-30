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
        !isAllDay && placeLabel != nil
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
            notes: notes ?? ""
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

/// Maps a user-initiated appointment time change onto the existing EventKit event.
/// Never invents a new identifier — CalendarStore saves the event she tapped.
enum EventScheduleEdit {
    struct Prepared: Equatable {
        var identifier: String
        var title: String
        var start: Date
        var end: Date
        var notes: String?
    }

    static func prepare(item: TodayItem, officialStart: Date, officialEnd: Date) throws -> Prepared {
        guard CalendarSaveGate.readyToSave(start: officialStart, end: officialEnd) else {
            throw CalendarStoreError.missingDateOrTime
        }
        let padBefore = item.officialStart.timeIntervalSince(item.start)
        let padAfter = item.end.timeIntervalSince(item.officialEnd)
        let blockStart = officialStart.addingTimeInterval(-max(padBefore, 0))
        let blockEnd = officialEnd.addingTimeInterval(max(padAfter, 0))
        guard blockEnd > blockStart else {
            throw CalendarStoreError.missingDateOrTime
        }
        return Prepared(
            identifier: item.id,
            title: item.title,
            start: blockStart,
            end: blockEnd,
            notes: replacingAppointmentWindow(in: item.notes, start: officialStart, end: officialEnd)
        )
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
    /// Debounces Maps + notification reschedule after Today reloads.
    private var homeGapNotifyTask: Task<Void, Never>?

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

    /// Rebuild local home-gap reminders for today and tomorrow.
    func refreshHomeGapNotifications() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        homeGapNotifyTask?.cancel()
        homeGapNotifyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            await HomeGapNotificationPlanner.refresh(using: self)
        }
    }

    func loadSelectedDay() {
        selectedDayEvents = events(on: selectedDay)
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
        // The block wraps the drive when one is known; the notes still state 6-9 as 6-9.
        let block = TravelEstimator.calendarBlock(
            start: draft.arrivalTarget,
            end: draft.end,
            travel: travel,
            extraBeforeMinutes: draft.extraBeforeMinutes,
            extraAfterMinutes: draft.extraAfterMinutes
        )
        event.startDate = block.start
        event.endDate = block.end
        event.timeZone = TimeZone.current
        let place = draft.locationToSave
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
        OriginalTextStore.save(draft.sourceText, for: savedID)
        PlaceMemory.remember(
            title: draft.calendarTitle,
            location: draft.locationToSave,
            latitude: draft.locationLatitude,
            longitude: draft.locationLongitude
        )
        reloadTodayAfterSave(committed)
        loadSelectedDay()
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

    /// User-initiated day/time change on the event she tapped. Saves the existing
    /// EventKit event (`commit: true`). Never silently moves a different event.
    func updateEventTimes(_ item: TodayItem, start: Date, end: Date) async throws {
        let prepared = try EventScheduleEdit.prepare(item: item, officialStart: start, officialEnd: end)
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

        event.startDate = prepared.start
        event.endDate = prepared.end
        event.isAllDay = false
        event.timeZone = TimeZone.current
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
        reloadTodayAfterSave(committed)
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
        forget(todayItem(from: event), eventID: identifier)
        store.refreshSourcesIfNecessary()
        loadToday()
        loadSelectedDay()
    }

    private func eventForTaskIdentifier(_ identifier: String) -> EKEvent? {
        if let event = store.event(withIdentifier: identifier) { return event }
        if let event = store.calendarItem(withIdentifier: identifier) as? EKEvent { return event }
        return retainedEvents[identifier]
    }

    /// Updates travel notes only — never moves the EventKit start or end.
    func updateTravelNotes(for item: TodayItem, travel: TravelEstimate) throws {
        let place = item.placeLabel ?? ""
        let details = TravelEstimator.noteLines(
            appointmentStart: item.officialStart,
            appointmentEnd: item.officialEnd,
            travel: travel,
            place: place
        ) + item.savedInfo.extraLines
        let notes = EventNotes.body(forOriginal: item.originalText ?? "", details: details)
        if let event = eventMatching(item), access == .full || access == .writeOnly {
            event.notes = notes
            try store.save(event, span: .thisEvent, commit: true)
        }
        func patched(_ existing: TodayItem) -> TodayItem {
            TodayItem(
                id: existing.id,
                title: existing.title,
                start: existing.start,
                end: existing.end,
                isAllDay: existing.isAllDay,
                location: existing.location,
                notes: notes,
                latitude: existing.latitude,
                longitude: existing.longitude
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
        forget(item, eventID: stableID(for: event))
        store.refreshSourcesIfNecessary()
        loadToday()
        loadSelectedDay()
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
