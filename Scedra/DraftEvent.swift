import Foundation

struct DraftEvent: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var start: Date
    var durationMinutes: Int
    var durationAssumed: Bool
    var location: String
    var resolvedLocation: String? = nil
    var resolvedCaption: String? = nil
    var locationLatitude: Double? = nil
    var locationLongitude: Double? = nil
    var sourceText: String
    /// Whether the original text named a calendar day. Review still shows a DatePicker
    /// using `start`; this flag is only a "we had to guess" hint, not the save gate.
    var hasDate: Bool
    /// Whether the original text named a clock time. Review still shows typed start/end
    /// fields and a start–end line using `start`; this flag is not the save gate.
    var hasTime: Bool
    /// Minutes to arrive before the official start. Default 0. Not Apple Maps drive time.
    /// Portal check-in is `arriveBy`, not this chip — zeroing extra-before must not move leave-by to the appointment start.
    var extraBeforeMinutes: Int = 0
    /// Minutes to stay after the official end. Default 0. Not Apple Maps drive time.
    var extraAfterMinutes: Int = 0
    /// When she must be at the place (check-in). Travel and leave-by use this; official `start` stays the appointment.
    var arriveBy: Date? = nil
    /// Per-appointment Driving vs Public transport. Settings is only the default.
    var travelMode: TravelMode = .drive
    /// Portal notes, parking, and other extra lines — saved on the calendar event.
    var details: [String] = []
    /// Session-only path to the photo she scanned. Voice and type stay nil.
    var originalImageURL: URL? = nil

    /// Official appointment end — duration only. Extra before/after pad the calendar block.
    var end: Date {
        start.addingTimeInterval(TimeInterval(durationMinutes * 60))
    }

    /// Drive and leave-by target. Check-in if the portal named one; otherwise official start.
    var arrivalTarget: Date { arriveBy ?? start }

    /// Minutes from check-in to official start. Home-gap uses this; the extra-before chip does not.
    var checkInLeadMinutes: Int {
        guard let arriveBy else { return 0 }
        return max(0, Int(start.timeIntervalSince(arriveBy) / 60))
    }

    /// Review always renders `start` as a day plus a clock time (date picker, typed
    /// start/end, and "Sep 17, 2026 at 10:16 AM – 11:16 AM"). Confirm and drive-time
    /// follow that displayed window. Extractor `hasDate`/`hasTime` stay false when the
    /// original text omitted them — that must not block save or hide drive time.
    var hasDisplayedDateAndTime: Bool {
        durationMinutes > 0
    }

    /// Copies the on-screen date and clock values into the save flags so CalendarStore's
    /// date+time requirement matches what is already on the Review card.
    mutating func acceptDisplayedDateAndTime() {
        hasDate = true
        hasTime = true
    }

    /// Start field: a clock keeps duration (assumed 1 hour stays assumed); "6-9" sets both ends.
    @discardableResult
    mutating func applyTypedStart(_ text: String) -> Bool {
        guard let parsed = ReviewTimeTyping.parseAppointment(text) else { return false }
        applyTypedAppointment(parsed, asEnd: false)
        return true
    }

    /// End field: a clock sets duration from the current start; a range like "6-9" sets both.
    @discardableResult
    mutating func applyTypedEnd(_ text: String) -> Bool {
        guard let parsed = ReviewTimeTyping.parseAppointment(text) else { return false }
        applyTypedAppointment(parsed, asEnd: true)
        return true
    }

    @discardableResult
    mutating func applyTypedExtraBefore(_ text: String) -> Bool {
        guard let minutes = ReviewTimeTyping.parseExtraMinutes(text) else { return false }
        extraBeforeMinutes = minutes
        return true
    }

    @discardableResult
    mutating func applyTypedExtraAfter(_ text: String) -> Bool {
        guard let minutes = ReviewTimeTyping.parseExtraMinutes(text) else { return false }
        extraAfterMinutes = minutes
        return true
    }

    mutating func applyTypedAppointment(_ parsed: ReviewTimeTyping.Appointment, asEnd: Bool) {
        let calendar = Calendar.current
        hasTime = true
        switch parsed {
        case .window(let startHour, let startMinute, let endHour, let endMinute):
            setClock(hour: startHour, minute: startMinute, calendar: calendar)
            durationMinutes = max(
                1,
                ReviewTimeTyping.durationMinutes(
                    fromHour: startHour,
                    fromMinute: startMinute,
                    toHour: endHour,
                    toMinute: endMinute,
                    wrapHours: 12
                )
            )
            durationAssumed = false
        case .clock(let hour, let minute, let resolved):
            if asEnd {
                let startHour = calendar.component(.hour, from: start)
                let startMinute = calendar.component(.minute, from: start)
                let end = ReviewTimeTyping.resolve(
                    hour: hour,
                    minute: minute,
                    resolved: resolved,
                    like: start
                )
                durationMinutes = max(
                    1,
                    ReviewTimeTyping.durationMinutes(
                        fromHour: startHour,
                        fromMinute: startMinute,
                        toHour: end.hour,
                        toMinute: end.minute,
                        wrapHours: resolved ? 24 : 12
                    )
                )
                durationAssumed = false
            } else {
                let clock = ReviewTimeTyping.resolve(
                    hour: hour,
                    minute: minute,
                    resolved: resolved,
                    like: start
                )
                setClock(hour: clock.hour, minute: clock.minute, calendar: calendar)
            }
        }
    }

    private mutating func setClock(hour: Int, minute: Int, calendar: Calendar) {
        var parts = calendar.dateComponents([.year, .month, .day], from: start)
        parts.hour = hour
        parts.minute = minute
        parts.second = 0
        start = calendar.date(from: parts) ?? start
    }

    var calendarTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    /// Resolved "Name · Address" when MapKit found a nearby match; otherwise the raw location.
    var locationToSave: String {
        let resolved = resolvedLocation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !resolved.isEmpty { return resolved }
        return location.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func applyResolvedPlace(_ place: ResolvedPlace) {
        resolvedLocation = place.displayLine
        resolvedCaption = place.caption
        locationLatitude = place.latitude
        locationLongitude = place.longitude
    }

    mutating func applyRememberedPlace(_ place: RememberedPlace) {
        resolvedLocation = place.location
        resolvedCaption = ScedraString("Remembered")
        locationLatitude = place.latitude
        locationLongitude = place.longitude
        if location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || PlaceMemory.memoryKey(from: location) == PlaceMemory.memoryKey(from: title) {
            location = place.location
        }
    }

    mutating func clearResolvedPlace() {
        resolvedLocation = nil
        resolvedCaption = nil
        locationLatitude = nil
        locationLongitude = nil
    }

    func asHomeGapStop() -> HomeGapStop {
        let place = locationToSave
        return HomeGapStop(
            id: id.uuidString,
            title: calendarTitle,
            place: place,
            officialStart: start,
            officialEnd: end,
            extraBeforeMinutes: extraBeforeMinutes + checkInLeadMinutes,
            extraAfterMinutes: extraAfterMinutes,
            latitude: locationLatitude,
            longitude: locationLongitude,
            usesHome: place.isEmpty || HomeGapLogic.looksLikeHome(place),
            notes: (details + [sourceText]).joined(separator: "\n")
        )
    }
}

/// Typed Review clocks: "2:30 PM", "14:30", "6-9". Extra minutes are not Maps drive time.
enum ReviewTimeTyping {
    enum Appointment: Equatable {
        /// A single clock. `resolved` means she stated AM/PM or a 24-hour time.
        case clock(hour: Int, minute: Int, resolved: Bool)
        /// Official start and end, as with "6-9".
        case window(startHour: Int, startMinute: Int, endHour: Int, endMinute: Int)
    }

    static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseAppointment(_ text: String) -> Appointment? {
        let trimmed = normalize(text)
        guard !trimmed.isEmpty else { return nil }

        if let range = TimeRangeParser.parse(trimmed) {
            return .window(
                startHour: range.startHour,
                startMinute: range.startMinute,
                endHour: range.endHour,
                endMinute: range.endMinute
            )
        }
        if let clock = parseStandaloneClock(trimmed) {
            return clock
        }
        if let clock = ClockTimeParser.parse(trimmed) {
            return .clock(hour: clock.hour, minute: clock.minute, resolved: true)
        }
        if let clock = parseLocaleClock(trimmed) {
            return clock
        }
        return nil
    }

    /// Same FormatStyle Review uses to fill the start/end fields. A German or
    /// French clock must still parse so Confirm can save.
    static func parseLocaleClock(_ text: String, locale: Locale = .current) -> Appointment? {
        let trimmed = normalize(text)
        guard !trimmed.isEmpty else { return nil }
        let style = Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
        guard let parsed = try? Date(trimmed, strategy: style) else { return nil }
        let calendar = Calendar.current
        return .clock(
            hour: calendar.component(.hour, from: parsed),
            minute: calendar.component(.minute, from: parsed),
            resolved: true
        )
    }

    static func parseExtraMinutes(_ text: String) -> Int? {
        let trimmed = normalize(text).lowercased()
        if trimmed.isEmpty { return 0 }
        if let hours = firstInteger(pattern: #"^\s*(\d+)\s*(?:h|hr|hrs|hour|hours)\s*$"#, in: trimmed) {
            return clampExtra(hours * 60)
        }
        if let minutes = firstInteger(
            pattern: #"^\s*(\d+)\s*(?:m|min|mins|minute|minutes)?\s*$"#,
            in: trimmed
        ) {
            return clampExtra(minutes)
        }
        return nil
    }

    static func resolve(
        hour: Int,
        minute: Int,
        resolved: Bool,
        like reference: Date,
        calendar: Calendar = .current
    ) -> (hour: Int, minute: Int) {
        if resolved { return (hour, minute) }
        let refHour = calendar.component(.hour, from: reference)
        var hour = hour % 12
        if refHour >= 12 { hour += 12 }
        return (hour, minute)
    }

    static func durationMinutes(
        fromHour: Int,
        fromMinute: Int,
        toHour: Int,
        toMinute: Int,
        wrapHours: Int
    ) -> Int {
        let start = fromHour * 60 + fromMinute
        var end = toHour * 60 + toMinute
        let wrap = max(wrapHours, 1) * 60
        while end <= start {
            end += wrap
        }
        return end - start
    }

    static func clocksMatch(_ typed: String, formatted: String) -> Bool {
        let typed = normalize(typed)
        let formatted = normalize(formatted)
        if typed.localizedCaseInsensitiveCompare(formatted) == .orderedSame {
            return true
        }
        let compactTyped = typed.filter { !$0.isWhitespace && !$0.isPunctuation }
        let compactFormatted = formatted.filter { !$0.isWhitespace && !$0.isPunctuation }
        return !compactTyped.isEmpty
            && compactTyped.localizedCaseInsensitiveCompare(compactFormatted) == .orderedSame
    }

    private static func parseStandaloneClock(_ text: String) -> Appointment? {
        let lowered = text.lowercased()
        if lowered == "noon" {
            return .clock(hour: 12, minute: 0, resolved: true)
        }
        if lowered == "midnight" {
            return .clock(hour: 0, minute: 0, resolved: true)
        }

        let pattern = #"(?i)^\s*(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*((?:a|p)\.?m\.?)?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: full) else { return nil }

        func int(at index: Int) -> Int? {
            let range = match.range(at: index)
            guard range.location != NSNotFound else { return nil }
            return Int(nsText.substring(with: range))
        }

        guard let hourRaw = int(at: 1), (0...23).contains(hourRaw) else { return nil }
        let minute: Int = {
            let range = match.range(at: 2)
            guard range.location != NSNotFound, range.length > 0 else { return 0 }
            return Int(nsText.substring(with: range)) ?? 0
        }()
        guard minute < 60 else { return nil }

        let merRange = match.range(at: 3)
        let meridian: String? = {
            guard merRange.location != NSNotFound, merRange.length > 0 else { return nil }
            return nsText.substring(with: merRange)
        }()
        let hasMinutes = match.range(at: 2).location != NSNotFound
        if hourRaw > 12, !hasMinutes, meridian == nil { return nil }

        let applied = ClockTimeParser.applyMeridian(hour: hourRaw, minute: minute, meridian: meridian)
        if meridian != nil || hourRaw == 0 || hourRaw > 12 {
            return .clock(hour: applied.hour, minute: applied.minute, resolved: true)
        }
        // Bare 1–5 is afternoon; 10/11 stay late morning and must not flip to PM.
        if (1...5).contains(hourRaw) || (10...11).contains(hourRaw) {
            return .clock(hour: applied.hour, minute: applied.minute, resolved: true)
        }
        return .clock(hour: applied.hour, minute: applied.minute, resolved: false)
    }

    private static func firstInteger(pattern: String, in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: full),
              match.numberOfRanges >= 2
        else { return nil }
        let range = match.range(at: 1)
        guard range.location != NSNotFound else { return nil }
        return Int(nsText.substring(with: range))
    }

    private static func clampExtra(_ minutes: Int) -> Int {
        min(max(minutes, 0), 180)
    }
}
