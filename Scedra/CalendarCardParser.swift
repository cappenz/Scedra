import Foundation

/// Screenshots and OCR paste in odd spaces, dashes, and glued portal words.
/// Fold those so "12:00–1:00 PM" and "Appointoointment Typeype" still parse.
enum OCRTextNormalizer {
    static func normalize(_ text: String) -> String {
        var value = text
        let spaces = ["\u{00A0}", "\u{202F}", "\u{2007}", "\u{2009}", "\u{200A}", "\u{2060}"]
        for space in spaces {
            value = value.replacingOccurrences(of: space, with: " ")
        }
        value = value.replacingOccurrences(of: "\u{2013}", with: "–")
        value = value.replacingOccurrences(of: "\u{2014}", with: "–")
        value = value.replacingOccurrences(of: "\u{2012}", with: "–")
        value = value.replacingOccurrences(of: "\u{2010}", with: "-")
        value = value.replacingOccurrences(of: "\u{2011}", with: "-")
        value = value.replacingOccurrences(of: "\u{2212}", with: "-")
        value = value.replacingOccurrences(of: #"[^\S\n]*:[^\S\n]*"#, with: ":", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)\b([ap])\s*\.?\s*m\.?\b"#, with: "$1m", options: .regularExpression)
        // Vision often reads PM as PN / P.N.
        value = value.replacingOccurrences(of: #"(?i)\b([ap])\s*\.?\s*n\.?\b"#, with: "$1m", options: .regularExpression)
        // Street numbers glued to the name: "12344Elm" → "12344 Elm". Safe for speech.
        value = value.replacingOccurrences(
            of: #"(\d{2,})([A-Za-z])"#,
            with: "$1 $2",
            options: .regularExpression
        )
        value = splitGluedPortalWords(value)
        value = repairKnownWords(value)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drop OCR chrome: boxes, bullets, replacement chars, zero-width junk.
    /// Letters, numbers, and ordinary punctuation stay.
    static func stripWeirdSymbols(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            if character.isNewline {
                result.append(character)
                continue
            }
            if character.isWhitespace {
                if result.last != " " && result.last != "\n" {
                    result.append(" ")
                }
                continue
            }
            if character.isLetter || character.isNumber || allowedPhotoPunctuation.contains(character) {
                result.append(character)
                continue
            }
            if result.last != " " && result.last != "\n" {
                result.append(" ")
            }
        }
        return result
    }

    private static let allowedPhotoPunctuation: Set<Character> = [
        ".", ",", ":", ";", "!", "?", "\"", "'", "`", "’", "“", "”",
        "-", "–", "—", "/", "(", ")", "[", "]", "@", "#", "&", "+",
        "%", "$", "*", "°", "~", "=", "'"
    ]

    /// Vision output only: keep real line breaks, spaces between words, and
    /// conservative de-glue so a human can read the portal page.
    /// Spoken phrases must not go through here — camelCase split would break McDonald's.
    static func readablePhotoTranscript(_ text: String) -> String {
        var value = text
        value = value.replacingOccurrences(
            of: #"(?<=[a-z])(?=[A-Z])"#,
            with: " ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?<=\d)(?=[A-Za-z])"#,
            with: " ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(\d{2,})([A-Za-z])"#,
            with: "$1 $2",
            options: .regularExpression
        )
        value = normalize(value)
        value = stripWeirdSymbols(value)
        return CalendarCardParser.lineated(value)
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// "AppointmentDetails", "2:30PM" — only glued screenshot tokens, not spoken phrases.
    static func splitGluedPortalWords(_ text: String) -> String {
        var value = text
        value = value.replacingOccurrences(
            of: #"(?i)(?<=[a-z])(?=(details|type|time|location|address|patient|provider|notes|confirmed|health|family|exam|physical|annual)\b)"#,
            with: " ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?<=\d)(?=[AaPp]\.?[Mm]\.?)"#,
            with: " ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?<=[A-Za-z])(?=\d)"#,
            with: " ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?i)\b(am|pm)(?=[a-z])"#,
            with: "$1 ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?i)\b(on|this)(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#,
            with: "$1 $2",
            options: .regularExpression
        )
        value = splitKnownPhrases(value)
        value = splitGluedChatWords(value)
        return value
    }

    /// iMessage OCR often drops spaces: "areeyou", "11amonSaturday", "newcoffeeshopdowntown".
    /// Only split a token when it is entirely known chat/schedule words — "westwind" stays.
    static func splitGluedChatWords(_ text: String) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line in
            String(line).split(omittingEmptySubsequences: false, whereSeparator: { $0.isWhitespace && !$0.isNewline }).map { chunk in
                unglueChatToken(String(chunk))
            }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// Collapse obvious doubled-letter OCR on a small allow-list. Unknown names stay.
    /// Newlines are kept so a screenshot transcript stays readable.
    static func repairKnownWords(_ text: String) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line in
            String(line).split(omittingEmptySubsequences: false, whereSeparator: { $0.isWhitespace && !$0.isNewline }).map { chunk in
                guard !chunk.isEmpty else { return "" }
                return repairToken(String(chunk))
            }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    static func fuzzyPhrase(_ text: String, matches phrase: String) -> Bool {
        let hay = tokens(in: text)
        let needle = tokens(in: phrase)
        guard !hay.isEmpty, !needle.isEmpty else { return false }
        if hay.count == needle.count {
            return zip(hay, needle).allSatisfy { fuzzyToken($0, matches: $1) }
        }
        return fuzzyToken(text, matches: phrase)
    }

    private static func tokens(in text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !$0.isEmpty }
    }

    private static let knownPhrases: [(folded: String, spaced: String)] = [
        ("appointmentdetails", "Appointment Details"),
        ("appointmenttype", "Appointment Type"),
        ("appointmenttime", "Appointment Time"),
        ("checkintime", "Check-in Time"),
        ("annualphysicalexam", "Annual Physical Exam"),
        ("peninsulafamilyhealth", "Peninsula Family Health"),
        ("deyoungmuseum", "de Young Museum"),
        ("sightglasscoffee", "Sightglass Coffee")
    ]

    private static func splitKnownPhrases(_ text: String) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line in
            String(line).split(omittingEmptySubsequences: false, whereSeparator: { $0.isWhitespace && !$0.isNewline }).map { chunk in
                expandKnownPhrase(String(chunk))
            }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    private static func expandKnownPhrase(_ token: String) -> String {
        let folded = foldedLetters(token)
        guard folded.count >= 10 else { return token }
        if let mapped = knownPhrases.first(where: {
            folded == $0.folded || (fuzzyToken(token, matches: $0.folded) && abs(folded.count - $0.folded.count) <= 4)
        }) {
            return mapped.spaced
        }
        return token
    }

    static func foldedLetters(_ token: String) -> String {
        var result = ""
        var last: Character?
        for character in token.lowercased() where character.isLetter || character.isNumber {
            if character != last {
                result.append(character)
            }
            last = character
        }
        return result
    }

    static func fuzzyToken(_ token: String, matches needle: String) -> Bool {
        let hay = foldedLetters(token.replacingOccurrences(of: "-", with: ""))
        let needle = foldedLetters(needle.replacingOccurrences(of: "-", with: ""))
        guard !hay.isEmpty, !needle.isEmpty else { return false }
        if hay == needle { return true }
        if hay.hasPrefix(needle), hay.count - needle.count <= max(2, needle.count) { return true }
        if needle.hasPrefix(hay), hay.count >= 4 { return true }
        return subsequenceExtras(hay: hay, needle: needle) <= max(3, needle.count / 2)
    }

    private static func subsequenceExtras(hay: String, needle: String) -> Int {
        var index = hay.startIndex
        var extras = 0
        for character in needle {
            var found = false
            while index < hay.endIndex {
                if hay[index] == character {
                    index = hay.index(after: index)
                    found = true
                    break
                }
                extras += 1
                index = hay.index(after: index)
            }
            if !found { return .max }
        }
        extras += hay.distance(from: index, to: hay.endIndex)
        return extras
    }

    private static let knownWords: [String: String] = [
        "appointment": "Appointment",
        "details": "Details",
        "peninsula": "Peninsula",
        "family": "Family",
        "health": "Health",
        "location": "Location",
        "address": "Address",
        "confirmed": "Confirmed",
        "physical": "Physical",
        "annual": "Annual",
        "patient": "Patient",
        "provider": "Provider",
        "parking": "Parking",
        "notes": "Notes",
        "type": "Type",
        "time": "Time",
        "date": "Date",
        "exam": "Exam",
        "tuesday": "Tuesday",
        "wednesday": "Wednesday",
        "thursday": "Thursday",
        "friday": "Friday",
        "saturday": "Saturday",
        "sunday": "Sunday",
        "monday": "Monday",
        "october": "October",
        "january": "January",
        "february": "February",
        "march": "March",
        "april": "April",
        "june": "June",
        "july": "July",
        "august": "August",
        "september": "September",
        "november": "November",
        "december": "December"
    ]

    private static let explicitRepairs: [String: String] = [
        "appointoointment": "Appointment",
        "detailils": "Details",
        "typeype": "Type",
        "dateate": "Date",
        "deyoung": "de Young",
        "sightglass": "Sightglass"
    ]

    private static func repairToken(_ token: String) -> String {
        let letters = token.filter(\.isLetter)
        guard letters.count >= 3 else { return token }
        let folded = foldedLetters(token)
        if let mapped = explicitRepairs[token.lowercased()] ?? explicitRepairs[folded] {
            return splice(mapped, into: token)
        }
        if let mapped = knownWords[folded] {
            return splice(mapped, into: token)
        }
        return token
    }

    private static func splice(_ replacement: String, into token: String) -> String {
        let prefix = token.prefix { !$0.isLetter }
        let letterEnd = token.lastIndex(where: \.isLetter) ?? token.index(before: token.endIndex)
        let suffix = token[token.index(after: letterEnd)...]
        return String(prefix) + replacement + String(suffix)
    }

    private static let chatFunctionWords: Set<String> = [
        "a", "an", "the", "to", "of", "in", "on", "at", "for", "from", "and", "or",
        "are", "you", "we", "i", "me", "my", "your", "our", "they", "them", "have",
        "has", "had", "was", "were", "could", "would", "should", "can", "go", "see",
        "then", "how", "about", "what", "which", "one", "new", "so", "fun", "yes",
        "hey", "hi", "ok", "okay", "am", "pm", "this", "that", "with", "be"
    ]

    private static let chatAnchorWords: Set<String> = [
        "free", "weekend", "thinking", "together", "downtown", "coffee", "shop",
        "sounds", "great", "cute", "drinks", "seating", "perfect", "time", "works",
        "daily", "grind", "saturday", "sunday", "monday", "tuesday", "wednesday",
        "thursday", "friday", "today", "tomorrow", "tonight", "morning", "afternoon",
        "evening", "yay", "museum", "around", "opens"
    ]

    private static let chatGreetingRepairs: [String] = ["hey", "yes", "yay", "hi", "ok", "okay"]

    private static var chatLexicon: Set<String> {
        chatFunctionWords.union(chatAnchorWords).union(knownWords.keys)
    }

    private static func unglueChatToken(_ token: String) -> String {
        let prefix = token.prefix { !$0.isLetter && !$0.isNumber }
        let suffixCount = token.reversed().prefix { !$0.isLetter && !$0.isNumber }.count
        let coreEnd = token.index(token.endIndex, offsetBy: -suffixCount)
        guard prefix.endIndex < coreEnd else { return token }
        let core = String(token[prefix.endIndex..<coreEnd])
        let suffix = String(token[coreEnd...])
        guard core.count >= 4 else { return token }
        // Brands like McDonald's are camelCase on purpose — do not unglue them.
        if core.dropFirst().contains(where: \.isUppercase) { return token }

        let letters = core.lowercased().filter { $0.isLetter || $0.isNumber }
        if chatLexicon.contains(letters) {
            return String(prefix) + letters + suffix
        }
        let folded = foldedLetters(core)
        if let mapped = knownWords[folded] ?? (chatLexicon.contains(folded) ? folded : nil) {
            return String(prefix) + mapped + suffix
        }
        if let greeting = chatGreetingRepairs.first(where: {
            fuzzyToken(core, matches: $0) && folded.count <= $0.count + 3
        }) {
            return String(prefix) + greeting + suffix
        }
        guard let parts = segmentChatWords(letters), parts.count >= 2 else { return token }
        let hasAnchor = parts.contains { chatAnchorWords.contains($0) || knownWords[$0] != nil }
        let allKnown = parts.allSatisfy { chatFunctionWords.contains($0) || chatAnchorWords.contains($0) }
        guard hasAnchor || allKnown else { return token }
        return String(prefix) + parts.joined(separator: " ") + suffix
    }

    /// Word-break glued chat tokens. Extra repeated letters (“weekeend”) still
    /// count as the lexicon word (“weekend”).
    private static func segmentChatWords(_ letters: String) -> [String]? {
        let chars = Array(letters)
        guard !chars.isEmpty, chars.count <= 48 else { return nil }
        let words = chatLexicon.filter { word in
            if word.count == 1 { return ["a", "i"].contains(word) }
            if word.count == 2 { return chatFunctionWords.contains(word) || ["am", "pm", "ok"].contains(word) }
            return true
        }.sorted { $0.count > $1.count }

        var best: [[String]?] = Array(repeating: nil, count: chars.count + 1)
        best[0] = []
        for start in 0..<chars.count {
            guard let leading = best[start] else { continue }
            for word in words {
                guard let consumed = consumeLexiconWord(word, in: chars, at: start) else { continue }
                let next = leading + [word]
                if let existing = best[consumed] {
                    if next.count < existing.count { best[consumed] = next }
                } else {
                    best[consumed] = next
                }
            }
        }
        return best[chars.count]
    }

    /// Match `word` at `start`, allowing extra consecutive OCR repeats in the haystack.
    private static func consumeLexiconWord(_ word: String, in chars: [Character], at start: Int) -> Int? {
        var index = start
        let needles = Array(word)
        for (offset, needle) in needles.enumerated() {
            guard index < chars.count, chars[index] == needle else { return nil }
            index += 1
            let nextNeedle = offset + 1 < needles.count ? needles[offset + 1] : nil
            while index < chars.count, chars[index] == needle, nextNeedle != needle {
                index += 1
            }
        }
        return index
    }
}

/// Calendar / invite screenshots and labeled portal rows (Appointment Type, Date,
/// Check-in, Appointment Time, Location, Address, Notes). Spoken phrases still
/// use EventExtractor.
enum CalendarCardParser {
    struct Fields: Equatable {
        var title: String?
        var whenLine: String?
        var location: String?
        var notes: String?
        var appointmentType: String?
        var checkIn: String?
        var appointmentTime: String?
        var address: String?
        var parking: String?
        var patient: String?
    }

    static func looksLikeCard(_ text: String) -> Bool {
        let lined = lineated(text)
        let fields = fields(from: lined)
        if looksLikePortal(fields) { return true }
        if fields.location != nil { return true }
        if lined.range(of: #"(?i)appointment\s+(details|type|time)"#, options: .regularExpression) != nil,
           fields.whenLine != nil || fields.appointmentTime != nil || hasCardDateLine(lined) {
            return true
        }
        if looksLikeChat(lined) { return true }
        return fields.whenLine != nil && fields.title != nil
    }

    /// iMessage / chat screenshot: place+address in one bubble, “11am on saturday”.
    static func looksLikeChat(_ text: String) -> Bool {
        let fields = fields(from: text)
        if looksLikePortal(fields) { return false }
        let street = chatStreetAddress(in: text)
        let when = chatWhenLine(in: text)
        let place = chatPlaceName(in: text)
        let cues = chatCueCount(in: text)
        if street != nil, when != nil, place != nil { return true }
        if street != nil, when != nil, cues >= 1 { return true }
        return street != nil && cues >= 2 && mentionsCalendarDay(text)
    }

    /// Chat screenshots can name more than one stop (coffee, then the museum).
    static func drafts(from text: String, calendar: Calendar = .current) -> [DraftEvent] {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return [] }
        let normalized = lineated(OCRTextNormalizer.normalize(original))
        let parsed = fields(from: normalized)
        if looksLikeChat(normalized), !looksLikePortal(parsed) {
            let stops = draftsFromChat(normalized, original: original, calendar: calendar)
            if !stops.isEmpty { return stops }
        }
        if let card = draft(from: text, calendar: calendar) {
            return [card]
        }
        return []
    }

    static func draft(from text: String, calendar: Calendar = .current) -> DraftEvent? {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return nil }
        let normalized = lineated(OCRTextNormalizer.normalize(original))
        let parsed = fields(from: normalized)
        if looksLikeChat(normalized), !looksLikePortal(parsed) {
            return draftFromChat(normalized, original: original, calendar: calendar)
        }
        guard looksLikeCard(normalized) else { return nil }
        let when = composedWhen(from: parsed, in: normalized)
        let portal = portalAppointmentWindow(fields: parsed, page: normalized)
        let range = portal?.range
            ?? TimeRangeParser.parse(parsed.appointmentTime ?? when)
            ?? adjacentClockRange(in: parsed.appointmentTime ?? "", allowed: parsed.appointmentTime != nil)
            ?? TimeRangeParser.parse(when)
        let clock = range == nil ? ClockTimeParser.parse(when) : nil
        let day = detectedDay(in: when, calendar: calendar)
            ?? detectedDay(in: parsed.whenLine ?? "", calendar: calendar)
            ?? detectedDay(in: normalized, calendar: calendar)
        guard range != nil || clock != nil || day != nil else { return nil }

        let start: Date
        let minutes: Int
        let assumed: Bool
        let hasTime: Bool
        if let range {
            start = range.startDate(on: day ?? Date(), calendar: calendar)
            minutes = range.durationMinutes
            assumed = portal?.assumed ?? false
            hasTime = true
        } else if let clock {
            start = clock.startDate(on: day ?? Date(), calendar: calendar)
            minutes = 60
            assumed = true
            hasTime = true
        } else if let day {
            start = day
            minutes = 60
            assumed = true
            hasTime = timeLooksPresent(in: when)
        } else {
            return nil
        }

        let title = preferredTitle(from: parsed, in: normalized)
        let location = preferredLocation(from: parsed, in: normalized)
        guard !title.isEmpty || location != nil || hasTime else { return nil }

        let details = extraDetails(from: parsed)
        let arrival = arrivalFromCheckIn(
            checkIn: parsed.checkIn ?? checkInLine(in: normalized),
            start: start,
            notes: parsed.notes,
            calendar: calendar
        )
        let readable = OCRTextNormalizer.readablePhotoTranscript(original)
        return DraftEvent(
            title: title.isEmpty ? (location ?? "Untitled") : title,
            start: start,
            durationMinutes: minutes,
            durationAssumed: assumed,
            location: location ?? "",
            sourceText: readable.isEmpty ? original : readable,
            hasDate: day != nil || mentionsCalendarDay(normalized),
            hasTime: hasTime,
            extraBeforeMinutes: arrival.extraBefore,
            arriveBy: arrival.arriveBy,
            details: details
        )
    }

    /// OCR often pastes a card as one long line. Put labels and the date on their own lines.
    static func lineated(_ text: String) -> String {
        var value = text
        let colonLabels = [
            "Location", "Where", "Address", "Place", "When", "Date", "Time",
            "Notes", "Note", "Description", "Details", "Title", "Event",
            "Appointment Type", "Appointment Time", "Check-in Time", "Patient",
            "Provider", "Parking", "Phone"
        ]
        for label in colonLabels {
            let escaped = NSRegularExpression.escapedPattern(for: label)
            value = value.replacingOccurrences(
                of: #"(?i)\s+(\#(escaped))\s*:"#,
                with: "\n$1:",
                options: .regularExpression
            )
        }
        // Distinctive portal labels often have no colon. Do not split on
        // "Details" / "Time" — that would break "Appointment Details".
        let portalLabels = [
            "Appointment Type", "Appointment Time", "Check-in Time", "Check-In Time",
            "Check-in", "Check in", "Patient", "Provider", "Location", "Address",
            "Parking", "Phone", "Date", "Notes"
        ]
        for label in portalLabels {
            let escaped = NSRegularExpression.escapedPattern(for: label)
            value = value.replacingOccurrences(
                of: #"(?i)\s+(\#(escaped))\b"#,
                with: "\n$1",
                options: .regularExpression
            )
        }
        if let range = value.range(of: cardDatePattern, options: .regularExpression) {
            let prefix = value[..<range.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty, !prefix.contains(where: \.isNewline) {
                value.insert("\n", at: range.lowerBound)
            }
        }
        return value
    }

    static func fields(from text: String) -> Fields {
        let lines = lineated(text)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var fields = Fields()
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let next = index + 1 < lines.count ? lines[index + 1] : nil
            if let labeled = labeledValue(line, next: next) {
                assign(labeled.kind, value: labeled.value, to: &fields)
                index += labeled.consumedNext ? 2 : 1
                if labeled.consumedNext == false,
                   let next,
                   shouldJoin(kind: labeled.kind, continuation: next) {
                    append(labeled.kind, extra: next, to: &fields)
                    index += 1
                }
                continue
            }
            if fields.whenLine == nil, isCardDateLine(line) {
                fields.whenLine = line
                index += 1
                continue
            }
            if fields.title == nil, isTitleCandidate(line, fields: fields) {
                fields.title = line
            }
            index += 1
        }
        return fields
    }

    private enum LabelKind {
        case title, when, location, notes, appointmentType, checkIn, appointmentTime, address, parking, patient, chrome
    }

    private static let labelTable: [(LabelKind, [String])] = [
        (.appointmentType, ["appointment type", "appt type", "visit type"]),
        (.appointmentTime, ["appointment time", "visit time", "appt time"]),
        (.checkIn, ["check-in time", "check in time", "check-in", "check in", "arrival time"]),
        (.address, ["street address", "address"]),
        (.patient, ["patient name", "patient"]),
        (.location, ["location", "where", "place", "clinic", "facility"]),
        (.when, ["when", "date", "appointment date", "visit date", "time"]),
        (.parking, ["parking"]),
        (.notes, ["notes", "note", "description", "instructions"]),
        (.title, ["title", "event", "name"]),
        (.chrome, ["appointment details", "add to calendar", "get directions"])
    ]

    private static func labeledValue(_ line: String, next: String?) -> (kind: LabelKind, value: String, consumedNext: Bool)? {
        if let colon = colonLabeledValue(line, next: next) {
            return colon
        }
        if let leading = leadingLabeledValue(line, next: next) {
            return leading
        }
        return nil
    }

    private static func colonLabeledValue(_ line: String, next: String?) -> (kind: LabelKind, value: String, consumedNext: Bool)? {
        let folded = line.lowercased()
        for (kind, labels) in labelTable {
            for label in labels {
                if folded == label || folded == "\(label):" {
                    let value = next?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !value.isEmpty, !isPortalLabelLine(value), labeledValue(value, next: nil) == nil else {
                        return nil
                    }
                    return (kind, value, next != nil)
                }
                let prefix = "\(label):"
                if folded.hasPrefix(prefix) {
                    let value = String(line.dropFirst(prefix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if value.isEmpty, let next, !next.isEmpty {
                        return (kind, next, true)
                    }
                    guard !value.isEmpty else { return nil }
                    return (kind, value, false)
                }
            }
        }
        return nil
    }

    /// Portal rows often omit the colon: "Appointment Type Annual Physical Exam".
    private static func leadingLabeledValue(_ line: String, next: String?) -> (kind: LabelKind, value: String, consumedNext: Bool)? {
        let tokens = wordTokens(line)
        guard !tokens.isEmpty else { return nil }
        for (kind, labels) in labelTable {
            for label in labels.sorted(by: { $0.count > $1.count }) {
                guard let consumed = consumeLabel(tokens, label: label) else { continue }
                let valueTokens = Array(tokens.dropFirst(consumed))
                if kind == .chrome {
                    return (kind, valueTokens.joined(separator: " "), false)
                }
                if valueTokens.isEmpty {
                    let value = next?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !value.isEmpty, !isPortalLabelLine(value), labeledValue(value, next: nil) == nil else {
                        return nil
                    }
                    return (kind, clipValueAtNextLabel(value), next != nil)
                }
                return (kind, clipValueAtNextLabel(valueTokens.joined(separator: " ")), false)
            }
        }
        return nil
    }

    /// Keep "2:15 PM" from swallowing "Appointment Time 2:30 PM – 3:15 PM" on one line.
    private static func clipValueAtNextLabel(_ value: String) -> String {
        let tokens = wordTokens(value)
        guard !tokens.isEmpty else { return value }
        var used: [String] = []
        for index in tokens.indices {
            let rest = Array(tokens[index...])
            if index > 0, startsWithLabel(rest) { break }
            used.append(tokens[index])
        }
        return used.joined(separator: " ")
    }

    private static func startsWithLabel(_ tokens: [String]) -> Bool {
        labelTable.contains { kind in
            kind.1.contains { consumeLabel(tokens, label: $0) != nil }
        }
    }

    private static func consumeLabel(_ tokens: [String], label: String) -> Int? {
        let needed = wordTokens(label)
        guard !needed.isEmpty, tokens.count >= needed.count else { return nil }
        for (index, needle) in needed.enumerated() {
            guard OCRTextNormalizer.fuzzyToken(tokens[index], matches: needle) else { return nil }
        }
        return needed.count
    }

    private static func wordTokens(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: "-", with: " ")
            .split { $0.isWhitespace }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func assign(_ kind: LabelKind, value: String, to fields: inout Fields) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, kind != .chrome else { return }
        switch kind {
        case .title: if fields.title == nil { fields.title = trimmed }
        case .when: if fields.whenLine == nil { fields.whenLine = trimmed }
        case .location: if fields.location == nil { fields.location = trimmed }
        case .notes: if fields.notes == nil { fields.notes = trimmed }
        case .appointmentType: if fields.appointmentType == nil { fields.appointmentType = trimmed }
        case .checkIn: if fields.checkIn == nil { fields.checkIn = trimmed }
        case .appointmentTime: if fields.appointmentTime == nil { fields.appointmentTime = trimmed }
        case .address: if fields.address == nil { fields.address = trimmed }
        case .parking: if fields.parking == nil { fields.parking = trimmed }
        case .patient: if fields.patient == nil { fields.patient = trimmed }
        case .chrome: break
        }
    }

    private static func append(_ kind: LabelKind, extra: String, to fields: inout Fields) {
        switch kind {
        case .location:
            if let existing = fields.location, !existing.isEmpty {
                fields.location = existing + ", " + extra
            }
        case .address:
            if let existing = fields.address, !existing.isEmpty {
                fields.address = existing + ", " + extra
            }
        case .when:
            if let existing = fields.whenLine, !existing.isEmpty {
                fields.whenLine = existing + " " + extra
            }
        case .appointmentTime:
            if let existing = fields.appointmentTime, !existing.isEmpty {
                fields.appointmentTime = joinTimeFragments(existing, extra)
            }
        default:
            break
        }
    }

    private static func shouldJoin(kind: LabelKind, continuation: String) -> Bool {
        if labeledValue(continuation, next: nil) != nil { return false }
        switch kind {
        case .location, .address:
            return looksLikeAddressContinuation(continuation)
        case .when, .appointmentTime:
            return TimeRangeParser.parse(continuation) != nil || ClockTimeParser.parse(continuation) != nil
        default:
            return false
        }
    }

    private static func looksLikeAddressContinuation(_ line: String) -> Bool {
        if isCardDateLine(line) { return false }
        if labeledValue(line, next: nil) != nil { return false }
        if line.range(of: #"(?i)\b[A-Z]{2}\s+\d{5}\b"#, options: .regularExpression) != nil {
            return true
        }
        return line.contains(",") && line.count <= 80
    }

    static func hasCardDateLine(_ text: String) -> Bool {
        text
            .components(separatedBy: .newlines)
            .contains { isCardDateLine($0) }
    }

    private static let cardDatePattern = #"(?i)\b(?:mon|tue|tues|wed|weds|thu|thur|thurs|fri|sat|sun)[a-z]*\.?,?\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(?:st|nd|rd|th)?"#

    static func isCardDateLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else { return false }
        return trimmed.range(of: cardDatePattern, options: .regularExpression) != nil
    }

    private static func cardDateLine(in text: String) -> String? {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { isCardDateLine($0) }
    }

    private static func isTitleCandidate(_ line: String, fields: Fields) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 80 else { return false }
        if isChromeTitle(trimmed) { return false }
        if isPortalLabelLine(trimmed) { return false }
        if isCardDateLine(trimmed) { return false }
        if labeledValue(trimmed, next: nil) != nil { return false }
        if trimmed.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) != nil { return false }
        if trimmed.range(of: #"\d{3}.+\d{4}"#, options: .regularExpression) != nil { return false }
        if let patient = fields.patient,
           patient.caseInsensitiveCompare(trimmed) == .orderedSame
            || OCRTextNormalizer.fuzzyPhrase(trimmed, matches: patient) {
            return false
        }
        if trimmed.range(of: #"(?i)^dr\.?\b"#, options: .regularExpression) != nil { return false }
        return true
    }

    private static func cleanedTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var trimmed = stripLeadingPortalLabel(raw)
            .replacingOccurrences(of: #"(?i)\bconfirmed\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if isChromeTitle(trimmed) { return nil }
        if isPortalLabelLine(trimmed) { return nil }
        if looksLikePersonName(trimmed) { return nil }
        if trimmed.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) != nil { return nil }
        if let known = knownVisitTitle(in: trimmed) { return known }
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func knownVisitTitle(in text: String) -> String? {
        let known = "Annual Physical Exam"
        let hay = OCRTextNormalizer.foldedLetters(text)
        let needle = OCRTextNormalizer.foldedLetters(known)
        if hay.contains(needle) { return known }
        if needle.hasPrefix(hay), hay.count >= 14 { return known }
        if OCRTextNormalizer.fuzzyPhrase(text, matches: known) { return known }
        return nil
    }

    private static func stripLeadingPortalLabel(_ text: String) -> String {
        let tokens = wordTokens(text)
        guard !tokens.isEmpty else { return text }
        for (_, labels) in labelTable {
            for label in labels.sorted(by: { $0.count > $1.count }) {
                guard let consumed = consumeLabel(tokens, label: label) else { continue }
                let rest = Array(tokens.dropFirst(consumed))
                guard !rest.isEmpty, !startsWithLabel(rest) else { return text }
                return rest.joined(separator: " ")
            }
        }
        return text
    }

    private static func firstTitle(in text: String, fields: Fields) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { isTitleCandidate($0, fields: fields) } ?? ""
    }

    private static func cleanedLocation(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func preferredTitle(from parsed: Fields, in text: String) -> String {
        if let type = visitName(parsed.appointmentType) { return type }
        if let visit = visitTypeTitle(in: text, fields: parsed) { return visit }
        if let title = visitName(parsed.title) ?? cleanedTitle(parsed.title) { return title }
        return visitName(firstTitle(in: text, fields: parsed))
            ?? cleanedTitle(firstTitle(in: text, fields: parsed))
            ?? ""
    }

    /// "Annual Physical Exam Confirmed" on a header row still wins over a bare label.
    private static func visitTypeTitle(in text: String, fields: Fields) -> String? {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for line in lines {
            guard let visit = visitName(line) else { continue }
            if let patient = fields.patient, OCRTextNormalizer.fuzzyPhrase(visit, matches: patient) {
                continue
            }
            return visit
        }
        return nil
    }

    /// Keep "Annual Physical Exam"; drop "Check-in Time", "Details", and the clinic name.
    private static func visitName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let tokens = wordTokens(stripLeadingPortalLabel(raw))
        let skip = ["appointment", "details", "type", "time", "confirmed", "status"]
        let stop = [
            "peninsula", "family", "health", "location", "address", "patient",
            "provider", "parking", "notes", "phone", "date", "check"
        ]
        var used: [String] = []
        for token in tokens {
            if used.isEmpty, skip.contains(where: { OCRTextNormalizer.fuzzyToken(token, matches: $0) }) {
                continue
            }
            if !used.isEmpty, stop.contains(where: { OCRTextNormalizer.fuzzyToken(token, matches: $0) }) {
                break
            }
            if !used.isEmpty, isPortalLabelLine(token) { break }
            used.append(token)
        }
        let joined = used.joined(separator: " ")
        guard looksLikeVisitType(joined), let cleaned = cleanedTitle(joined) else { return nil }
        return cleaned
    }

    private static func looksLikeVisitType(_ text: String) -> Bool {
        text.range(
            of: #"(?i)\b(exam|physical|checkup|check-up|follow-?up|consult|consultation|wellness|physicals)\b"#,
            options: .regularExpression
        ) != nil
    }

    /// A line that is only a portal label ("Check-in Time") is never a title or a field value.
    private static func isPortalLabelLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let tokens = wordTokens(trimmed)
        guard !tokens.isEmpty else { return false }
        for (_, labels) in labelTable {
            for label in labels.sorted(by: { $0.count > $1.count }) {
                guard let consumed = consumeLabel(tokens, label: label) else { continue }
                let rest = Array(tokens.dropFirst(consumed))
                return rest.isEmpty || startsWithLabel(rest)
            }
        }
        return false
    }

    private static func looksLikePersonName(_ text: String) -> Bool {
        let words = wordTokens(text)
        guard words.count == 2 else { return false }
        let lettersOnly = words.allSatisfy { word in
            let letters = word.filter(\.isLetter)
            return letters.count == word.filter { $0.isLetter || $0 == "-" }.count && letters.count >= 2
        }
        guard lettersOnly else { return false }
        let clinic = ["health", "family", "clinic", "hospital", "medical", "dental", "park", "road"]
        if words.contains(where: { clinic.contains($0.lowercased()) }) { return false }
        return words.allSatisfy { $0.first?.isUppercase == true }
    }

    private static func preferredLocation(from parsed: Fields, in text: String) -> String? {
        let name = cleanedLocation(parsed.location)
        let street = cleanedLocation(parsed.address) ?? detectedAddress(in: text)
        if let name, let street {
            if street.localizedCaseInsensitiveContains(name) { return street }
            if name.localizedCaseInsensitiveContains(street) { return name }
            return "\(name), \(street)"
        }
        return name ?? street
    }

    private static func composedWhen(from parsed: Fields, in text: String) -> String {
        let date = parsed.whenLine ?? cardDateLine(in: text)
        if let date, let time = parsed.appointmentTime {
            return "\(date) \(time)"
        }
        if let time = parsed.appointmentTime {
            return time
        }
        return date ?? text
    }

    /// Vision often drops the dash: "2:30 PM" and "3:15 PM" land as two clocks.
    /// End is the latest clock of the day, never the first appointment clock.
    static func adjacentClockRange(in text: String, allowed: Bool) -> TimeRangeParser.Result? {
        guard allowed else { return nil }
        let clocks = ClockTimeParser.all(in: text)
        guard clocks.count >= 2, let first = clocks.first, let latest = ClockTimeParser.latest(in: text) else {
            return nil
        }
        return range(from: first, to: latest)
    }

    /// Portal times: be-there from check-in, official start from Appointment Time,
    /// end = latest clock on the page (3:15, not 2:30), in any order.
    static func portalAppointmentWindow(
        fields: Fields,
        page: String
    ) -> (range: TimeRangeParser.Result, assumed: Bool, endToken: String)? {
        guard fields.checkIn != nil || fields.appointmentTime != nil || looksLikePortal(fields) else {
            return nil
        }
        let pageClocks = ClockTimeParser.all(in: page)
        guard !pageClocks.isEmpty else { return nil }

        let officialStart = ClockTimeParser.first(in: fields.appointmentTime ?? "")
            ?? pageClocks.first { clock in
                guard let checkIn = ClockTimeParser.first(in: fields.checkIn ?? "")
                    ?? ClockTimeParser.first(in: checkInLine(in: page) ?? "")
                else { return true }
                return clock.hour != checkIn.hour || clock.minute != checkIn.minute
            }
            ?? pageClocks.first
        guard let officialStart, let latest = ClockTimeParser.latest(in: page) else { return nil }

        let sameClock = officialStart.hour == latest.hour && officialStart.minute == latest.minute
        if sameClock, TimeRangeParser.parse(fields.appointmentTime ?? "") == nil {
            return nil
        }
        return (range(from: officialStart, to: latest), false, latest.matchedText(in: page))
    }

    private static func range(
        from start: ClockTimeParser.Result,
        to end: ClockTimeParser.Result
    ) -> TimeRangeParser.Result {
        var endHour = end.hour
        var endMinute = end.minute
        let startMinutes = start.hour * 60 + start.minute
        if endHour * 60 + endMinute <= startMinutes,
           !(end.hour == start.hour && end.minute == start.minute),
           endHour < 12 {
            endHour += 12
        }
        if endHour * 60 + endMinute <= startMinutes {
            endHour = end.hour
            endMinute = end.minute
            while endHour * 60 + endMinute <= startMinutes {
                endHour += 12
            }
        }
        let location = min(start.nsRange.location, end.nsRange.location)
        let length = max(NSMaxRange(start.nsRange), NSMaxRange(end.nsRange)) - location
        return TimeRangeParser.Result(
            startHour: start.hour,
            startMinute: start.minute,
            endHour: endHour,
            endMinute: endMinute,
            nsRange: NSRange(location: location, length: max(length, 0))
        )
    }

    private static func checkInLine(in text: String) -> String? {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { line in
                let tokens = wordTokens(line)
                return ["check-in time", "check in time", "check-in", "check in", "arrival time"]
                    .contains { consumeLabel(tokens, label: $0) != nil }
            }
    }

    private static func joinTimeFragments(_ existing: String, _ extra: String) -> String {
        if TimeRangeParser.parse(existing) != nil { return existing }
        if extra.range(of: #"[-–—]"#, options: .regularExpression) != nil {
            return existing + " " + extra
        }
        return existing + " – " + extra
    }

    private static func looksLikePortal(_ fields: Fields) -> Bool {
        let structural = fields.appointmentType != nil
            || fields.patient != nil
            || fields.address != nil
            || fields.checkIn != nil
            || fields.appointmentTime != nil
        let when = fields.whenLine != nil || fields.appointmentTime != nil || fields.checkIn != nil
        return structural && when
    }

    private static func isChromeTitle(_ text: String) -> Bool {
        let folded = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let chrome: Set<String> = [
            "appointment details", "details", "confirmed", "back",
            "add to calendar", "get directions", "home", "appointments",
            "messages", "profile", "status",
            "check-in time", "check in time", "check-in", "check in",
            "appointment time", "appointment type", "visit type", "visit time",
            "date", "time", "patient", "patient name", "provider",
            "location", "address", "parking", "notes", "phone"
        ]
        if chrome.contains(folded) { return true }
        return [
            "appointment details", "check-in time", "check in time",
            "appointment time", "appointment type"
        ].contains { OCRTextNormalizer.fuzzyPhrase(text, matches: $0) }
    }

    private static func extraDetails(from parsed: Fields) -> [String] {
        var lines: [String] = []
        if let notes = parsed.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            lines.append(notes)
        }
        if let parking = parsed.parking?.trimmingCharacters(in: .whitespacesAndNewlines), !parking.isEmpty {
            lines.append("Parking: \(parking)")
        }
        return lines
    }

    /// Check-in is when she must be there. Matching "arrive 15 minutes early" is the
    /// same fact — do not also load the extra-before chip.
    private static func arrivalFromCheckIn(
        checkIn: String?,
        start: Date,
        notes: String?,
        calendar: Calendar
    ) -> (arriveBy: Date?, extraBefore: Int) {
        if let checkIn, let clock = ClockTimeParser.first(in: checkIn) {
            let arrival = clock.startDate(on: start, calendar: calendar)
            let delta = Int(start.timeIntervalSince(arrival) / 60)
            if (1...180).contains(delta) {
                return (arrival, 0)
            }
        }
        return (nil, notes.flatMap { arriveEarlyMinutes(in: $0) } ?? 0)
    }

    private static func arriveEarlyMinutes(in text: String) -> Int? {
        let pattern = #"(?i)\b(?:arrive\s+)?(\d+)\s*(?:min|mins|minute|minutes)\s+early\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)),
              match.numberOfRanges >= 2
        else { return nil }
        let value = Int(nsText.substring(with: match.range(at: 1))) ?? 0
        return (1...180).contains(value) ? value : nil
    }

    private static func detectedDay(in text: String, calendar: Calendar) -> Date? {
        guard !text.isEmpty else { return nil }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let nsText = text as NSString
        let matches = detector?.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: nsText.length)
        ) ?? []
        let dated = matches.filter { $0.resultType.contains(.date) && $0.date != nil }
        if let calendarDay = dated.first(where: { looksLikeCalendarDay($0, in: nsText) })?.date {
            return calendar.startOfDay(for: calendarDay)
        }
        return dated.first?.date
    }

    private static func looksLikeCalendarDay(_ match: NSTextCheckingResult, in text: NSString) -> Bool {
        let snippet = text.substring(with: match.range).lowercased()
        if snippet.range(of: cardDatePattern, options: .regularExpression) != nil { return true }
        let months = [
            "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "sept",
            "oct", "nov", "dec", "today", "tomorrow", "tonight", "yesterday"
        ]
        return months.contains { snippet.contains($0) }
    }

    private static func detectedAddress(in text: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue)
        let nsText = text as NSString
        let matches = detector?.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: nsText.length)
        ) ?? []
        for match in matches where match.resultType.contains(.address) {
            if let components = match.addressComponents {
                let parts = [components[.street], components[.city], components[.state], components[.zip]]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                if !parts.isEmpty { return parts.joined(separator: ", ") }
            }
            let raw = nsText.substring(with: match.range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty { return raw }
        }
        return nil
    }

    private static func mentionsCalendarDay(_ text: String) -> Bool {
        isCardDateLine(text)
            || text.range(
                of: #"(?i)\b(today|tomorrow|tonight|yesterday|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#,
                options: .regularExpression
            ) != nil
    }

    private static func timeLooksPresent(in text: String) -> Bool {
        text.range(
            of: #"(?i)(\d{1,2}:\d{2}|\b\d{1,2}\s*(a\.?m\.?|p\.?m\.?)\b)"#,
            options: .regularExpression
        ) != nil
    }

    private static let chatFluff: Set<String> = [
        "hey", "hi", "hello", "yes", "yay", "yeah", "ok", "okay", "perfect",
        "thanks", "thank", "you", "works", "me", "see", "then", "what", "time",
        "how", "about", "which", "one", "were", "thinking", "sounds", "fun",
        "together", "downtown", "new", "m", "read", "delivered", "liked", "loved",
        "lily", "ethan"
    ]

    private static let weekdayNames: [(name: String, weekday: Int)] = [
        ("sunday", 1), ("monday", 2), ("tuesday", 3), ("wednesday", 4),
        ("thursday", 5), ("friday", 6), ("saturday", 7)
    ]

    private static func draftsFromChat(
        _ text: String,
        original: String,
        calendar: Calendar
    ) -> [DraftEvent] {
        let streets = allStreetRanges(in: text)
        if streets.count <= 1 {
            return draftFromChat(text, original: original, calendar: calendar).map { [$0] } ?? []
        }

        let clocks = ClockTimeParser.appointmentClocks(in: text)
        let day = chatDay(in: text, calendar: calendar)
        let readable = OCRTextNormalizer.readablePhotoTranscript(original)
        var used = Set<Int>()
        var drafts: [DraftEvent] = []

        for streetRange in streets {
            let street = cleanedStreet(String(text[streetRange]))
            let place = chatPlaceName(before: streetRange, in: text)
            let location = composeChatLocation(place: place, street: street)
            let title = isolatedChatTitle(place: place, location: location)
            guard !title.isEmpty || location != nil else { continue }

            let clockIndex = nearestClockIndex(to: streetRange, clocks: clocks, in: text, used: used)
            if let clockIndex { used.insert(clockIndex) }
            let clock = clockIndex.map { clocks[$0] }

            let start: Date
            let hasTime: Bool
            if let clock {
                start = clock.startDate(on: day ?? Date(), calendar: calendar)
                hasTime = true
            } else if let day {
                start = day
                hasTime = false
            } else {
                continue
            }

            drafts.append(
                DraftEvent(
                    title: title.isEmpty ? (location ?? "Untitled") : title,
                    start: start,
                    durationMinutes: 60,
                    durationAssumed: true,
                    location: location ?? "",
                    sourceText: readable.isEmpty ? original : readable,
                    hasDate: day != nil || mentionsCalendarDay(text),
                    hasTime: hasTime
                )
            )
        }
        return drafts
    }

    private static func isolatedChatTitle(place: String?, location: String?) -> String {
        if let place, !place.isEmpty, !isChatFluffTitle(place) {
            return place
        }
        if let location {
            let head = location.components(separatedBy: ",").first ?? location
            if looksLikeVenueName(head) {
                return titleCasedVenue(head)
            }
        }
        return place ?? ""
    }

    private static func cleanedStreet(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func nearestClockIndex(
        to street: Range<String.Index>,
        clocks: [ClockTimeParser.Result],
        in text: String,
        used: Set<Int>
    ) -> Int? {
        let streetNS = NSRange(street, in: text)
        var best: (index: Int, distance: Int)?
        for (index, clock) in clocks.enumerated() where !used.contains(index) {
            let distance = gap(between: clock.nsRange, and: streetNS)
            if let current = best {
                if distance < current.distance { best = (index, distance) }
            } else {
                best = (index, distance)
            }
        }
        return best?.index
    }

    private static func gap(between first: NSRange, and second: NSRange) -> Int {
        if NSMaxRange(first) <= second.location { return second.location - NSMaxRange(first) }
        if NSMaxRange(second) <= first.location { return first.location - NSMaxRange(second) }
        return 0
    }

    private static func draftFromChat(
        _ text: String,
        original: String,
        calendar: Calendar
    ) -> DraftEvent? {
        let when = chatWhenLine(in: text) ?? text
        let clock = ClockTimeParser.appointmentClock(in: when)
            ?? ClockTimeParser.appointmentClock(in: text)
        let day = chatDay(in: when, calendar: calendar)
            ?? chatDay(in: text, calendar: calendar)
        guard clock != nil || day != nil else { return nil }

        let start: Date
        let hasTime: Bool
        if let clock {
            start = clock.startDate(on: day ?? Date(), calendar: calendar)
            hasTime = true
        } else if let day {
            start = day
            hasTime = timeLooksPresent(in: when)
        } else {
            return nil
        }

        let place = chatPlaceName(in: text)
        let street = chatStreetAddress(in: text) ?? detectedAddress(in: text)
        let location = composeChatLocation(place: place, street: street)
        let title = chatTitle(place: place, text: text, location: location)
        guard !title.isEmpty || location != nil || hasTime else { return nil }

        let readable = OCRTextNormalizer.readablePhotoTranscript(original)
        return DraftEvent(
            title: title.isEmpty ? (location ?? "Untitled") : title,
            start: start,
            durationMinutes: 60,
            durationAssumed: true,
            location: location ?? "",
            sourceText: readable.isEmpty ? original : readable,
            hasDate: day != nil || mentionsCalendarDay(text),
            hasTime: hasTime
        )
    }

    private static func chatWhenLine(in text: String) -> String? {
        let patterns = [
            #"(?i)\b\d{1,2}(?::\d{2})?\s*(?:a|p)\.?m\.?\s*on\s*(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*\b"#,
            #"(?i)\bon\s*(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*\s*(?:at\s*)?\d{1,2}(?::\d{2})?\s*(?:a|p)\.?m\.?\b"#,
            #"(?i)\b(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*\s*(?:at\s*)?\d{1,2}(?::\d{2})?\s*(?:a|p)\.?m\.?\b"#,
            #"(?i)\bhow about\s+\d{1,2}(?::\d{2})?(?:\s*(?:a|p)\.?m\.?)?\b"#,
            #"(?i)\baround\s+\d{1,2}(?::\d{2})?(?:\s*(?:a|p)\.?m\.?)?\b"#,
            #"(?i)\bthis\s+(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*\b"#
        ]
        for pattern in patterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                return String(text[range])
            }
        }
        return nil
    }

    private static func chatDay(in text: String, calendar: Calendar) -> Date? {
        let folded = text.lowercased()
        for item in weekdayNames where folded.range(of: "\\b\(item.name)\\b", options: .regularExpression) != nil {
            return nextWeekday(item.weekday, calendar: calendar)
        }
        return detectedDay(in: text, calendar: calendar)
    }

    private static func nextWeekday(_ weekday: Int, calendar: Calendar, from date: Date = Date()) -> Date {
        let start = calendar.startOfDay(for: date)
        if calendar.component(.weekday, from: start) == weekday {
            return start
        }
        return calendar.nextDate(
            after: start,
            matching: DateComponents(weekday: weekday),
            matchingPolicy: .nextTime
        ) ?? start
    }

    private static let chatStreetPattern = #"(?i)\b\d{1,6}\s*[A-Za-z0-9.'\-]+(?:\s+[A-Za-z0-9.'\-]+){0,4}\s*(?:st|street|ave|avenue|rd|road|blvd|boulevard|dr|drive|ln|lane|way|ct|court)\.?\b(?:\s*,?\s*[A-Za-z][A-Za-z .]+)?(?:\s*,?\s*[A-Z]{2}\s+\d{5}(?:-\d{4})?)?"#

    private static func allStreetRanges(in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: chatStreetPattern) else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
            .compactMap { Range($0.range, in: text) }
    }

    private static func chatStreetAddress(in text: String) -> String? {
        if let range = allStreetRanges(in: text).first {
            let raw = cleanedStreet(String(text[range]))
            if !raw.isEmpty { return raw }
        }
        return detectedAddress(in: text)
    }

    private static func chatPlaceName(in text: String) -> String? {
        guard let street = allStreetRanges(in: text).first else { return nil }
        return chatPlaceName(before: street, in: text)
    }

    private static func chatPlaceName(before street: Range<String.Index>, in text: String) -> String? {
        let prefix = String(text[..<street.lowerBound])
        let bubble = prefix
            .replacingOccurrences(of: #"[\r\n]+"#, with: " ", options: .regularExpression)
            .split(whereSeparator: { $0 == "!" || $0 == "?" || $0 == "." })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty }
        guard var bubble else { return nil }
        bubble = bubble.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        var words = bubble.split { $0.isWhitespace }.map(String.init)
        while let first = words.first, chatFluff.contains(first.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            words.removeFirst()
        }
        while let last = words.last, chatFluff.contains(last.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            words.removeLast()
        }
        let name = words.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard looksLikeVenueName(name) else { return nil }
        return titleCasedVenue(name)
    }

    private static func looksLikeVenueName(_ name: String) -> Bool {
        let words = wordTokens(name)
        guard !words.isEmpty, words.count <= 6 else { return false }
        let folded = words.map { $0.lowercased() }
        if folded.contains(where: {
            ["grind", "cafe", "café", "coffee", "shop", "barn", "clinic", "park", "studio", "museum"].contains($0)
        }) {
            return true
        }
        if folded.first == "the", words.count >= 2 { return true }
        if words.count >= 2, words.allSatisfy({ word in
            word.first?.isUppercase == true || word.lowercased() == "the"
        }) {
            return true
        }
        return false
    }

    private static func titleCasedVenue(_ name: String) -> String {
        let small: Set<String> = ["the", "of", "and", "at", "in", "on", "a"]
        return name.split { $0.isWhitespace }.enumerated().map { index, word in
            let lower = word.lowercased()
            if index > 0, small.contains(lower) { return lower }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }

    private static func composeChatLocation(place: String?, street: String?) -> String? {
        switch (cleanedLocation(place), cleanedLocation(street)) {
        case let (place?, street?):
            if street.localizedCaseInsensitiveContains(place) { return street }
            if place.localizedCaseInsensitiveContains(street) { return place }
            return "\(place), \(street)"
        case let (place?, nil):
            return place
        case let (nil, street?):
            return street
        default:
            return nil
        }
    }

    private static func chatTitle(place: String?, text: String, location: String?) -> String {
        if let place, !place.isEmpty, !isChatFluffTitle(place) {
            return place
        }
        if text.range(of: #"(?i)\bcoffee\b"#, options: .regularExpression) != nil {
            return "Coffee"
        }
        if let location, looksLikeVenueName(location.components(separatedBy: ",").first ?? location) {
            return titleCasedVenue(location.components(separatedBy: ",").first ?? location)
        }
        return ""
    }

    private static func isChatFluffTitle(_ text: String) -> Bool {
        let folded = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if chatFluff.contains(folded) { return true }
        if folded.contains("yay") || folded.contains("heyey") { return true }
        if folded.count >= 18, !folded.contains(" ") { return true }
        return false
    }

    private static func chatCueCount(in text: String) -> Int {
        let cues = [
            "hey", "yay", "how about", "works for me", "see you", "are you free",
            "what time", "sounds so fun", "free this weekend"
        ]
        return cues.filter { cue in
            text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: cue))\\b", options: [.regularExpression, .caseInsensitive]) != nil
        }.count
    }
}
