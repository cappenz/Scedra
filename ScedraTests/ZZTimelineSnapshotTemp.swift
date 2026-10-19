import SwiftUI
import UIKit
import XCTest
@testable import Scedra

final class ZZTimelineSnapshotTemp: XCTestCase {
    @MainActor
    func testSnapshot() throws {
        let cal = Calendar.current
        let day = cal.startOfDay(for: cal.date(from: DateComponents(year: 2026, month: 6, day: 10))!)
        func t(_ h: Int, _ m: Int) -> Date { day.addingTimeInterval(TimeInterval(h * 3600 + m * 60)) }
        let home = "Apple Park, One Apple Park Way, Cupertino, CA 95014"
        let items = [
            TodayItem(id: "1", title: "Drive to PetSmart", start: t(10, 0), end: t(10, 15), isAllDay: false, location: nil),
            TodayItem(id: "2", title: "Boba", start: t(10, 15), end: t(11, 15), isAllDay: false, location: nil),
            TodayItem(id: "3", title: "Drive home", start: t(11, 15), end: t(11, 33), isAllDay: false, location: home),
            TodayItem(id: "4", title: "Drive to Walmart", start: t(11, 15), end: t(11, 30), isAllDay: false, location: nil),
            TodayItem(id: "5", title: "Walmart", start: t(11, 30), end: t(12, 30), isAllDay: false, location: nil),
            TodayItem(id: "6", title: "Drive home", start: t(12, 30), end: t(12, 50), isAllDay: false, location: home),
            TodayItem(id: "7", title: "Quick call", start: t(13, 30), end: t(13, 35), isAllDay: false, location: nil)
        ]
        let view = DayTimelineView(
            day: day,
            items: items,
            onSelect: { _ in },
            onDelete: { _ in },
            onShiftDay: { _ in }
        )
        .padding(.horizontal, 16)
        .background(Color(white: 0.96))

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 520))
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let image = renderer.image { ctx in
            host.view.layer.render(in: ctx.cgContext)
        }
        let url = URL(fileURLWithPath: "/tmp/scedra-timeline-short-events.png")
        try XCTUnwrap(image.pngData()).write(to: url)
    }
}
