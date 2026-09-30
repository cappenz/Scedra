import Foundation

/// The saved Apple Calendar event carries the original wording in its notes,
/// so "View original" survives even if Scedra's local map is cleared.
enum EventNotes {
    static let marker = "Added by Scedra"
    static let originalPrefix = "Original:"

    /// `details` (drive times, leave-by, the resolved place) sit above the original
    /// wording so "View original" keeps returning only what she said or typed.
    static func body(forOriginal source: String, details: [String] = []) -> String {
        var blocks = [marker]
        let lines = details.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !lines.isEmpty {
            blocks.append(lines.joined(separator: "\n"))
        }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            blocks.append("\(originalPrefix) \(trimmed)")
        }
        return blocks.joined(separator: "\n\n")
    }

    static func original(from notes: String?) -> String? {
        guard let notes, let range = notes.range(of: originalPrefix) else { return nil }
        let value = notes[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// The drive and official-time lines Confirm wrote into notes. Used by the
    /// details sheet so a padded 5:35–9:25 block still reads as 6:00–9:00.
    static func savedInfo(from notes: String?) -> SavedAppointmentInfo {
        SavedAppointmentInfo.parse(notes)
    }
}

/// What Review-style details can reconstruct from a saved event's notes.
struct SavedAppointmentInfo: Equatable {
    var appointmentWindow: String? = nil
    var driveLine: String? = nil
    var leaveByLine: String? = nil
    var travelModeLine: String? = nil
    var travelMode: TravelMode? = nil
    var placeFromNotes: String? = nil
    /// Parking, portal notes, and other lines Confirm wrote under the place.
    var extraLines: [String] = []
    var original: String? = nil
    var isScedraEvent = false

    /// Driving unless notes recorded Public transport.
    var resolvedTravelMode: TravelMode {
        travelMode ?? .drive
    }

    static func parse(_ notes: String?) -> SavedAppointmentInfo {
        var info = SavedAppointmentInfo()
        guard let notes, !notes.isEmpty else { return info }
        info.isScedraEvent = notes.contains(EventNotes.marker)
        info.original = EventNotes.original(from: notes)

        var body = notes
        if let range = notes.range(of: EventNotes.originalPrefix) {
            body = String(notes[..<range.lowerBound])
        }
        let lines = body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != EventNotes.marker }

        for line in lines {
            if let window = Self.value(after: Self.appointmentPrefixes, in: line) {
                info.appointmentWindow = window
            } else if let value = Self.value(after: Self.travelPrefixes, in: line) {
                info.travelModeLine = line
                info.travelMode = TravelMode.parseAppointmentChoice(value)
            } else if let value = Self.value(after: Self.drivePrefixes, in: line) {
                info.driveLine = value
                if info.travelMode == nil { info.travelMode = .drive }
            } else if let value = Self.value(after: Self.transitPrefixes, in: line) {
                info.driveLine = value
                if info.travelMode == nil { info.travelMode = .transit }
            } else if TravelEstimator.leaveByTimeText(from: line) != nil {
                info.leaveByLine = line
            } else if info.placeFromNotes == nil {
                info.placeFromNotes = line
            } else {
                info.extraLines.append(line)
            }
        }
        return info
    }

    /// English keys Confirm writes, plus display-language prefixes if notes were shown back.
    private static let appointmentPrefixes = ["Appointment:", "Rendez-vous :", "Rendez-vous:", "Cita:", "Termin:"]
    private static let travelPrefixes = ["Travel:", "Trajet :", "Trajet:", "Viaje:", "Reise:"]
    private static let drivePrefixes = ["Drive:", "Voiture :", "Voiture:", "Coche:", "Fahrt:"]
    private static let transitPrefixes = ["Transit:", "Transports :", "Transports:", "Transporte:", "ÖPNV:"]

    private static func value(after prefixes: [String], in line: String) -> String? {
        for prefix in prefixes where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}

enum OriginalTextStore {
    private static let key = "scedra.originalTextByEventID"

    static func save(_ text: String, for eventID: String) {
        guard !eventID.isEmpty, !text.isEmpty else { return }
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        map[eventID] = text
        UserDefaults.standard.set(map, forKey: key)
    }

    static func text(for eventID: String) -> String? {
        let map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        return map[eventID]
    }

    static func remove(_ eventID: String) {
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        map.removeValue(forKey: eventID)
        UserDefaults.standard.set(map, forKey: key)
    }
}
