import Foundation

enum TimeRangeParser {
    struct Result: Equatable {
        var startHour: Int
        var startMinute: Int
        var endHour: Int
        var endMinute: Int
        var nsRange: NSRange

        var durationMinutes: Int {
            let start = startHour * 60 + startMinute
            var end = endHour * 60 + endMinute
            while end <= start {
                end += 12 * 60
            }
            return end - start
        }

        func startDate(on day: Date, calendar: Calendar = .current) -> Date {
            calendar.date(bySettingHour: startHour, minute: startMinute, second: 0, of: day) ?? day
        }
    }

    static func parse(_ text: String) -> Result? {
        let pattern = #"(?i)(?:\bfrom\s+)?(\d{1,2})(?::(\d{2}))?\s*((?:a|p)\.?m\.?)?\s*(?:-|–|—|\bto\b)\s*(\d{1,2})(?::(\d{2}))?\s*((?:a|p)\.?m\.?)?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: full), match.numberOfRanges >= 6 else {
            return nil
        }
        // Ignore fragments of ISO dates like 2026-09-14.
        if match.range.location > 0 {
            let prev = nsText.character(at: match.range.location - 1)
            if prev == 45 || prev == 8211 || prev == 8212 { return nil }
        }

        func int(at index: Int) -> Int {
            let range = match.range(at: index)
            guard range.location != NSNotFound else { return 0 }
            return Int(nsText.substring(with: range)) ?? 0
        }

        func meridian(at index: Int) -> String? {
            let range = match.range(at: index)
            guard range.location != NSNotFound, range.length > 0 else { return nil }
            return nsText.substring(with: range)
        }

        let startHourRaw = int(at: 1)
        let startMinute = match.range(at: 2).location == NSNotFound ? 0 : int(at: 2)
        let endHourRaw = int(at: 4)
        let endMinute = match.range(at: 5).location == NSNotFound ? 0 : int(at: 5)
        guard (1...12).contains(startHourRaw) || (0...23).contains(startHourRaw) else { return nil }
        guard (1...12).contains(endHourRaw) || (0...23).contains(endHourRaw) else { return nil }
        guard startHourRaw <= 23, endHourRaw <= 23, startMinute < 60, endMinute < 60 else { return nil }
        let startHasMinutes = match.range(at: 2).location != NSNotFound
        let endHasMinutes = match.range(at: 5).location != NSNotFound
        if startHourRaw > 12, !startHasMinutes, meridian(at: 3) == nil { return nil }
        if endHourRaw > 12, !endHasMinutes, meridian(at: 6) == nil { return nil }

        let startMer = meridian(at: 3)
        let endMer = meridian(at: 6)
        var start = ClockTimeParser.applyMeridian(
            hour: startHourRaw,
            minute: startMinute,
            meridian: startMer ?? endMer
        )
        var end = ClockTimeParser.applyMeridian(
            hour: endHourRaw,
            minute: endMinute,
            meridian: endMer ?? startMer
        )
        // Bare 6–9 is dinner/evening, not 6 AM. 9–11 stays late morning.
        if startMer == nil, endMer == nil,
           (6...9).contains(startHourRaw), (6...9).contains(endHourRaw) {
            start.hour += 12
            end.hour += 12
        }
        return Result(
            startHour: start.hour,
            startMinute: start.minute,
            endHour: end.hour,
            endMinute: end.minute,
            nsRange: match.range
        )
    }
}

/// A single clock time ("2pm", "at 4", "four") as opposed to a start–end range.
enum ClockTimeParser {
    struct Result: Equatable {
        var hour: Int
        var minute: Int
        var nsRange: NSRange

        func startDate(on day: Date, calendar: Calendar = .current) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }

        func matchedText(in text: String) -> String {
            let nsText = text as NSString
            guard nsRange.location != NSNotFound, NSMaxRange(nsRange) <= nsText.length else { return "" }
            return nsText.substring(with: nsRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static let spokenHours: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "noon": 12, "midnight": 0
    ]

    /// Last clock in the string. Spoken/typed phrases often put the time at the end.
    static func parse(_ text: String) -> Result? {
        all(in: text).last
    }

    static func first(in text: String) -> Result? {
        all(in: text).first
    }

    /// Chronologically latest clock, regardless of reading order.
    static func latest(in text: String) -> Result? {
        all(in: text).max { lhs, rhs in
            lhs.hour * 60 + lhs.minute < rhs.hour * 60 + rhs.minute
        }
    }

    /// Agreed appointment clocks. Skips iMessage “Read 3:26PM”, status-bar
    /// stamps, and “opens at 9:30”.
    static func appointmentClocks(in text: String) -> [Result] {
        all(in: text).filter { !isReceiptOrStatus($0, in: text) }
    }

    /// Last agreed appointment clock. Skips iMessage “Read 3:26PM” and prefers
    /// a time sitting next to a weekday (“11am on saturday”).
    static func appointmentClock(in text: String) -> Result? {
        let clocks = appointmentClocks(in: text)
        guard !clocks.isEmpty else { return nil }
        let besideWeekday = clocks.filter { adjacentToWeekday($0, in: text) }
        if let agreed = besideWeekday.last { return agreed }
        return clocks.last
    }

    private static func isReceiptOrStatus(_ clock: Result, in text: String) -> Bool {
        let nsText = text as NSString
        guard clock.nsRange.location != NSNotFound else { return false }
        let start = max(0, clock.nsRange.location - 16)
        let prefix = nsText.substring(with: NSRange(location: start, length: clock.nsRange.location - start))
            .lowercased()
        if prefix.range(of: #"\bread\s*$"#, options: .regularExpression) != nil { return true }
        if prefix.range(of: #"(?i)\b(delivered|liked|loved)\s*$"#, options: .regularExpression) != nil {
            return true
        }
        if prefix.range(of: #"(?i)\bopens?\s*(?:at\s*)?$"#, options: .regularExpression) != nil {
            return true
        }
        let matched = clock.matchedText(in: text).lowercased()
        let named = matched.hasPrefix("at") || matched.hasPrefix("from")
            || matched.hasPrefix("around") || matched.hasPrefix("@")
        if !named, prefix.range(of: #"(?i)\b(yesterday|today)\s*$"#, options: .regularExpression) != nil {
            return true
        }
        if clock.nsRange.location <= 5, !named, matched.contains(":"),
           !matched.contains("am"), !matched.contains("pm") {
            return true
        }
        return false
    }

    private static func adjacentToWeekday(_ clock: Result, in text: String) -> Bool {
        let nsText = text as NSString
        guard clock.nsRange.location != NSNotFound else { return false }
        let windowStart = max(0, clock.nsRange.location - 24)
        let windowEnd = min(nsText.length, NSMaxRange(clock.nsRange) + 24)
        let snippet = nsText.substring(with: NSRange(location: windowStart, length: windowEnd - windowStart))
        return snippet.range(
            of: #"(?i)\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)\b"#,
            options: .regularExpression
        ) != nil
    }

    /// Clocks in reading order, overlapping regex hits collapsed to one token.
    static func all(in text: String) -> [Result] {
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        var found: [Result] = []

        func addMatches(pattern: String, read: (NSTextCheckingResult, NSString) -> Result?) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            for match in regex.matches(in: text, options: [], range: full) {
                if let result = read(match, nsText) {
                    found.append(result)
                }
            }
        }

        addMatches(
            pattern: #"(?i)(?:\b(?:at|from|around)\s+|@\s*)(\d{1,2})(?::(\d{2}))?\s*((?:a|p)\.?m\.?)?\b"#
        ) { match, ns in numericClock(in: match, nsText: ns, hourAt: 1, minuteAt: 2, meridianAt: 3) }

        addMatches(
            pattern: #"(?i)\b(\d{1,2})(?::(\d{2}))?\s*((?:a|p)\.?m\.?)\b"#
        ) { match, ns in numericClock(in: match, nsText: ns, hourAt: 1, minuteAt: 2, meridianAt: 3) }

        addMatches(
            pattern: #"(?i)\b(\d{1,2}):(\d{2})\b"#
        ) { match, ns in numericClock(in: match, nsText: ns, hourAt: 1, minuteAt: 2, meridianAt: nil) }

        addMatches(
            pattern: #"(?i)(?:\b(?:at|from)\s+|@\s*)(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|noon|midnight)(?:\s+o'?clock)?\s*((?:a|p)\.?m\.?)?\b"#
        ) { match, ns in spokenClock(in: match, nsText: ns, wordAt: 1, meridianAt: 2) }

        addMatches(
            pattern: #"(?i)\b(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|noon|midnight)\s+o'?clock\s*((?:a|p)\.?m\.?)?\b"#
        ) { match, ns in spokenClock(in: match, nsText: ns, wordAt: 1, meridianAt: 2) }

        addMatches(
            pattern: #"(?i)\b(\d{1,2})(?::(\d{2}))?\s*$"#
        ) { match, ns in
            guard match.range.location > 0 else { return nil }
            // "March 4" is a day, not 4 o'clock.
            let prefix = ns.substring(to: match.range.location)
            if lastWordIsMonth(prefix) { return nil }
            return numericClock(in: match, nsText: ns, hourAt: 1, minuteAt: 2, meridianAt: nil)
        }

        addMatches(
            pattern: #"(?i)\b(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|noon|midnight)\s*$"#
        ) { match, ns in
            guard match.range.location > 0 else { return nil }
            return spokenClock(in: match, nsText: ns, wordAt: 1, meridianAt: nil)
        }

        let ordered = found.sorted { lhs, rhs in
            if lhs.nsRange.location != rhs.nsRange.location {
                return lhs.nsRange.location < rhs.nsRange.location
            }
            return lhs.nsRange.length > rhs.nsRange.length
        }
        var unique: [Result] = []
        for clock in ordered {
            if unique.contains(where: { NSIntersectionRange($0.nsRange, clock.nsRange).length > 0 }) {
                continue
            }
            unique.append(clock)
        }
        return unique
    }

    private static func numericClock(
        in match: NSTextCheckingResult,
        nsText: NSString,
        hourAt: Int,
        minuteAt: Int,
        meridianAt: Int?
    ) -> Result? {
        let hourRange = match.range(at: hourAt)
        guard hourRange.location != NSNotFound else { return nil }
        let hourRaw = Int(nsText.substring(with: hourRange)) ?? -1
        let minute: Int = {
            guard match.numberOfRanges > minuteAt else { return 0 }
            let range = match.range(at: minuteAt)
            guard range.location != NSNotFound, range.length > 0 else { return 0 }
            return Int(nsText.substring(with: range)) ?? 0
        }()
        guard hourRaw >= 0, hourRaw <= 23, minute < 60 else { return nil }
        let minuteMissing = minuteAt >= match.numberOfRanges || match.range(at: minuteAt).location == NSNotFound
        if hourRaw > 12, minuteMissing, meridian(in: match, nsText: nsText, at: meridianAt) == nil {
            return nil
        }
        if hourRaw == 0, meridian(in: match, nsText: nsText, at: meridianAt) == nil, minuteMissing {
            return nil
        }
        let mer = meridian(in: match, nsText: nsText, at: meridianAt)
        let applied = applyMeridian(hour: hourRaw, minute: minute, meridian: mer)
        return Result(hour: applied.hour, minute: applied.minute, nsRange: match.range)
    }

    /// Explicit am/pm or 24-hour wins. Bare 1–5 is afternoon (1 → 13:00), never 1 AM.
    /// Bare 10/11 stay late morning unless a range only fits evening.
    static func applyMeridian(hour: Int, minute: Int, meridian: String?) -> (hour: Int, minute: Int) {
        let token = meridian?
            .lowercased()
            .replacingOccurrences(of: ".", with: "")
            .trimmingCharacters(in: .whitespaces)
        var hour = hour
        if let token, !token.isEmpty {
            if token.hasPrefix("p"), hour < 12 {
                hour += 12
            } else if token.hasPrefix("a"), hour == 12 {
                hour = 0
            }
            return (hour, minute)
        }
        if (1...5).contains(hour) {
            hour += 12
        }
        return (hour, minute)
    }

    private static func spokenClock(
        in match: NSTextCheckingResult,
        nsText: NSString,
        wordAt: Int,
        meridianAt: Int?
    ) -> Result? {
        let range = match.range(at: wordAt)
        guard range.location != NSNotFound else { return nil }
        let word = nsText.substring(with: range).lowercased()
        guard let hourRaw = spokenHours[word] else { return nil }
        let mer = meridian(in: match, nsText: nsText, at: meridianAt)
        let applied = applyMeridian(hour: hourRaw, minute: 0, meridian: mer)
        return Result(hour: applied.hour, minute: applied.minute, nsRange: match.range)
    }

    private static func meridian(in match: NSTextCheckingResult, nsText: NSString, at index: Int?) -> String? {
        guard let index, match.numberOfRanges > index else { return nil }
        let range = match.range(at: index)
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        return nsText.substring(with: range)
    }

    private static let monthWords: Set<String> = [
        "jan", "january", "feb", "february", "mar", "march", "apr", "april", "may",
        "jun", "june", "jul", "july", "aug", "august", "sep", "sept", "september",
        "oct", "october", "nov", "november", "dec", "december"
    ]

    private static func lastWordIsMonth(_ prefix: String) -> Bool {
        let word = prefix
            .split { $0.isWhitespace }
            .last?
            .lowercased()
            .trimmingCharacters(in: .punctuationCharacters) ?? ""
        return monthWords.contains(word)
    }
}

enum EventExtractor {
    /// One appointment's words split into the human part and the place.
    /// Neither half may contain the other, or the map search gets the wrong string.
    struct TitlePlace: Equatable {
        var title: String
        var place: String
    }

    static func drafts(from text: String) -> [DraftEvent] {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return [] }
        let cards = CalendarCardParser.drafts(from: original)
        if !cards.isEmpty { return cards }
        let trimmed = OCRTextNormalizer.normalize(original)

        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue | NSTextCheckingResult.CheckingType.address.rawValue)
        let nsText = trimmed as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = detector?.matches(in: trimmed, options: [], range: fullRange) ?? []

        let dateMatches = matches.filter { $0.resultType.contains(.date) && $0.date != nil }
        let addresses = matches.compactMap { match -> String? in
            guard match.resultType.contains(.address) else { return nil }
            return formattedAddress(match) ?? nsText.substring(with: match.range)
        }

        let dateRanges = dateMatches.map(\.range)
        let dateSpans = dateRanges.map { dateOnlyRange(of: $0, in: nsText) }

        let timeRange = TimeRangeParser.parse(trimmed)
        if let timeRange, isSingleAppointment(dateMatches) {
            return [
                draftFromTimeRange(
                    timeRange,
                    text: original,
                    nsText: nsText,
                    dateMatches: dateMatches,
                    dateSpans: dateSpans,
                    addresses: addresses
                )
            ]
        }

        let clock = ClockTimeParser.appointmentClock(in: trimmed) ?? ClockTimeParser.parse(trimmed)
        if let clock, isSingleAppointment(dateMatches) {
            return [
                draftFromClock(
                    clock,
                    text: original,
                    nsText: nsText,
                    dateMatches: dateMatches,
                    dateSpans: dateSpans,
                    addresses: addresses
                )
            ]
        }

        if dateMatches.isEmpty {
            let split = titleAndPlace(in: trimmed)
            return [
                DraftEvent(
                    title: split.title,
                    start: Date(),
                    durationMinutes: 60,
                    durationAssumed: true,
                    location: addresses.first ?? split.place,
                    sourceText: original,
                    hasDate: mentionsRelativeDate(trimmed),
                    hasTime: false
                )
            ]
        }

        return dateMatches.enumerated().map { index, match in
            let date = match.date ?? Date()
            let snippet = nsText.substring(with: match.range)
            var hasTime = timeIsPresent(in: snippet, date: date)
            var assumed = match.duration <= 0
            var minutes = assumed ? 60 : max(Int((match.duration / 60).rounded()), 1)
            var start = date
            var blanked: [NSRange] = []

            // An explicit range ("6-9") belongs to the appointment whose text contains it.
            if let timeRange,
               rangeBelongs(timeRange.nsRange, toDateAt: index, dates: dateMatches, textLength: nsText.length) {
                start = timeRange.startDate(on: date)
                minutes = timeRange.durationMinutes
                assumed = false
                hasTime = true
                blanked.append(timeRange.nsRange)
            } else if let clock,
                      rangeBelongs(clock.nsRange, toDateAt: index, dates: dateMatches, textLength: nsText.length) {
                start = clock.startDate(on: date)
                hasTime = true
                blanked.append(clock.nsRange)
            }

            let split = titleAndPlace(
                in: remainder(
                    in: nsText,
                    dateSpans: dateSpans,
                    dateRanges: dateRanges,
                    index: index,
                    blanking: blanked
                )
            )

            return DraftEvent(
                title: split.title,
                start: start,
                durationMinutes: minutes,
                durationAssumed: assumed,
                location: addresses.first ?? split.place,
                sourceText: original,
                hasDate: true,
                hasTime: hasTime
            )
        }
    }

    /// "Wed, Sep 23, 12:00–1:00 PM" often yields two detector hits (start and end).
    /// That is still one appointment, not two.
    private static func isSingleAppointment(
        _ dates: [NSTextCheckingResult],
        calendar: Calendar = .current
    ) -> Bool {
        if dates.count <= 1 { return true }
        guard dates.count == 2, let first = dates[0].date, let second = dates[1].date else {
            return false
        }
        return calendar.isDate(first, inSameDayAs: second)
    }

    private static func draftFromTimeRange(
        _ range: TimeRangeParser.Result,
        text: String,
        nsText: NSString,
        dateMatches: [NSTextCheckingResult],
        dateSpans: [NSRange],
        addresses: [String]
    ) -> DraftEvent {
        let daySource = dateMatches.first?.date ?? Date()
        let start = range.startDate(on: daySource)
        let split = titleAndPlace(
            in: remainder(
                in: nsText,
                dateSpans: dateSpans,
                dateRanges: dateMatches.map(\.range),
                index: 0,
                blanking: [range.nsRange]
            )
        )
        return DraftEvent(
            title: split.title,
            start: start,
            durationMinutes: range.durationMinutes,
            durationAssumed: false,
            location: addresses.first ?? split.place,
            sourceText: text,
            hasDate: !dateMatches.isEmpty || mentionsRelativeDate(text),
            hasTime: true
        )
    }

    private static func draftFromClock(
        _ clock: ClockTimeParser.Result,
        text: String,
        nsText: NSString,
        dateMatches: [NSTextCheckingResult],
        dateSpans: [NSRange],
        addresses: [String]
    ) -> DraftEvent {
        let daySource = dateMatches.first?.date ?? Date()
        let start = clock.startDate(on: daySource)
        let split = titleAndPlace(
            in: remainder(
                in: nsText,
                dateSpans: dateSpans,
                dateRanges: dateMatches.map(\.range),
                index: 0,
                blanking: [clock.nsRange]
            )
        )
        return DraftEvent(
            title: split.title,
            start: start,
            durationMinutes: 60,
            durationAssumed: true,
            location: addresses.first ?? split.place,
            sourceText: text,
            hasDate: !dateMatches.isEmpty || mentionsRelativeDate(text),
            hasTime: true
        )
    }

    // MARK: - Title vs place

    /// `remainder` is one appointment's words with its date and time already blanked out,
    /// so any surviving "at" introduces a place rather than a time.
    static func titleAndPlace(in remainder: String) -> TitlePlace {
        var body = remainder.replacingOccurrences(of: ",", with: " ")
        body = withoutLeftoverDateTime(body)
        body = withoutSpokenFiller(body)
        body = body
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let split = placePrepositionSplit(in: body) {
            let place = cleanedPlace(split.place)
            if !place.isEmpty {
                let title = cleanedTitle(split.title)
                return applyingMemory(TitlePlace(title: title.isEmpty ? place : title, place: place))
            }
        }

        if let split = juxtaposedPlaceSplit(in: body) {
            let title = cleanedTitle(split.title)
            let place = cleanedPlace(split.place)
            if !title.isEmpty, !place.isEmpty {
                return applyingMemory(TitlePlace(title: title, place: place))
            }
        }

        // Nothing marks a boundary ("westwind community barn tomorrow at 4"):
        // the same words are both the title and the place.
        return applyingMemory(TitlePlace(title: cleanedTitle(body), place: cleanedPlace(body)))
    }

    /// The first "at"/"@" that is not a clock time introduces the place.
    /// "in"/"near" only split when the words before them are the appointment, not a brand.
    private static func placePrepositionSplit(in text: String) -> (title: String, place: String)? {
        let words = text.split { $0.isWhitespace }.map(String.init)
        guard words.count >= 2 else { return nil }

        for index in 0..<(words.count - 1) {
            let marker = folded(words[index])
            let tail = Array(words[(index + 1)...])
            guard !tail.isEmpty, !looksLikeClock(tail) else { continue }

            if placeIntroducers.contains(marker) {
                return (words[0..<index].joined(separator: " "), tail.joined(separator: " "))
            }
            if areaIntroducers.contains(marker) {
                let leftWords = Array(words[0..<index])
                let left = leftWords.joined(separator: " ")
                guard looksLikeActivity(leftWords), !isBrandOnly(left) else { continue }
                return (left, tail.joined(separator: " "))
            }
        }
        return nil
    }

    /// No "at" — try the longest trailing span that looks like a venue, so
    /// "horse show westwind community barn" and "lunch mcdonalds menlo park" both split.
    private static func juxtaposedPlaceSplit(in text: String) -> (title: String, place: String)? {
        let words = text.split { $0.isWhitespace }.map(String.init)
        guard words.count >= 2 else { return nil }

        // Longest place first: drop one leading title word, then two, and so on.
        for placeStart in 1..<words.count {
            let title = Array(words[0..<placeStart])
            let place = Array(words[placeStart...])
            guard looksLikeActivity(title) else { continue }
            guard looksLikeVenue(place) else { continue }
            guard place.count >= 2 || isStrongPlaceWord(place[0]) else { continue }
            return (title.joined(separator: " "), place.joined(separator: " "))
        }
        return nil
    }

    /// A short leftover like "barn" can be a nickname for a place she already saved.
    /// Title-only leftovers ("dentist") stay as her words — Review fills those in.
    private static func applyingMemory(_ split: TitlePlace) -> TitlePlace {
        let placeKey = folded(split.place)
        let titleKey = folded(split.title)
        guard !placeKey.isEmpty, placeKey != titleKey else { return split }
        let placeWords = split.place.split { $0.isWhitespace }
        guard placeWords.count <= 2, !PlaceMemory.isGenericPOI(split.place) else { return split }
        guard let remembered = PlaceMemory.remembered(matchingPlaceQuery: split.place) else { return split }
        return TitlePlace(title: split.title, place: remembered.location)
    }

    /// Her own wording, minus dangling connectives left behind by the place and date.
    /// Articles stay: "the dentist" is what she said.
    private static func cleanedTitle(_ raw: String) -> String {
        let words = trimmingEdgeWords(in: raw, using: titleEdgeWords)
        return words
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// The venue only: no leading "the", no dangling "on"/"at" from the date that followed.
    private static func cleanedPlace(_ raw: String) -> String {
        let words = trimmingEdgeWords(in: raw, using: placeEdgeWords)
        // A run this long is a sentence, not a place name.
        guard !words.isEmpty, words.count <= 8 else { return "" }
        return words.joined(separator: " ")
    }

    private static func trimmingEdgeWords(in raw: String, using edge: Set<String>) -> [String] {
        var words = raw.split { $0.isWhitespace }.map(String.init)
        while let first = words.first, edge.contains(folded(first)) { words.removeFirst() }
        while let last = words.last, edge.contains(folded(last)) { words.removeLast() }
        return words
    }

    // MARK: - Date and time removal

    /// NSDataDetector usually swallows the word in front of the date: the whole of
    /// "lunch today at 1" comes back as one match. Hand the leading non-date words
    /// back so they can become the title.
    private static func dateOnlyRange(of range: NSRange, in text: NSString) -> NSRange {
        guard NSMaxRange(range) <= text.length else { return range }
        let snippet = text.substring(with: range)
        var consumed = 0
        var index = snippet.startIndex

        while index < snippet.endIndex {
            while index < snippet.endIndex, snippet[index].isWhitespace {
                index = snippet.index(after: index)
            }
            var end = index
            while end < snippet.endIndex, !snippet[end].isWhitespace {
                end = snippet.index(after: end)
            }
            guard end > index else { break }
            if isDateTimeWord(String(snippet[index..<end])) { break }
            consumed = snippet.distance(from: snippet.startIndex, to: end)
            index = end
        }

        guard consumed > 0 else { return range }
        let offset = (String(snippet.prefix(consumed)) as NSString).length
        guard offset < range.length else { return range }
        return NSRange(location: range.location + offset, length: range.length - offset)
    }

    /// Everything belonging to appointment `index`, with its own date, time and any
    /// explicit range blanked out. Blanks keep their width so the ranges stay valid.
    private static func remainder(
        in text: NSString,
        dateSpans: [NSRange],
        dateRanges: [NSRange],
        index: Int,
        blanking extra: [NSRange]
    ) -> String {
        var lower = 0
        if index > 0, index - 1 < dateSpans.count {
            let gap = gapRange(from: dateSpans[index - 1], to: dateRanges[index], in: text)
            lower = separator(in: gap, of: text).map(NSMaxRange) ?? gap.location
        }
        var upper = text.length
        if index + 1 < dateRanges.count, index < dateSpans.count {
            let gap = gapRange(from: dateSpans[index], to: dateRanges[index + 1], in: text)
            upper = separator(in: gap, of: text)?.location ?? NSMaxRange(gap)
        }
        guard upper > lower else { return "" }

        let segment = NSRange(location: lower, length: upper - lower)
        let body = NSMutableString(string: text.substring(with: segment))
        var blanks = extra
        if index < dateSpans.count { blanks.append(dateSpans[index]) }

        for blank in blanks {
            let overlap = NSIntersectionRange(blank, segment)
            guard overlap.length > 0 else { continue }
            let local = NSRange(location: overlap.location - segment.location, length: overlap.length)
            guard NSMaxRange(local) <= body.length else { continue }
            body.replaceCharacters(in: local, with: String(repeating: " ", count: local.length))
        }
        return String(body)
    }

    private static func gapRange(from previous: NSRange, to next: NSRange, in text: NSString) -> NSRange {
        let start = min(NSMaxRange(previous), text.length)
        let end = min(max(next.location, start), text.length)
        return NSRange(location: start, length: end - start)
    }

    /// She separates one appointment from the next with a line break, a comma or "and".
    /// The words after the last separator belong to the appointment that follows.
    private static func separator(in gap: NSRange, of text: NSString) -> NSRange? {
        guard gap.length > 0 else { return nil }
        let pattern = #"(?i)(?:[\r\n.;,]|\band\b|\bthen\b|\balso\b)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.matches(in: text as String, options: [], range: gap).last?.range
    }

    /// Mops up the date and time words NSDataDetector did not claim, so that what is
    /// left is only the title and the place.
    private static func withoutLeftoverDateTime(_ text: String) -> String {
        var value = text
        func blank(_ range: NSRange) {
            let mutable = NSMutableString(string: value)
            guard NSMaxRange(range) <= mutable.length else { return }
            mutable.replaceCharacters(in: range, with: " ")
            value = String(mutable)
        }
        if let range = TimeRangeParser.parse(value) {
            blank(range.nsRange)
        }
        if let clock = ClockTimeParser.parse(value) {
            blank(clock.nsRange)
        }
        value = value.replacingOccurrences(
            of: #"(?i)\b(today|tomorrow|tonight|yesterday|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#,
            with: " ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?i)\b(this|next|last)\s+(morning|afternoon|evening|night|week|month)?\b"#,
            with: " ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?i)\b(morning|afternoon|evening|night|noon|midnight)\b"#,
            with: " ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?i)\b(at|from|on)\s+\d{1,2}(?::\d{2})?\s*(?:a\.?m\.?|p\.?m\.?)?\b"#,
            with: " ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?i)\b\d{1,2}(?::\d{2})?\s*(?:a\.?m\.?|p\.?m\.?)\b"#,
            with: " ",
            options: .regularExpression
        )
        return value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// Drops um/uh/like and leading "i have a" so the title is her appointment, not the filler.
    private static func withoutSpokenFiller(_ text: String) -> String {
        var words = text.split { $0.isWhitespace }.map(String.init)
        words.removeAll { weakFillers.contains(folded($0)) }
        while let first = words.first, preambleFillers.contains(folded(first)) {
            words.removeFirst()
        }
        return words.joined(separator: " ")
    }

    private static func looksLikeClock(_ words: [String]) -> Bool {
        guard let first = words.first else { return false }
        let word = folded(first)
        if spokenHourWords.contains(word) { return true }
        if let hour = Int(word), (0...23).contains(hour) { return true }
        if word.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil { return true }
        return false
    }

    private static func looksLikeActivity(_ words: [String]) -> Bool {
        words.contains { activityWords.contains(folded($0)) }
    }

    private static func looksLikeVenue(_ words: [String]) -> Bool {
        guard !words.isEmpty else { return false }
        let joined = words.joined(separator: " ")
        if PlaceMemory.isGenericPOI(joined) || PlaceMemory.brandAndRemainder(in: joined) != nil {
            return true
        }
        if words.contains(where: { activityWords.contains(folded($0)) && !venueSuffixes.contains(folded($0)) }) {
            return false
        }
        if venueSuffixes.contains(folded(words.last ?? "")) { return true }
        if words.count >= 2, PlaceResolver.isDistinctiveVenue(joined) { return true }
        if words.count == 1 { return isStrongPlaceWord(words[0]) }
        return false
    }

    private static func isStrongPlaceWord(_ token: String) -> Bool {
        let word = folded(token)
        guard word.count >= 3, !activityWords.contains(word), !dateTimeWords.contains(word) else { return false }
        if PlaceMemory.isGenericPOI(word) || venueSuffixes.contains(word) { return true }
        if PlaceMemory.remembered(matchingPlaceQuery: token) != nil { return true }
        return word.count >= 4
    }

    private static func isBrandOnly(_ text: String) -> Bool {
        PlaceMemory.isGenericPOI(text) || PlaceMemory.brandAndRemainder(in: text) != nil
    }

    private static func isDateTimeWord(_ token: String) -> Bool {
        let word = folded(token)
        guard !word.isEmpty else { return false }
        if word.first?.isNumber == true { return true }
        if spokenHourWords.contains(word) { return true }
        return dateTimeWords.contains(word)
    }

    private static func folded(_ token: String) -> String {
        token.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    private static let placeIntroducers: Set<String> = ["at", "@"]
    private static let areaIntroducers: Set<String> = ["in", "near", "around"]

    private static let titleEdgeWords: Set<String> = [
        "at", "on", "in", "for", "from", "to", "and", "then", "also", "with", "of", "@"
    ]

    private static let placeEdgeWords: Set<String> = [
        "a", "an", "the", "at", "on", "in", "of", "for", "from", "to",
        "and", "then", "also", "with", "by", "near", "around", "@"
    ]

    private static let weakFillers: Set<String> = [
        "um", "uh", "er", "ah", "hmm", "like", "yeah", "yes", "okay", "ok",
        "hey", "yay", "well", "actually", "basically", "please"
    ]

    private static let preambleFillers: Set<String> = [
        "i", "i'm", "im", "ive", "i've", "i'd", "id", "we", "we'll",
        "just", "maybe", "so", "gonna", "gotta", "going", "have", "had",
        "got", "having", "there's", "there", "it's", "is", "a", "an"
    ]

    private static let spokenHourWords: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "eleven", "twelve", "noon", "midnight"
    ]

    /// Words that name what she is doing rather than where. Used only to find the
    /// boundary when she did not say "at".
    private static let activityWords: Set<String> = [
        "lesson", "lessons", "class", "classes", "practice", "rehearsal", "training", "session",
        "show", "competition", "match", "game", "tournament", "meet", "meeting", "clinic",
        "appointment", "appt", "checkup", "visit", "consult", "consultation", "exam",
        "interview", "call", "lunch", "dinner", "breakfast", "brunch", "coffee", "drinks",
        "party", "birthday", "wedding", "funeral", "haircut", "dentist", "doctor", "therapy",
        "physio", "vet", "ride", "riding", "workout", "yoga", "pilates", "swim",
        "recital", "concert", "service", "tour"
    ]

    private static let venueSuffixes: Set<String> = [
        "barn", "stables", "stable", "ranch", "center", "park", "clinic", "hospital",
        "studio", "church", "school", "library", "gym", "rink", "arena", "field",
        "hall", "theatre", "theater", "museum", "cafe", "café", "restaurant", "office",
        "campus", "station", "airport", "marina", "farm", "pavilion", "plaza", "market",
        "mall", "hotel", "inn", "spa", "salon", "bakery", "diner", "tavern", "lodge",
        "university", "college", "academy", "institute", "stadium", "club", "store",
        "shop", "pharmacy", "kitchen", "grind"
    ]

    private static let dateTimeWords: Set<String> = [
        "at", "on", "from", "to", "in", "this", "next", "last", "the", "of", "a", "an",
        "today", "tomorrow", "tonight", "yesterday", "morning", "afternoon", "evening",
        "night", "noon", "midnight", "am", "pm", "a.m", "p.m", "o'clock", "oclock",
        "early", "late",
        "mon", "tue", "tues", "wed", "weds", "thu", "thur", "thurs", "fri", "sat", "sun",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "jan", "january", "feb", "february", "mar", "march", "apr", "april", "may",
        "jun", "june", "jul", "july", "aug", "august", "sep", "sept", "september",
        "oct", "october", "nov", "november", "dec", "december"
    ]

    /// Text from the previous appointment's date up to the next one belongs to appointment `index`.
    private static func rangeBelongs(
        _ range: NSRange,
        toDateAt index: Int,
        dates: [NSTextCheckingResult],
        textLength: Int
    ) -> Bool {
        let lowerBound = index == 0 ? 0 : NSMaxRange(dates[index - 1].range)
        let upperBound = index + 1 < dates.count ? dates[index + 1].range.location : textLength
        return range.location >= lowerBound && NSMaxRange(range) <= upperBound
    }

    private static func mentionsRelativeDate(_ text: String) -> Bool {
        text.range(
            of: #"(?i)\b(today|tomorrow|tonight|yesterday|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#,
            options: .regularExpression
        ) != nil
    }

    private static func timeIsPresent(in snippet: String, date: Date) -> Bool {
        let pattern = #"(?i)(\d{1,2}:\d{2}|\b\d{1,2}\s*(a\.?m\.?|p\.?m\.?)\b|\bnoon\b|\bmidnight\b|\bmorning\b|\bafternoon\b|\bevening\b|\bat\s+\d{1,2}\b)"#
        if snippet.range(of: pattern, options: .regularExpression) != nil {
            return true
        }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) != 0 || (parts.minute ?? 0) != 0
    }

    private static func formattedAddress(_ match: NSTextCheckingResult) -> String? {
        guard let components = match.addressComponents else { return nil }
        let parts = [components[.street], components[.city], components[.state], components[.zip]]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
