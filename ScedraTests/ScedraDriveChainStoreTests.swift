import CoreLocation
import EventKit
import XCTest
@testable import Scedra

@MainActor
final class ScedraDriveChainStoreTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private var store: CalendarStore!
    private var kit: EKEventStore!
    private var day: Date!
    private var savedPlacement: String?
    private var savedMinHome: Any?
    private var savedBuffer: Any?
    private var savedHome: String?

    override func setUp() async throws {
        try await super.setUp()
        savedPlacement = UserDefaults.standard.string(forKey: UserProfile.driveTimePlacementKey)
        savedMinHome = UserDefaults.standard.object(forKey: UserProfile.workOutKey)
        savedBuffer = UserDefaults.standard.object(forKey: UserProfile.homeGapKey)
        savedHome = UserDefaults.standard.string(forKey: PlaceResolver.homeAddressKey)
        UserDefaults.standard.set(DriveTimePlacement.separateEvent.rawValue, forKey: UserProfile.driveTimePlacementKey)
        UserDefaults.standard.set(30, forKey: UserProfile.workOutKey)
        UserDefaults.standard.set(0, forKey: UserProfile.homeGapKey)
        UserDefaults.standard.set(
            "Apple Park, One Apple Park Way, Cupertino, CA 95014",
            forKey: PlaceResolver.homeAddressKey
        )
        UserDefaults.standard.removeObject(forKey: DriveEventLinkStore.key)
        UserDefaults.standard.removeObject(forKey: DriveEventLinkStore.onwardKey)
        UserDefaults.standard.removeObject(forKey: DriveEventLinkStore.chainMapKey)

        let base = calendar.startOfDay(for: Date())
        day = calendar.date(byAdding: .day, value: 21, to: base)

        store = CalendarStore()
        await store.requestAccessAndLoad()
        try XCTSkipIf(store.access != .full, "Full calendar access required for Confirm save path")

        kit = EKEventStore()
        await clearTestDay()

        CalendarTravelBackfill.estimateProvider = { [weak self] stops in
            guard let self else { return DriveChainEstimates() }
            var estimates = DriveChainEstimates()
            for stop in stops {
                estimates.fromHome[stop.id] = 21
                estimates.toHome[stop.id] = 21
            }
            if stops.count >= 2 {
                let ordered = stops.sorted { $0.start < $1.start }
                estimates.between["\(ordered[0].id)|\(ordered[1].id)"] = 15
            }
            return estimates
        }
    }

    override func tearDown() async throws {
        CalendarTravelBackfill.estimateProvider = nil
        if let day {
            store?.selectedDay = day
            await clearTestDay()
        }
        if let savedPlacement {
            UserDefaults.standard.set(savedPlacement, forKey: UserProfile.driveTimePlacementKey)
        } else {
            UserDefaults.standard.removeObject(forKey: UserProfile.driveTimePlacementKey)
        }
        if let savedMinHome {
            UserDefaults.standard.set(savedMinHome, forKey: UserProfile.workOutKey)
        } else {
            UserDefaults.standard.removeObject(forKey: UserProfile.workOutKey)
        }
        if let savedBuffer {
            UserDefaults.standard.set(savedBuffer, forKey: UserProfile.homeGapKey)
        } else {
            UserDefaults.standard.removeObject(forKey: UserProfile.homeGapKey)
        }
        if let savedHome {
            UserDefaults.standard.set(savedHome, forKey: PlaceResolver.homeAddressKey)
        } else {
            UserDefaults.standard.removeObject(forKey: PlaceResolver.homeAddressKey)
        }
        UserDefaults.standard.removeObject(forKey: DriveEventLinkStore.key)
        UserDefaults.standard.removeObject(forKey: DriveEventLinkStore.onwardKey)
        UserDefaults.standard.removeObject(forKey: DriveEventLinkStore.chainMapKey)
        store = nil
        kit = nil
        try await super.tearDown()
    }

    func testConfirmSaveUsesDayChainAndDeletesOldSchemeSiblings() async throws {
        let targetStart = time(15)
        let targetEnd = time(16)
        let heartStart = time(16, 20)
        let heartEnd = time(17, 20)

        insertOldSchemeSibling(
            title: "Drive home",
            start: targetEnd,
            end: targetEnd.addingTimeInterval(21 * 60),
            location: "Apple Park, One Apple Park Way, Cupertino, CA 95014",
            notes: """
            \(EventNotes.marker)

            \(DriveTimeLogic.driveMarker)
            \(DriveTimeLogic.forPrefix) stale-target
            \(DriveTimeLogic.legPrefix) onward
            """
        )
        insertOldSchemeSibling(
            title: "Drive to H Mart",
            start: time(15, 40),
            end: heartStart,
            location: "H Mart",
            notes: """
            \(EventNotes.marker)

            \(DriveTimeLogic.driveMarker)
            \(DriveTimeLogic.forPrefix) stale-heart
            \(DriveTimeLogic.legPrefix) inbound
            """
        )

        try await store.save(
            draft(
                title: "target",
                start: targetStart,
                minutes: 60,
                place: "Target"
            ),
            travel: travel(start: targetStart)
        )
        try await store.save(
            draft(
                title: "Heart",
                start: heartStart,
                minutes: 60,
                place: "H Mart"
            ),
            travel: travel(start: heartStart)
        )

        let events = timedEvents()
        let titles = events.map { $0.title ?? "" }
        XCTAssertEqual(
            titles,
            [
                ScedraString("Drive to target"),
                "target",
                ScedraString("Drive to Heart from target"),
                "Heart",
                ScedraString("Drive home"),
            ],
            "EventKit day after Confirm save: \(events.map(summarize).joined(separator: " | "))"
        )
        XCTAssertFalse(titles.contains("Drive to H Mart"))
        XCTAssertEqual(events.filter { ($0.title ?? "").hasPrefix("Drive home") }.count, 1)

        let between = try XCTUnwrap(events.first { ($0.title ?? "").contains("Drive to Heart from target") })
        XCTAssertEqual(between.startDate.timeIntervalSince(targetEnd), 0, accuracy: 1)
        XCTAssertEqual(between.endDate.timeIntervalSince(targetEnd.addingTimeInterval(15 * 60)), 0, accuracy: 1)

        let inbound = try XCTUnwrap(events.first { ($0.title ?? "") == ScedraString("Drive to target") })
        XCTAssertEqual(inbound.endDate.timeIntervalSince(targetStart), 0, accuracy: 1)

        let home = try XCTUnwrap(events.last { ($0.title ?? "") == ScedraString("Drive home") })
        XCTAssertEqual(home.startDate.timeIntervalSince(heartEnd), 0, accuracy: 1)

        XCTAssertEqual(events.first { $0.title == "target" }?.startDate.timeIntervalSince(targetStart) ?? 99, 0, accuracy: 1)
        XCTAssertEqual(events.first { $0.title == "Heart" }?.startDate.timeIntervalSince(heartStart) ?? 99, 0, accuracy: 1)
        XCTAssertEqual(events.first { $0.title == "Heart" }?.endDate.timeIntervalSince(heartEnd) ?? 99, 0, accuracy: 1)
    }

    func testBackToBackConfirmWritesStraddlingDriveToBFromA() async throws {
        CalendarTravelBackfill.estimateProvider = { stops in
            var estimates = DriveChainEstimates()
            let ordered = stops.sorted { $0.start < $1.start }
            for stop in ordered {
                estimates.fromHome[stop.id] = 21
                estimates.toHome[stop.id] = 21
            }
            if ordered.count >= 2 {
                estimates.between["\(ordered[0].id)|\(ordered[1].id)"] = 10
            }
            return estimates
        }

        let targetStart = time(15)
        let targetEnd = time(16)
        let heartStart = time(16)
        let heartEnd = time(17)

        try await store.save(
            draft(title: "target", start: targetStart, minutes: 60, place: "Target"),
            travel: travel(start: targetStart)
        )
        try await store.save(
            draft(title: "Heart", start: heartStart, minutes: 60, place: "H Mart"),
            travel: travel(start: heartStart)
        )

        let events = timedEvents()
        let titles = events.map { $0.title ?? "" }
        XCTAssertEqual(
            titles,
            [
                ScedraString("Drive to target"),
                "target",
                ScedraString("Drive to Heart from target"),
                "Heart",
                ScedraString("Drive home"),
            ],
            "EventKit day after back-to-back Confirm: \(events.map(summarize).joined(separator: " | "))"
        )

        let between = try XCTUnwrap(events.first { ($0.title ?? "").contains("Drive to Heart from target") })
        XCTAssertEqual(between.startDate.timeIntervalSince(time(15, 55)), 0, accuracy: 1)
        XCTAssertEqual(between.endDate.timeIntervalSince(time(16, 5)), 0, accuracy: 1)

        let targetEvent = try XCTUnwrap(events.first { $0.title == "target" })
        XCTAssertEqual(targetEvent.startDate.timeIntervalSince(targetStart), 0, accuracy: 1)
        XCTAssertEqual(targetEvent.endDate.timeIntervalSince(targetEnd), 0, accuracy: 1)

        let heartEvent = try XCTUnwrap(events.first { $0.title == "Heart" })
        XCTAssertEqual(heartEvent.startDate.timeIntervalSince(heartStart), 0, accuracy: 1)
        XCTAssertEqual(heartEvent.endDate.timeIntervalSince(heartEnd), 0, accuracy: 1)

        let home = try XCTUnwrap(events.last { ($0.title ?? "") == ScedraString("Drive home") })
        XCTAssertEqual(home.startDate.timeIntervalSince(heartEnd), 0, accuracy: 1)
    }

    private func time(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    private func travel(start: Date) -> TravelEstimate {
        TravelEstimator.estimate(
            minutes: 21,
            mode: .drive,
            start: start,
            bufferMinutes: 0,
            returnMinutes: 21
        )
    }

    private func draft(title: String, start: Date, minutes: Int, place: String) -> DraftEvent {
        DraftEvent(
            title: title,
            start: start,
            durationMinutes: minutes,
            durationAssumed: false,
            location: place,
            resolvedLocation: place,
            locationLatitude: 37.332,
            locationLongitude: -122.005,
            sourceText: "ScedraDriveChainIT \(title)",
            hasDate: true,
            hasTime: true
        )
    }

    private func insertOldSchemeSibling(
        title: String,
        start: Date,
        end: Date,
        location: String,
        notes: String
    ) {
        let event = EKEvent(eventStore: kit)
        event.calendar = kit.defaultCalendarForNewEvents ?? storeWritableCalendar()
        event.title = title
        event.startDate = start
        event.endDate = end
        event.timeZone = TimeZone.current
        event.location = location
        event.notes = notes
        try? kit.save(event, span: .thisEvent, commit: true)
    }

    private func storeWritableCalendar() -> EKCalendar? {
        kit.calendars(for: .event).first { $0.allowsContentModifications }
    }

    private func timedEvents() -> [EKEvent] {
        kit.refreshSourcesIfNecessary()
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let predicate = kit.predicateForEvents(withStart: start, end: end, calendars: nil)
        return kit.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
    }

    private func summarize(_ event: EKEvent) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(event.title ?? "") \(formatter.string(from: event.startDate))–\(formatter.string(from: event.endDate))"
    }

    private func clearTestDay() async {
        for event in timedEvents() {
            let notes = event.notes ?? ""
            let title = event.title ?? ""
            let ours = notes.contains("ScedraDriveChainIT")
                || notes.contains(DriveTimeLogic.driveMarker)
                || notes.contains("stale-target")
                || notes.contains("stale-heart")
                || title == "target"
                || title == "Heart"
                || title.hasPrefix("Drive to")
                || title.hasPrefix("Drive from")
                || title.hasPrefix("Drive home")
            if ours, event.calendar?.allowsContentModifications ?? false {
                try? kit.remove(event, span: .thisEvent, commit: true)
            }
        }
        if let store {
            for item in store.driveSiblings(on: day) + store.events(on: day) {
                try? store.delete(item)
            }
        }
    }
}
