import Foundation

enum TravelMode: String, CaseIterable, Identifiable {
    case drive
    case transit
    case walk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .drive: ScedraString("Drive")
        case .transit: ScedraString("Transit")
        case .walk: ScedraString("Walk")
        }
    }

    /// Lowercase form for sentences like "~25 min drive".
    var travelLabel: String {
        switch self {
        case .drive: "drive"
        case .transit: "transit"
        case .walk: "walk"
        }
    }

    /// Per-appointment toggle label. Walk is not a choice here — Settings can stay Walk.
    var appointmentTitle: String {
        switch self {
        case .transit: ScedraString("Public transport")
        case .drive, .walk: ScedraString("Driving")
        }
    }

    /// English token written into EventKit notes so we can parse the mode later.
    var appointmentTitleStorage: String {
        switch self {
        case .transit: "Public transport"
        case .drive, .walk: "Driving"
        }
    }

    /// Drive vs transit for one appointment. Settings Walk maps to Driving.
    static func appointmentDefault(fromSettings stored: TravelMode? = nil) -> TravelMode {
        let settings = stored ?? TravelMode(rawValue: UserDefaults.standard.string(forKey: UserProfile.travelModeKey) ?? "")
        return settings == .transit ? .transit : .drive
    }

    static func parseAppointmentChoice(_ text: String) -> TravelMode? {
        let folded = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if folded.contains("public")
            || folded.contains("transit")
            || folded.contains("transport")
            || folded.contains("öpnv")
            || folded.contains("opnv") {
            return .transit
        }
        if folded.contains("driv")
            || folded.contains("voiture")
            || folded.contains("coche")
            || folded.contains("auto") {
            return .drive
        }
        return nil
    }
}

enum UserProfile {
    static let nameKey = "scedra.profileName"
    static let homeGapKey = "scedra.homeGapMinutes"
    static let workOutKey = "scedra.workOutGapMinutes"
    static let travelModeKey = "scedra.travelMode"
    static let walkMinutesKey = "scedra.walkMinutes"
    /// Standing “remind me to bring” list — one item per line or comma-separated.
    static let standingBringKey = "scedra.standingBring"
    /// Unset leaving-home buffer. Existing users who already stored 10 keep 10.
    static let defaultHomeGapMinutes = 5
    /// If a home stop would be shorter than this, stay out and work / keep going.
    static let defaultMinimumHomeMinutes = 20

    static var standingBringItems: [String] {
        standingItems(from: UserDefaults.standard.string(forKey: standingBringKey) ?? "")
    }

    static func standingItems(from text: String) -> [String] {
        text
            .split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static var minimumHomeMinutes: Int {
        let stored = UserDefaults.standard.object(forKey: workOutKey) as? Int
        return stored ?? defaultMinimumHomeMinutes
    }

    static var displayName: String {
        (UserDefaults.standard.string(forKey: nameKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var greeting: String {
        let name = displayName
        return name.isEmpty ? ScedraString("Hi") : ScedraString("Hi, \(name)")
    }
}
