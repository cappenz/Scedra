#if DEBUG
import CoreLocation
import EventKit
import Foundation

/// Debug-only Confirm-path seed for the Target → Heart chain screenshot.
/// Launch with `-scedra-drive-chain-seed`. Release builds omit this type.
enum DriveChainDemo {
    static let argument = "-scedra-drive-chain-seed"
    static let marker = "ScedraDriveChainIT"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }

    @MainActor
    static func seed(using calendar: CalendarStore) async -> Date {
        let day = Calendar.current.startOfDay(for: Date())
        UserDefaults.standard.set(
            DriveTimePlacement.separateEvent.rawValue,
            forKey: UserProfile.driveTimePlacementKey
        )
        UserDefaults.standard.set(30, forKey: UserProfile.workOutKey)
        UserDefaults.standard.set(0, forKey: UserProfile.homeGapKey)
        UserDefaults.standard.set(
            "Apple Park, One Apple Park Way, Cupertino, CA 95014",
            forKey: PlaceResolver.homeAddressKey
        )
        UserDefaults.standard.set("14", forKey: "scedra-timeline-scroll-hour")
        CalendarTravelBackfill.estimateProvider = { stops in
            var estimates = DriveChainEstimates()
            let ordered = stops.sorted { $0.start < $1.start }
            for stop in ordered {
                estimates.fromHome[stop.id] = 21
                estimates.toHome[stop.id] = 21
            }
            if ordered.count >= 2 {
                estimates.between["\(ordered[0].id)|\(ordered[1].id)"] = 15
            }
            return estimates
        }

        let kit = EKEventStore()
        _ = try? await kit.requestFullAccessToEvents()
        clearDemoEvents(on: day, kit: kit)

        let targetStart = date(day, 15, 0)
        let targetEnd = date(day, 16, 0)
        let heartStart = date(day, 16, 20)
        let heartEnd = date(day, 17, 20)

        insertStale(
            kit: kit,
            title: "Drive home",
            start: targetEnd,
            end: targetEnd.addingTimeInterval(21 * 60),
            location: "Apple Park, One Apple Park Way, Cupertino, CA 95014",
            notes: """
            \(EventNotes.marker)

            \(DriveTimeLogic.driveMarker)
            \(DriveTimeLogic.forPrefix) stale-target
            \(DriveTimeLogic.legPrefix) onward
            Original: \(marker) stale-home
            """
        )
        insertStale(
            kit: kit,
            title: "Drive to H Mart",
            start: date(day, 15, 40),
            end: heartStart,
            location: "H Mart",
            notes: """
            \(EventNotes.marker)

            \(DriveTimeLogic.driveMarker)
            \(DriveTimeLogic.forPrefix) stale-heart
            \(DriveTimeLogic.legPrefix) inbound
            Original: \(marker) stale-inbound
            """
        )

        calendar.selectedDay = day
        calendar.loadToday()
        calendar.loadSelectedDay()

        let travel: (Date) -> TravelEstimate = { start in
            TravelEstimator.estimate(
                minutes: 21,
                mode: .drive,
                start: start,
                bufferMinutes: 0,
                returnMinutes: 21
            )
        }
        try? await calendar.save(
            draft(title: "target", start: targetStart, place: "Target"),
            travel: travel(targetStart)
        )
        try? await calendar.save(
            draft(title: "Heart", start: heartStart, place: "H Mart"),
            travel: travel(heartStart)
        )
        _ = heartEnd
        calendar.selectedDay = day
        calendar.loadToday()
        calendar.loadSelectedDay()
        return day
    }

    private static func date(_ day: Date, _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    private static func draft(title: String, start: Date, place: String) -> DraftEvent {
        DraftEvent(
            title: title,
            start: start,
            durationMinutes: 60,
            durationAssumed: false,
            location: place,
            resolvedLocation: place,
            locationLatitude: place == "Target" ? 37.3230 : 37.3524,
            locationLongitude: place == "Target" ? -122.0465 : -121.9814,
            sourceText: "\(marker) \(title)",
            hasDate: true,
            hasTime: true
        )
    }

    private static func insertStale(
        kit: EKEventStore,
        title: String,
        start: Date,
        end: Date,
        location: String,
        notes: String
    ) {
        let event = EKEvent(eventStore: kit)
        event.calendar = kit.defaultCalendarForNewEvents
            ?? kit.calendars(for: .event).first { $0.allowsContentModifications }
        event.title = title
        event.startDate = start
        event.endDate = end
        event.timeZone = TimeZone.current
        event.location = location
        event.notes = notes
        try? kit.save(event, span: .thisEvent, commit: true)
    }

    private static func clearDemoEvents(on day: Date, kit: EKEventStore) {
        let start = Calendar.current.startOfDay(for: day)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return }
        kit.refreshSourcesIfNecessary()
        let predicate = kit.predicateForEvents(withStart: start, end: end, calendars: nil)
        for event in kit.events(matching: predicate) {
            let notes = event.notes ?? ""
            let title = event.title ?? ""
            let ours = notes.contains(marker)
                || notes.contains("stale-target")
                || notes.contains("stale-heart")
                || title == "target"
                || title == "Heart"
                || title == "Drive to H Mart"
                || title.hasPrefix("Drive to target")
                || title.hasPrefix("Drive from target")
                || title.contains(" from target")
                || title.contains(" from Boba")
                || (title.hasPrefix("Drive home") && notes.contains(DriveTimeLogic.driveMarker))
            if ours, event.calendar?.allowsContentModifications ?? false {
                try? kit.remove(event, span: .thisEvent, commit: true)
            }
        }
    }
}
#endif
