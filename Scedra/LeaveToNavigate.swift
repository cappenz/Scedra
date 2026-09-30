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

    static func reschedule(_ drafts: [LeaveToNavigateDraft], now: Date = Date()) async {
        await requestAuthorization()
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) }
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
        guard let leave = leaveBy(for: item, bufferMinutes: bufferMinutes), leave > now else {
            return nil
        }
        let coordinate = pin ?? item.navigationCoordinate
        guard let coordinate, CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let place = item.placeLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = place.isEmpty ? item.title : place
        let resolvedMode = item.savedInfo.travelMode ?? mode
        let body = resolvedMode == .transit
            ? ScedraString("Leave now — transit to \(name).")
            : ScedraString("Leave now — Google Maps or Waze to \(name).")
        return LeaveToNavigateDraft(
            identifier: idPrefix + item.occurrenceKey,
            title: ScedraString("Time to leave for \(item.title)"),
            body: body,
            fire: leave,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            placeName: name,
            mode: resolvedMode
        )
    }

    /// Prefer the leave-by written for this mode. Padded EventKit start is the fallback.
    static func leaveBy(for item: TodayItem, bufferMinutes: Int = UserProfile.defaultHomeGapMinutes) -> Date? {
        guard !item.isAllDay else { return nil }
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
        var drafts: [LeaveToNavigateDraft] = []
        for item in items {
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
        await LeaveToNavigateNotifier.reschedule(drafts, now: now)
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
