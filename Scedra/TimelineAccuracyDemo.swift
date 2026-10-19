#if DEBUG
import EventKit
import Foundation

/// Debug-only seed for checking the day timeline against the hour grid.
/// Launch with `-scedra-timeline-accuracy-seed`: writes short and normal blocks
/// (including an overlap) on tomorrow and opens Calendar there. Release builds
/// omit this type.
enum TimelineAccuracyDemo {
    static let argument = "-scedra-timeline-accuracy-seed"
    static let marker = "ScedraTimelineAccuracyIT"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }

    private static let blocks: [(title: String, start: (Int, Int), end: (Int, Int))] = [
        ("Lunch drive", (12, 30), (12, 50)),
        ("Target", (15, 0), (16, 0)),
        ("Drive to H Mart", (16, 0), (16, 21)),
        ("H Mart", (16, 20), (17, 20)),
        ("Drive home", (17, 20), (17, 49))
    ]

    @MainActor
    static func seed(using calendar: CalendarStore) async -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let day = cal.date(byAdding: .day, value: 1, to: today) ?? today

        let kit = EKEventStore()
        _ = try? await kit.requestFullAccessToEvents()
        clear(on: day, kit: kit)
        for block in blocks {
            let event = EKEvent(eventStore: kit)
            event.calendar = kit.defaultCalendarForNewEvents
                ?? kit.calendars(for: .event).first { $0.allowsContentModifications }
            event.title = block.title
            event.startDate = date(day, block.start)
            event.endDate = date(day, block.end)
            event.timeZone = TimeZone.current
            event.notes = marker
            try? kit.save(event, span: .thisEvent, commit: true)
        }

        calendar.selectedDay = day
        calendar.loadToday()
        calendar.loadSelectedDay()
        return day
    }

    private static func date(_ day: Date, _ time: (Int, Int)) -> Date {
        Calendar.current.date(bySettingHour: time.0, minute: time.1, second: 0, of: day) ?? day
    }

    private static func clear(on day: Date, kit: EKEventStore) {
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: day) else { return }
        let predicate = kit.predicateForEvents(withStart: day, end: end, calendars: nil)
        for event in kit.events(matching: predicate) where (event.notes ?? "").contains(marker) {
            try? kit.remove(event, span: .thisEvent, commit: true)
        }
    }
}
#endif
