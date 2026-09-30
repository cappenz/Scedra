import Foundation
import UserNotifications

struct HomeGapNotificationDraft: Equatable {
    var identifier: String
    var title: String
    var body: String
    var fire: Date
}

/// Local reminders for a home-gap plan. Not always-on listening, not a Live Activity.
enum HomeGapNotifier {
    static let idPrefix = "scedra.homegap."

    static func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Replace every pending home-gap reminder with these suggestions.
    static func reschedule(_ suggestions: [HomeGapSuggestion], now: Date = Date()) async {
        await requestAuthorization()
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: stale)

        for draft in drafts(from: suggestions, now: now) {
            let content = UNMutableNotificationContent()
            content.title = draft.title
            content.body = draft.body
            content.sound = .default
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

    static func drafts(from suggestions: [HomeGapSuggestion], now: Date = Date()) -> [HomeGapNotificationDraft] {
        suggestions.compactMap { suggestion in
            guard suggestion.kind != .cannotBeLived, suggestion.kind != .goHome else { return nil }
            guard suggestion.notifyAt > now else { return nil }
            return HomeGapNotificationDraft(
                identifier: idPrefix + suggestion.id,
                title: suggestion.headline,
                body: body(for: suggestion),
                fire: suggestion.notifyAt
            )
        }
    }

    static func body(for suggestion: HomeGapSuggestion) -> String {
        var parts = [suggestion.detail]
        if !suggestion.bringItems.isEmpty {
            parts.append(ScedraString("Bring: \(suggestion.bringItems.joined(separator: "; "))"))
        }
        return parts.joined(separator: "\n")
    }
}

/// Builds today's and tomorrow's home-gap suggestions and schedules reminders.
enum HomeGapNotificationPlanner {
    @MainActor
    static func refresh(using calendar: CalendarStore, now: Date = Date()) async {
        let day = Calendar.current
        let tomorrow = day.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(24 * 3600)
        let stops = (calendar.events(on: now) + calendar.events(on: tomorrow))
            .filter { !$0.isAllDay }
            .map { $0.asHomeGapStop() }
        if HomeGapLogic.consecutivePairs(from: stops).isEmpty {
            await HomeGapNotifier.reschedule([], now: now)
        } else {
            let home = await PlaceResolver().geocodedHomeLocation()
            let defaults = UserDefaults.standard
            let suggestions = await HomeGapRouter.suggestions(
                stops: stops,
                home: home,
                leavingHomeBuffer: defaults.object(forKey: UserProfile.homeGapKey) as? Int
                    ?? UserProfile.defaultHomeGapMinutes,
                walkMinutes: defaults.object(forKey: UserProfile.walkMinutesKey) as? Int ?? 15,
                preferTransit: defaults.string(forKey: UserProfile.travelModeKey) == TravelMode.transit.rawValue,
                minHomeMinutes: UserProfile.minimumHomeMinutes,
                standingBring: UserProfile.standingBringItems
            )
            await HomeGapNotifier.reschedule(suggestions, now: now)
        }
        await LeaveToNavigatePlanner.refresh(using: calendar, now: now)
    }
}
