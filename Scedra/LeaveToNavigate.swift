import CoreLocation
import Foundation
import UserNotifications

struct LeaveToNavigateDraft: Equatable {
    var identifier: String
    var title: String
    var body: String
    var fire: Date
    var latitude: Double
    var longitude: Double
    var placeName: String
    var mode: TravelMode
}

/// Time-to-leave banner with Google Maps / Waze — fires at leave-by, not the appointment.
enum LeaveToNavigateNotifier {
    static let idPrefix = "scedra.leave."
    static let categoryID = "scedra.leave.navigate"
    static let googleAction = "scedra.leave.google"
    static let wazeAction = "scedra.leave.waze"
    static let latitudeKey = "lat"
    static let longitudeKey = "lng"
    static let nameKey = "name"
    static let modeKey = "mode"

    static func registerCategory() {
        let google = UNNotificationAction(
            identifier: googleAction,
            title: "Google Maps",
            options: [.foreground]
        )
        let waze = UNNotificationAction(
            identifier: wazeAction,
            title: "Waze",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [google, waze],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    static func requestAuthorization() async {
        registerCategory()
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    static func reschedule(
        _ drafts: [LeaveToNavigateDraft],
        liveIdentifiers: Set<String>? = nil,
        now: Date = Date()
    ) async {
        await requestAuthorization()
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let newIDs = Set(drafts.map(\.identifier))
        let stale = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(idPrefix) }
            .filter { identifier in
                if newIDs.contains(identifier) { return true }
                if let liveIdentifiers {
                    return !liveIdentifiers.contains(identifier)
                }
                return true
            }
        center.removePendingNotificationRequests(withIdentifiers: stale)

        for draft in drafts where draft.fire > now {
            let content = UNMutableNotificationContent()
            content.title = draft.title
            content.body = draft.body
            content.sound = .default
            content.categoryIdentifier = categoryID
            content.userInfo = userInfo(for: draft)
            let parts = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: draft.fire
            )
            let request = UNNotificationRequest(
                identifier: draft.identifier,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            )
            try? await center.add(request)
        }
    }

    static func drafts(
        from items: [TodayItem],
        now: Date = Date(),
        bufferMinutes: Int = UserProfile.defaultHomeGapMinutes,
        mode: TravelMode = .drive
    ) -> [LeaveToNavigateDraft] {
        items.compactMap { item in
            draft(for: item, now: now, bufferMinutes: bufferMinutes, mode: mode)
        }
    }

    static func draft(
        for item: TodayItem,
        pin: CLLocationCoordinate2D? = nil,
        now: Date = Date(),
        bufferMinutes: Int = UserProfile.defaultHomeGapMinutes,
        mode: TravelMode = .drive
    ) -> LeaveToNavigateDraft? {
        guard !item.isAllDay else { return nil }
        if isGoHomeDrive(item) { return nil }
        guard let leave = leaveBy(for: item, bufferMinutes: bufferMinutes), leave > now else {
            return nil
        }
        let coordinate = pin ?? item.navigationCoordinate
        guard let coordinate, CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let name = destinationName(for: item)
        let resolvedMode = item.savedInfo.travelMode ?? mode
        return LeaveToNavigateDraft(
            identifier: notificationIdentifier(for: item),
            title: leaveNowTitle(destination: name, mode: resolvedMode),
            body: ScedraString("Tap to open Maps"),
            fire: leave,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            placeName: name,
            mode: resolvedMode
        )
    }

    static func notificationIdentifier(for item: TodayItem) -> String {
        item.isDriveEvent ? idPrefix + item.id : idPrefix + item.occurrenceKey
    }

    /// Drive home / Drive from stay off — Don’t-go-home cards are not leave-now banners.
    static func isGoHomeDrive(_ item: TodayItem) -> Bool {
        guard item.isDriveEvent else { return false }
        if DriveTimeLogic.inferredLeg(title: item.title, notes: item.notes) == .onward {
            return true
        }
        let folded = item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return folded.hasPrefix("drive home")
            || folded.hasPrefix("transit home")
            || folded.hasPrefix("walk home")
            || folded.hasPrefix("trajet maison")
            || folded.hasPrefix("trayecto a casa")
            || folded.hasPrefix("fahrt nach hause")
    }

    static func destinationName(for item: TodayItem) -> String {
        if item.isDriveEvent {
            let place = DriveTimeLogic.shortPlace(item.placeLabel ?? "")
            if !place.isEmpty, !HomeGapLogic.looksLikeHome(place) {
                return place
            }
            if let parsed = destinationFromDriveTitle(item.title), !parsed.isEmpty {
                return parsed
            }
        }
        let place = DriveTimeLogic.shortPlace(item.placeLabel ?? "")
        return place.isEmpty ? item.title : place
    }

    static func destinationFromDriveTitle(_ title: String) -> String? {
        let prefixes = [
            "Drive to ", "Transit to ", "Walk to ",
            "Trajet vers ", "Trayecto a ", "Fahrt zu "
        ]
        let folded = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in prefixes {
            guard folded.lowercased().hasPrefix(prefix.lowercased()) else { continue }
            var rest = String(folded.dropFirst(prefix.count))
            for marker in [" from ", " de ", " von "] {
                if let range = rest.range(of: marker, options: .caseInsensitive) {
                    rest = String(rest[..<range.lowerBound])
                }
            }
            let trimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    static func leaveNowTitle(destination: String, mode: TravelMode) -> String {
        switch mode {
        case .transit: return ScedraString("Leave now — transit to \(destination)")
        case .walk: return ScedraString("Leave now — walk to \(destination)")
        case .drive: return ScedraString("Leave now — drive to \(destination)")
        }
    }

    /// Drive siblings fire at the block start (leave-by for inbound from Home).
    /// Appointments use the leave-by line, then padded start, then drive minutes.
    static func leaveBy(for item: TodayItem, bufferMinutes: Int = UserProfile.defaultHomeGapMinutes) -> Date? {
        guard !item.isAllDay else { return nil }
        if item.isDriveEvent {
            if isGoHomeDrive(item) { return nil }
            return item.start
        }
        if let parsed = parseLeaveByLine(item.savedInfo.leaveByLine, around: item.officialStart) {
            return parsed
        }
        if item.savedInfo.leaveByLine != nil {
            return item.start
        }
        if let minutes = driveMinutes(from: item.savedInfo.driveLine) {
            return TravelEstimator.leaveBy(
                start: item.officialStart,
                travelMinutes: minutes,
                bufferMinutes: bufferMinutes
            )
        }
        return nil
    }

    /// "Leave by 9:51 AM" on the official appointment day — so a later mode switch
    /// can change the fire time without moving the EventKit block.
    static func parseLeaveByLine(_ line: String?, around reference: Date) -> Date? {
        guard let line, let text = TravelEstimator.leaveByTimeText(from: line), !text.isEmpty,
              case .clock(let hour, let minute, _) = ReviewTimeTyping.parseAppointment(text)
        else { return nil }
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: reference)
    }

    /// First "~25 min" on a Drive: line — outbound only, never the return.
    static func driveMinutes(from line: String?) -> Int? {
        guard let line, !line.isEmpty else { return nil }
        guard let match = line.range(of: #"~(\d+)\s*min"#, options: .regularExpression) else {
            return nil
        }
        let digits = line[match].filter(\.isNumber)
        return Int(digits)
    }

    /// "~18 min back" on a Drive: round-trip line. Nil when notes only stored outbound.
    static func returnMinutes(from line: String?) -> Int? {
        guard let line, !line.isEmpty else { return nil }
        guard let match = line.range(of: #"~(\d+)\s*min back"#, options: .regularExpression) else {
            return nil
        }
        let digits = line[match].filter(\.isNumber)
        return Int(digits)
    }

    static func userInfo(for draft: LeaveToNavigateDraft) -> [String: Any] {
        [
            latitudeKey: draft.latitude,
            longitudeKey: draft.longitude,
            nameKey: draft.placeName,
            modeKey: draft.mode.rawValue
        ]
    }

    /// Google Maps or Waze from a notification tap — default banner tap is Google.
    static func mapsApp(for action: String) -> String? {
        switch action {
        case wazeAction:
            return "waze"
        case googleAction, UNNotificationDefaultActionIdentifier:
            return "google"
        default:
            return nil
        }
    }

    static func openMaps(from userInfo: [AnyHashable: Any], action: String) {
        guard let latitude = coordinateValue(userInfo[latitudeKey]),
              let longitude = coordinateValue(userInfo[longitudeKey])
        else { return }
        let mode = TravelMode(rawValue: userInfo[modeKey] as? String ?? "") ?? .drive
        let name = userInfo[nameKey] as? String ?? "Destination"
        switch action {
        case wazeAction:
            if mode == .transit {
                MapsHandoff.openAppleMaps(latitude: latitude, longitude: longitude, name: name, mode: .transit)
            } else {
                MapsHandoff.openWaze(latitude: latitude, longitude: longitude)
            }
        case googleAction, UNNotificationDefaultActionIdentifier:
            MapsHandoff.openGoogleMaps(latitude: latitude, longitude: longitude, mode: mode)
        default:
            break
        }
    }

    private static func coordinateValue(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? NSNumber { return value.doubleValue }
        return nil
    }
}

/// Today's and tomorrow's leave-by reminders, using the pin we already have or a saved place.
enum LeaveToNavigatePlanner {
    @MainActor
    static func refresh(using calendar: CalendarStore, now: Date = Date()) async {
        let day = Calendar.current
        let tomorrow = day.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(24 * 3600)
        let items = unique(
            (calendar.events(on: now) + calendar.events(on: tomorrow))
                .filter { !$0.isAllDay }
        )
        let settingsMode = TravelMode(rawValue: UserDefaults.standard.string(forKey: UserProfile.travelModeKey) ?? "")
            ?? .drive
        let buffer = UserDefaults.standard.object(forKey: UserProfile.homeGapKey) as? Int
            ?? UserProfile.defaultHomeGapMinutes
        let resolver = PlaceResolver()
        let coveredAppointments = Set(items.compactMap { item -> String? in
            guard item.isDriveEvent else { return nil }
            let leg = DriveTimeLogic.inferredLeg(title: item.title, notes: item.notes)
            guard leg == .inbound || leg == .between else { return nil }
            return DriveTimeLogic.appointmentIdentifier(fromDriveNotes: item.notes)
                ?? DriveTimeLogic.endpointIDs(fromNotes: item.notes).to
        })
        var drafts: [LeaveToNavigateDraft] = []
        for item in items {
            if !item.isDriveEvent, coveredAppointments.contains(item.id) {
                continue
            }
            let pin = await destinationPin(for: item, resolver: resolver)
            let mode = item.savedInfo.travelMode ?? settingsMode
            if let draft = LeaveToNavigateNotifier.draft(
                for: item,
                pin: pin,
                now: now,
                bufferMinutes: buffer,
                mode: mode
            ) {
                drafts.append(draft)
            }
        }
        let live = Set(items.map { LeaveToNavigateNotifier.notificationIdentifier(for: $0) })
        await LeaveToNavigateNotifier.reschedule(drafts, liveIdentifiers: live, now: now)
    }

    static func destinationPin(for item: TodayItem, resolver: PlaceResolver) async -> CLLocationCoordinate2D? {
        if let pin = item.navigationCoordinate { return pin }
        if let remembered = PlaceMemory.remembered(forTitle: item.title)
            ?? PlaceMemory.remembered(matchingPlaceQuery: item.placeLabel ?? ""),
           let latitude = remembered.latitude,
           let longitude = remembered.longitude {
            let pin = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            if CLLocationCoordinate2DIsValid(pin) { return pin }
        }
        let query = [item.placeLabel, item.title]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        if let saved = await resolver.resolvedSavedPlace(matching: query),
           let latitude = saved.latitude,
           let longitude = saved.longitude {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        if let place = await resolver.resolve(query),
           let latitude = place.latitude,
           let longitude = place.longitude {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        return nil
    }

    private static func unique(_ items: [TodayItem]) -> [TodayItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.occurrenceKey).inserted }
    }
}

final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        LeaveToNavigateNotifier.openMaps(
            from: response.notification.request.content.userInfo,
            action: response.actionIdentifier
        )
    }
}
