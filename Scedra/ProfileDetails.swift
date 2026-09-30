import Foundation

/// Extra named places and freeform notes in Settings — work, school, a second house, etc.
struct ProfilePlace: Equatable, Identifiable, Codable {
    var id: UUID
    var label: String
    var address: String

    init(id: UUID = UUID(), label: String, address: String) {
        self.id = id
        self.label = label
        self.address = address
    }

    var isFilled: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct ProfileDetails: Equatable, Codable {
    var notes: String
    var places: [ProfilePlace]

    static let empty = ProfileDetails(notes: "", places: [])
}

enum ProfileDetailsStore {
    static let key = "scedra.profileDetails"

    static func load() -> ProfileDetails {
        decode(UserDefaults.standard.data(forKey: key))
    }

    static func decode(_ data: Data?) -> ProfileDetails {
        guard let data,
              let details = try? JSONDecoder().decode(ProfileDetails.self, from: data)
        else { return .empty }
        return details
    }

    static func save(_ details: ProfileDetails) {
        guard let data = try? JSONEncoder().encode(details) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func encode(_ details: ProfileDetails) -> Data? {
        try? JSONEncoder().encode(details)
    }

    /// "school", "the school", "at school", "lunch at my school" → the saved School address.
    /// Other people will phrase it differently; the label only has to show up as a whole word.
    static func place(matching query: String, in details: ProfileDetails = load()) -> ProfilePlace? {
        let needle = folded(query)
        guard !needle.isEmpty else { return nil }
        let filled = allPlaces(in: details)
        guard !filled.isEmpty else { return nil }

        if let exact = filled.first(where: { folded($0.label) == needle }) {
            return exact
        }

        let queryWords = words(in: needle)
        let meaningful = queryWords.filter { !fillers.contains($0) }

        var tokenHit: ProfilePlace?
        for place in filled {
            let label = folded(place.label)
            guard !label.isEmpty else { continue }
            let labelWords = words(in: label)
            if needle == label { return place }
            if meaningful.joined(separator: " ") == label { return place }
            if labelWords.count >= 2, needle.contains(label) { return place }
            if queryWords.contains(label) || meaningful.contains(label) {
                tokenHit = place
            }
        }
        return tokenHit
    }

    private static let fillers: Set<String> = [
        "a", "an", "the", "my", "our", "her", "his", "their",
        "at", "to", "for", "in", "on", "of", "and", "or"
    ]

    private static func words(in text: String) -> [String] {
        text
            .split { !$0.isLetter && !$0.isNumber }
            .map { String($0) }
            .filter { !$0.isEmpty }
    }

    static func looksLikeSavedPlace(_ query: String, in details: ProfileDetails = load()) -> Bool {
        place(matching: query, in: details) != nil
    }

    /// Label/address rows, plus "school = 100 Example Ave…" lines in the notes box.
    static func allPlaces(in details: ProfileDetails) -> [ProfilePlace] {
        details.places.filter(\.isFilled) + placesFromNotes(details.notes)
    }

    static func placesFromNotes(_ notes: String) -> [ProfilePlace] {
        notes
            .components(separatedBy: .newlines)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let separator = trimmed.range(of: " = ")
                    ?? trimmed.range(of: "=")
                    ?? trimmed.range(of: ": ", options: .caseInsensitive)
                    ?? trimmed.range(of: " - ")
                    ?? trimmed.range(of: " is ", options: .caseInsensitive)
                else { return nil }
                let label = trimmed[..<separator.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var address = trimmed[separator.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if address.hasPrefix("=") {
                    address = String(address.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard label.count >= 2, label.count <= 40, looksLikeAddress(address) else { return nil }
                return ProfilePlace(label: label, address: address)
            }
    }

    private static func looksLikeAddress(_ text: String) -> Bool {
        text.count >= 6 && text.contains(where: \.isNumber)
    }

    private static func folded(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
