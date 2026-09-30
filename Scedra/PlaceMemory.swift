import Foundation

struct RememberedPlace: Equatable, Codable {
    var location: String
    var latitude: Double?
    var longitude: Double?
}

/// Remembers the last saved place for a named appointment type ("dentist").
/// Generic POIs like McDonald's still resolve to Home / a named area.
enum PlaceMemory {
    static let storageKey = "scedra.placeMemory"

    static var defaults: UserDefaults = .standard

    static func remember(title: String, location: String, latitude: Double?, longitude: Double?) {
        let key = memoryKey(from: title)
        let place = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !place.isEmpty, !isGenericPOI(title) else { return }
        var map = load()
        let remembered = RememberedPlace(location: place, latitude: latitude, longitude: longitude)
        map[key] = remembered
        for alias in distinctiveAliases(from: place) where alias != key && !isGenericPOI(alias) {
            map[alias] = remembered
        }
        save(map)
    }

    static func remembered(forTitle title: String) -> RememberedPlace? {
        let key = memoryKey(from: title)
        guard !key.isEmpty, !isGenericPOI(title) else { return nil }
        return load()[key]
    }

    /// A leftover nickname ("barn") that appears in a saved venue name.
    static func remembered(matchingPlaceQuery query: String) -> RememberedPlace? {
        let folded = normalize(query)
        guard !folded.isEmpty, !isGenericPOI(query) else { return nil }
        let map = load()
        if let hit = map[folded] { return hit }
        let key = memoryKey(from: query)
        if key != folded, let hit = map[key] { return hit }
        return nil
    }

    /// Use memory when the user named a type (dentist) but not a new address/area.
    static func shouldPreferMemory(title: String, locationQuery: String) -> Bool {
        guard !isGenericPOI(title), !isGenericPOI(locationQuery) else { return false }
        if PlaceResolver.searchPlan(for: locationQuery).prefersNamedArea { return false }
        if PlaceResolver.isSpecificAddress(locationQuery) { return false }
        let query = normalize(locationQuery)
        if query.isEmpty { return true }
        let titleKey = memoryKey(from: title)
        return query == titleKey || memoryKey(from: locationQuery) == titleKey
    }

    static func memoryKey(from title: String) -> String {
        let words = normalize(title)
            .split { $0.isWhitespace }
            .map(String.init)
            .filter { !filler.contains($0) }
        return words.prefix(3).joined(separator: " ")
    }

    static func isGenericPOI(_ text: String) -> Bool {
        let folded = normalize(text)
        guard !folded.isEmpty else { return false }
        if poiBrands.contains(folded) { return true }
        for brand in poiBrands {
            if folded == brand || folded.hasPrefix(brand + " ") { return true }
        }
        return false
    }

    /// "mcdonalds menlo park" -> ("mcdonalds", "menlo park"). Nil when the leading words
    /// are not a known chain, so a venue name like "westwind community barn" is never
    /// carved into a place plus an invented area.
    static func brandAndRemainder(in text: String) -> (brand: String, remainder: String)? {
        let tokens = text.split { $0.isWhitespace }.map(String.init)
        guard tokens.count >= 2 else { return nil }
        for count in 1..<tokens.count {
            let brand = tokens.prefix(count).joined(separator: " ")
            guard isGenericPOI(brand) else { continue }
            return (brand, tokens.dropFirst(count).joined(separator: " "))
        }
        return nil
    }

    /// "Westwind Community Barn · 27210 Altamont Rd" also answers to "barn".
    static func distinctiveAliases(from location: String) -> [String] {
        let name = location.split(separator: "·").first.map(String.init) ?? location
        let tokens = normalize(name)
            .split { $0.isWhitespace }
            .map(String.init)
            .filter { !filler.contains($0) && !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        var aliases = [tokens.joined(separator: " ")]
        for token in tokens where nicknameSuffixes.contains(token) {
            aliases.append(token)
        }
        return aliases
    }

    static func resetForTests() {
        defaults.removeObject(forKey: storageKey)
    }

    private static func load() -> [String: RememberedPlace] {
        guard let data = defaults.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: RememberedPlace].self, from: data)) ?? [:]
    }

    private static func save(_ map: [String: RememberedPlace]) {
        if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
    }

    private static let filler: Set<String> = [
        "a", "an", "the", "at", "on", "for", "to", "from", "and", "then", "also"
    ]

    private static let nicknameSuffixes: Set<String> = [
        "barn", "stables", "stable", "ranch", "marina", "rink"
    ]

    private static let poiBrands: Set<String> = [
        "mcdonalds", "mcdonald's", "mcdonald",
        "starbucks", "target", "walmart", "costco",
        "chipotle", "subway", "taco bell", "tacobell",
        "dunkin", "dunkin'",
        "whole foods", "trader joe's", "trader joes", "trader joe",
        "cvs", "walgreens", "ikea", "safeway"
    ]
}
