import CoreLocation
import MapKit

struct ResolvedPlace: Equatable {
    let name: String
    let address: String
    let latitude: Double?
    let longitude: Double?
    var caption: String = ScedraString("Nearby match")

    var displayLine: String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return name }
        return "\(name) · \(trimmed)"
    }
}

struct PlaceAreaSplit: Equatable {
    let place: String
    let area: String
}

/// Where a generic (no named-area) POI is searched from. Named-area queries ignore this.
enum PlaceSearchOriginPolicy: Equatable {
    /// "mcdonalds menlo park" — search that area only, never Home or GPS.
    case namedArea
    /// Generic "mcdonalds" when Settings Home is set — nearest to Home.
    case home
    /// Generic POI when Home is empty — nearest to the current pin ("closest to me").
    case currentLocation
}

/// Ordered strategy for one location query, built before any network call so it can be tested.
struct PlaceSearchPlan: Equatable {
    /// Always searched as a whole phrase first — "westwind community barn", not "westwind".
    var fullPhrase: String
    var areaCandidates: [PlaceAreaSplit]
    /// True only for "brand + area" ("mcdonalds menlo park") or an explicit "in/near <area>".
    /// Those must never fall back to the user or home pin.
    var prefersNamedArea: Bool
    /// Multi-word proper names get a much wider search and an unscoped last resort.
    var isDistinctiveVenue: Bool

    /// Home wins for a generic POI when an address is set. Simulator GPS is not "closest".
    func originPolicy(homeAddressIsSet: Bool) -> PlaceSearchOriginPolicy {
        if prefersNamedArea { return .namedArea }
        return homeAddressIsSet ? .home : .currentLocation
    }
}

/// Resolves a generic place name to the closest nearby match.
/// Requests When In Use location only while resolving — never at launch.
final class PlaceResolver {
    static let homeAddressKey = "scedra.homeAddress"

    private static let searchRadiusMeters: CLLocationDistance = 50_000
    private static let maxDistanceMeters: CLLocationDistance = 60_000
    /// A named venue can be several towns over; a franchise should not be.
    private static let wideSearchRadiusMeters: CLLocationDistance = 200_000
    private static let wideMaxDistanceMeters: CLLocationDistance = 250_000
    /// MKLocalSearch with no region returns nothing when Core Location has no fix.
    static let fallbackSearchRadiusMeters: CLLocationDistance = 4_000_000
    static let geocodeHintRadiusMeters: CLLocationDistance = 2_000_000
    /// Geographic center of the contiguous US — a region only, never a travel origin.
    static let fallbackSearchLocation = CLLocation(latitude: 39.8283, longitude: -98.5795)

    private let locationProvider = LocationProvider()

    /// Full-phrase search near a named area, then Home (when set), then last-known /
    /// current pin, then a default-region search for distinctive names and addresses.
    /// Returning nil is fine: the caller keeps the typed text and the event still saves.
    func resolve(_ query: String) async -> ResolvedPlace? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let saved = await resolvedSavedPlace(matching: trimmed) {
            return saved
        }
        if Self.isSpecificAddress(trimmed) {
            return await resolvedAddress(trimmed)
        }

        let phrases = Self.resolutionPhrases(for: trimmed)

        for phrase in phrases {
            guard await isUsablePhrase(phrase, whenShorterThan: trimmed) else { continue }
            if let place = await anchoredPlace(matching: phrase) { return place }
        }

        // Last resort for a distinctive name only: a franchise with no location fix
        // must not resolve to a store in another state.
        for phrase in phrases where Self.isDistinctiveVenue(phrase) {
            guard !Self.searchPlan(for: phrase).prefersNamedArea else { continue }
            guard await isUsablePhrase(phrase, whenShorterThan: trimmed) else { continue }
            if let place = await unscopedPlace(matching: phrase) { return place }
        }
        return nil
    }

    /// The whole phrase first, then progressively shorter trailing spans. When she said
    /// "horse show westwind community barn" with no "at", the leading words may be the
    /// title; dropping them is the only way to reach the venue.
    static func resolutionPhrases(for query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var phrases = [trimmed]
        let joined = joinSplitBrandTokens(trimmed)
        if joined != trimmed {
            phrases.append(joined)
        }
        let plan = searchPlan(for: trimmed)
        // "mcdonalds menlo park" must stay pinned to Menlo Park, never become "menlo park".
        guard !plan.prefersNamedArea, plan.isDistinctiveVenue else { return phrases }

        let tokens = trimmed.split { $0.isWhitespace }.map(String.init)
        // Three words are a venue name ("westwind community barn"), not a title plus a
        // venue — carving those up is what broke the search in the first place.
        guard tokens.count >= 4 else { return phrases }
        // Two dropped words covers "horse show ...". Beyond that the tail is no longer
        // recognisably the thing she named.
        for dropped in 1...min(2, tokens.count - 3) {
            phrases.append(tokens.dropFirst(dropped).joined(separator: " "))
        }
        return phrases
    }

    /// Speech/OCR often splits a brand: "west wind barn" should still search "westwind barn".
    static func joinSplitBrandTokens(_ query: String) -> String {
        query.replacingOccurrences(
            of: #"(?i)\bwest\s+wind\b"#,
            with: "westwind",
            options: .regularExpression
        )
    }

    /// A shortened span that geocodes to a real town is a town, not the venue she meant.
    private func isUsablePhrase(_ phrase: String, whenShorterThan original: String) async -> Bool {
        guard phrase != original else { return true }
        return await geocodedArea(phrase) == nil
    }

    private func anchoredPlace(matching phrase: String) async -> ResolvedPlace? {
        let plan = Self.searchPlan(for: phrase)
        let radius = plan.isDistinctiveVenue ? Self.wideSearchRadiusMeters : Self.searchRadiusMeters
        let maxDistance = plan.isDistinctiveVenue ? Self.wideMaxDistanceMeters : Self.maxDistanceMeters

        for split in plan.areaCandidates {
            guard let center = await geocodedArea(split.area) else { continue }
            let caption = ScedraString("Near \(Self.displayArea(split.area))")
            if let place = await closestPlace(
                matching: plan.fullPhrase,
                near: center,
                caption: caption,
                radius: radius,
                maxDistance: maxDistance
            ) {
                return place
            }
            if plan.prefersNamedArea,
               let place = await closestPlace(
                   matching: split.place,
                   near: center,
                   caption: caption,
                   radius: radius,
                   maxDistance: maxDistance
               ) {
                return place
            }
        }

        if plan.prefersNamedArea {
            // The user named an area — never substitute the user/home pin.
            return nil
        }

        let policy = plan.originPolicy(homeAddressIsSet: Self.isHomeAddressSet)
        if policy == .home {
            if let home = await geocodedHome(),
               let place = await closestPlace(
                   matching: plan.fullPhrase,
                   near: home,
                   caption: ScedraString("Near home"),
                   radius: radius,
                   maxDistance: maxDistance
               ) {
                return place
            }
            // Home is set — do not fall through to Simulator GPS / Apple Park.
            return nil
        }

        // Last-known first so a denied / slow GPS fix does not block "closest to me".
        if let last = locationProvider.lastKnownForSearch(),
           let place = await closestPlace(
               matching: plan.fullPhrase,
               near: last,
               caption: ScedraString("Nearby match"),
               radius: radius,
               maxDistance: maxDistance
           ) {
            return place
        }

        // Distinctive names skip the live-fix wait — unscoped + default region is next.
        if !plan.isDistinctiveVenue,
           let current = await trustedUserLocation(),
           let place = await closestPlace(
               matching: plan.fullPhrase,
               near: current,
               caption: ScedraString("Nearby match"),
               radius: radius,
               maxDistance: maxDistance
           ) {
            return place
        }

        if let home = await geocodedHome(),
           let place = await closestPlace(
               matching: plan.fullPhrase,
               near: home,
               caption: ScedraString("Near home"),
               radius: radius,
               maxDistance: maxDistance
           ) {
            return place
        }
        return nil
    }

    /// Street / "Name · Address" → a pin. Does not wait on GPS.
    private func resolvedAddress(_ query: String) async -> ResolvedPlace? {
        for candidate in Self.addressLookupCandidates(from: query) {
            if let place = await geocodedResolvedAddress(candidate, fallbackName: query) {
                return place
            }
        }
        let hint = await searchHintLocation(allowHomeGeocode: true)
        for candidate in Self.addressLookupCandidates(from: query) {
            if let place = await closestPlace(
                matching: candidate,
                near: hint,
                caption: ScedraString("Address"),
                radius: Self.wideSearchRadiusMeters,
                maxDistance: Self.fallbackSearchRadiusMeters
            ) {
                return place
            }
        }
        return nil
    }

    /// "McDonald's · 165 University Ave" looks up the street first.
    static func addressLookupCandidates(from query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let range = trimmed.range(of: " · ") else { return [trimmed] }
        let name = String(trimmed[..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let address = String(trimmed[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []
        var seen = Set<String>()
        for item in [address, trimmed, name] where !item.isEmpty {
            if seen.insert(item.lowercased()).inserted {
                candidates.append(item)
            }
        }
        return candidates
    }

    /// Home, last-known pin, then the continental default. Never a travel origin.
    static func searchHint(home: CLLocation?, lastKnown: CLLocation?) -> CLLocation {
        home ?? lastKnown ?? fallbackSearchLocation
    }

    static func localSearchRegion(
        around center: CLLocation,
        radius: CLLocationDistance
    ) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: center.coordinate,
            latitudinalMeters: radius,
            longitudinalMeters: radius
        )
    }

    /// Settings Home, geocoded. Nil when the address is empty or Maps cannot place it.
    func geocodedHomeLocation() async -> CLLocation? {
        await geocodedHome()
    }

    /// A named extra address from Settings (work, school, …).
    func geocodedSavedPlace(matching query: String) async -> CLLocation? {
        guard let place = ProfileDetailsStore.place(matching: query) else { return nil }
        return await geocodedAddress(place.address)
    }

    func resolvedSavedPlace(matching query: String) async -> ResolvedPlace? {
        guard let place = ProfileDetailsStore.place(matching: query) else { return nil }
        let location = await geocodedAddress(place.address)
        return ResolvedPlace(
            name: place.label,
            address: place.address,
            latitude: location?.coordinate.latitude,
            longitude: location?.coordinate.longitude,
            caption: ScedraString("Saved \(place.label)")
        )
    }

    func geocodedAddress(_ address: String) async -> CLLocation? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? await geocodeMarks(trimmed).first?.location
    }

    /// Origin for Review drive estimates: Settings home when set, else current location.
    func travelOrigin() async -> CLLocation? {
        await resolvedTravelOrigin()?.location
    }

    struct TravelOriginPin {
        var location: CLLocation
        var fromHome: Bool
    }

    func resolvedTravelOrigin() async -> TravelOriginPin? {
        let home = await geocodedHome()
        // Always read Core Location (When In Use). Review still prefers Home when it
        // geocodes; a Simulator Apple Park fix is valid when Home is empty.
        let current = await locationProvider.currentFix()
        let trustCurrent = TravelEstimator.shouldTrustCurrentFix(
            homeAddressIsSet: home != nil,
            isSimulator: false
        )
        guard let pin = TravelEstimator.preferredOrigin(
            current: current,
            home: home,
            currentIsTrusted: trustCurrent && current != nil
        ) else { return nil }
        let fromHome = home.map {
            $0.coordinate.latitude == pin.coordinate.latitude
                && $0.coordinate.longitude == pin.coordinate.longitude
        } ?? false
        return TravelOriginPin(location: pin, fromHome: fromHome)
    }

    /// Live GPS only when Home is empty ("closest to me right now").
    private func trustedUserLocation() async -> CLLocation? {
        await locationProvider.currentFix()
    }

    /// Settings Home has a typed address. Geocoding may still fail; the policy still prefers Home.
    static var isHomeAddressSet: Bool {
        let address = UserDefaults.standard.string(forKey: homeAddressKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !address.isEmpty
    }

    /// Testable origin policy: named area wins, else Home when set, else the current pin.
    static func originPolicy(for query: String, homeAddressIsSet: Bool) -> PlaceSearchOriginPolicy {
        searchPlan(for: query).originPolicy(homeAddressIsSet: homeAddressIsSet)
    }

    static func searchPlan(for query: String) -> PlaceSearchPlan {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let splits = placeAreaSplits(from: trimmed)
        return PlaceSearchPlan(
            fullPhrase: trimmed,
            areaCandidates: splits,
            prefersNamedArea: namesAnArea(trimmed, splits: splits),
            isDistinctiveVenue: isDistinctiveVenue(trimmed)
        )
    }

    /// "mcdonalds menlo park" and "mcdonalds in menlo park" name an area.
    /// "westwind community barn" only *looks* like it does because of the word-count heuristic.
    static func namesAnArea(_ query: String, splits: [PlaceAreaSplit]) -> Bool {
        guard !splits.isEmpty else { return false }
        if areaPrepositionSplit(from: query) != nil { return true }
        return splits.contains { PlaceMemory.isGenericPOI($0.place) }
    }

    /// A multi-word name that is not a known chain — search it whole and search wide.
    static func isDistinctiveVenue(_ query: String) -> Bool {
        let words = query
            .split { $0.isWhitespace }
            .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty && !articles.contains($0) }
        guard words.count >= 2 else { return false }
        return !PlaceMemory.isGenericPOI(query)
    }

    /// Generic names ("mcdonalds", "the dentist") have no area. "mcdonalds menlo park" does.
    ///
    /// Only two shapes name an area: an explicit "in/near <area>", or a known chain
    /// followed by the rest. Splitting on word position alone invented areas out of
    /// venue names — "westwind" + "community barn" — and sent the wrong string to the map.
    static func placeAreaSplits(from query: String) -> [PlaceAreaSplit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var splits: [PlaceAreaSplit] = []
        var seen = Set<String>()
        func add(_ place: String, _ area: String) {
            let place = place.trimmingCharacters(in: .whitespacesAndNewlines)
            var area = area.trimmingCharacters(in: .whitespacesAndNewlines)
            area = area.replacingOccurrences(
                of: #"(?i)^(?:in|near|around|by|at)\s+"#,
                with: "",
                options: .regularExpression
            )
            guard !place.isEmpty, !area.isEmpty else { return }
            let key = "\(place.lowercased())|\(area.lowercased())"
            guard seen.insert(key).inserted else { return }
            splits.append(PlaceAreaSplit(place: place, area: area))
        }

        if let split = areaPrepositionSplit(from: trimmed) {
            add(split.place, split.area)
        }
        if let brand = PlaceMemory.brandAndRemainder(in: trimmed) {
            add(brand.brand, brand.remainder)
        }
        return splits
    }

    /// "mcdonalds in menlo park" -> place "mcdonalds", area "menlo park".
    static func areaPrepositionSplit(from query: String) -> PlaceAreaSplit? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let nsText = trimmed as NSString
        let full = NSRange(location: 0, length: nsText.length)
        let pattern = #"^(?i)(.+?)\s+(?:in|near|around|by|at)\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, options: [], range: full),
              match.numberOfRanges == 3
        else {
            return nil
        }
        let place = nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        let area = nsText.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !place.isEmpty, !area.isEmpty else { return nil }
        return PlaceAreaSplit(place: place, area: area)
    }

    /// Picks the nearest candidate within `maxDistance`. Far franchises are dropped.
    static func closestMapItem(
        in items: [MKMapItem],
        near center: CLLocation,
        maxDistance: CLLocationDistance = 40_000
    ) -> MKMapItem? {
        items
            .compactMap { item -> (MKMapItem, CLLocationDistance)? in
                guard let location = item.placemark.location else { return nil }
                let distance = location.distance(from: center)
                guard distance <= maxDistance else { return nil }
                return (item, distance)
            }
            .min(by: { $0.1 < $1.1 })?
            .0
    }

    /// True when the string already looks like a street address or a resolved "Name · Address".
    static func isSpecificAddress(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains(" · ") { return true }

        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue)
        let range = NSRange(location: 0, length: (trimmed as NSString).length)
        if let match = detector?.firstMatch(in: trimmed, options: [], range: range),
           match.resultType.contains(.address),
           let street = match.addressComponents?[.street],
           street.rangeOfCharacter(from: .decimalDigits) != nil {
            return true
        }

        return trimmed.range(of: #"\b\d{1,6}\s+\p{L}"#, options: .regularExpression) != nil
    }

    private func geocodedHome() async -> CLLocation? {
        let address = UserDefaults.standard.string(forKey: Self.homeAddressKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return await geocodedAddress(address)
    }

    private static let articles: Set<String> = ["a", "an", "the"]

    private func geocodedArea(_ area: String) async -> CLLocation? {
        do {
            let marks = try await geocodeMarks(area)
            guard let mark = marks.first, Self.looksLikeNamedArea(mark, area: area) else { return nil }
            return mark.location
        } catch {
            return nil
        }
    }

    /// Region hint first so locale / no-GPS does not empty the geocoder; then unbounded.
    private func geocodeMarks(_ address: String) async throws -> [CLPlacemark] {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let hint = await searchHintLocation(allowHomeGeocode: false)
        let region = CLCircularRegion(
            center: hint.coordinate,
            radius: Self.geocodeHintRadiusMeters,
            identifier: "scedra.geocode"
        )
        do {
            let marks = try await CLGeocoder().geocodeAddressString(trimmed, in: region)
            if !marks.isEmpty { return marks }
        } catch {
            // Unbounded retry below.
        }
        return try await CLGeocoder().geocodeAddressString(trimmed)
    }

    private func geocodedResolvedAddress(_ address: String, fallbackName: String) async -> ResolvedPlace? {
        do {
            let marks = try await geocodeMarks(address)
            guard let mark = marks.first, let location = mark.location else { return nil }
            let name = mark.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let displayName = name.isEmpty ? fallbackName : name
            let line = Self.shortAddress(MKPlacemark(placemark: mark))
            return ResolvedPlace(
                name: displayName,
                address: line.isEmpty ? address : line,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                caption: ScedraString("Address")
            )
        } catch {
            return nil
        }
    }

    /// Does not wait for a live GPS authorization / fix.
    private func searchHintLocation(allowHomeGeocode: Bool) async -> CLLocation {
        let home = allowHomeGeocode ? await geocodedHome() : nil
        return Self.searchHint(home: home, lastKnown: locationProvider.lastKnownForSearch())
    }

    /// City/neighborhood names match locality (or equal name). Rejects stray POI hits like "foods".
    static func looksLikeNamedArea(_ mark: CLPlacemark, area: String) -> Bool {
        let needle = folded(area)
        guard !needle.isEmpty else { return false }
        let wordCount = area.split { $0.isWhitespace }.count
        let fields = [mark.locality, mark.subLocality, mark.name]
            .compactMap { $0.map(folded) }
            .filter { !$0.isEmpty }
        return fields.contains { field in
            if field == needle { return true }
            guard wordCount >= 2 else { return false }
            if field.contains(needle) { return true }
            // A shorter field only counts if it is itself a multi-word place name, so
            // "community barn" can't be anchored to a stray place called "Barn".
            return field.split(separator: " ").count >= 2 && needle.contains(field)
        }
    }

    private nonisolated static func folded(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    private static func displayArea(_ area: String) -> String {
        area.split { $0.isWhitespace }
            .map { $0.localizedCapitalized }
            .joined(separator: " ")
    }

    private func closestPlace(
        matching query: String,
        near center: CLLocation,
        caption: String,
        radius: CLLocationDistance,
        maxDistance: CLLocationDistance
    ) async -> ResolvedPlace? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        request.region = Self.localSearchRegion(around: center, radius: radius)

        do {
            let response = try await MKLocalSearch(request: request).start()
            let closest = Self.closestMapItem(
                in: response.mapItems,
                near: center,
                maxDistance: maxDistance
            )
            guard let closest else { return nil }
            return Self.place(from: closest, fallbackName: query, caption: caption)
        } catch {
            return nil
        }
    }

    /// Distinctive multi-word name when Home / last-known came up empty.
    /// Always sets a region — nil region + no GPS is why MKLocalSearch returned nothing.
    private func unscopedPlace(matching query: String) async -> ResolvedPlace? {
        let center = await searchHintLocation(allowHomeGeocode: true)
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        request.region = Self.localSearchRegion(
            around: center,
            radius: Self.fallbackSearchRadiusMeters
        )
        do {
            let response = try await MKLocalSearch(request: request).start()
            let item: MKMapItem?
            if Self.isFallbackSearchLocation(center) {
                item = response.mapItems.first
            } else {
                item = Self.closestMapItem(
                    in: response.mapItems,
                    near: center,
                    maxDistance: Self.fallbackSearchRadiusMeters
                ) ?? response.mapItems.first
            }
            if let item, let place = Self.place(
                from: item,
                fallbackName: query,
                caption: ScedraString("Best name match")
            ) {
                return place
            }
        } catch {
            // Geocode below.
        }
        if var place = await geocodedResolvedAddress(query, fallbackName: query) {
            place.caption = ScedraString("Best name match")
            return place
        }
        return nil
    }

    static func isFallbackSearchLocation(_ location: CLLocation) -> Bool {
        location.coordinate.latitude == fallbackSearchLocation.coordinate.latitude
            && location.coordinate.longitude == fallbackSearchLocation.coordinate.longitude
    }

    private static func place(from item: MKMapItem, fallbackName: String, caption: String) -> ResolvedPlace? {
        let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (name?.isEmpty == false) ? name! : fallbackName
        let address = shortAddress(item.placemark)
        guard !displayName.isEmpty || !address.isEmpty else { return nil }
        let coordinate = item.placemark.coordinate
        let hasCoordinate = CLLocationCoordinate2DIsValid(coordinate)
        return ResolvedPlace(
            name: displayName,
            address: address,
            latitude: hasCoordinate ? coordinate.latitude : nil,
            longitude: hasCoordinate ? coordinate.longitude : nil,
            caption: caption
        )
    }

    private static func shortAddress(_ placemark: MKPlacemark) -> String {
        let street = [placemark.subThoroughfare, placemark.thoroughfare]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !street.isEmpty {
            if let city = placemark.locality, !city.isEmpty {
                return "\(street), \(city)"
            }
            return street
        }
        return [placemark.locality, placemark.administrativeArea]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

}
