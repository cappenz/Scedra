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
    /// Generic "mcdonalds" nearest to Home — when Search from is Home, or no pin.
    case home
    /// Generic POI nearest to the current / last-known pin ("closest to me").
    case currentLocation
}

/// A Maps hit the distinctive-name picker can score without EventKit / MKMapItem.
struct PlaceCandidate: Equatable {
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double

    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    func asResolvedPlace(caption: String) -> ResolvedPlace {
        ResolvedPlace(
            name: name.isEmpty ? address : name,
            address: address,
            latitude: latitude,
            longitude: longitude,
            caption: caption
        )
    }
}

/// Where a distinctive MKLocalSearch is centered. Never a travel origin.
enum PlaceLookupAnchor: Equatable {
    case lastKnown
    case home
    case continentalUS
}

/// Ordered lookup for one query. Distinctive names search last-known, Home, and the US,
/// then geocode — they do not stop at a nearby generic POI.
struct PlaceLookupPlan: Equatable {
    var queries: [String]
    var isDistinctiveVenue: Bool
    var prefersNamedArea: Bool
    var searchAnchors: [PlaceLookupAnchor]
    var geocodeAfterSearch: Bool
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

    /// Named area still wins. Home-first for a generic POI only when Search from is
    /// Home, or there is no current/last-known pin.
    func originPolicy(
        homeAddressIsSet: Bool,
        searchFrom: PlaceSearchFrom = .currentLocation,
        hasLocationPin: Bool = false
    ) -> PlaceSearchOriginPolicy {
        if prefersNamedArea { return .namedArea }
        if searchFrom == .home {
            return homeAddressIsSet ? .home : .currentLocation
        }
        if hasLocationPin { return .currentLocation }
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

    /// Full-phrase search. Distinctive venues (Westwind Community Barn) match by name
    /// across last-known, Home, and a US-sized region, then geocode — never a nearby
    /// generic POI. Generic chains still follow Search from / Home-first.
    /// Existing calendar events pass `allowLiveGPS: false` so a missing fix cannot
    /// block geocoding a street that is already on the event.
    func resolve(_ query: String, allowLiveGPS: Bool = true) async -> ResolvedPlace? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let remembered = await resolvedRememberedPlace(matching: trimmed) {
            return remembered
        }
        if let saved = await resolvedSavedPlace(matching: trimmed) {
            return saved
        }
        if Self.isSpecificAddress(trimmed) {
            return await resolvedAddress(trimmed)
        }

        let phrases = Self.resolutionPhrases(for: trimmed)

        for phrase in phrases {
            guard await isUsablePhrase(phrase, whenShorterThan: trimmed) else { continue }
            let plan = Self.searchPlan(for: phrase)
            if plan.isDistinctiveVenue, !plan.prefersNamedArea {
                if let place = await distinctivePlace(matching: phrase) { return place }
                continue
            }
            if let place = await anchoredPlace(matching: phrase, allowLiveGPS: allowLiveGPS) {
                return place
            }
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

    /// Name-first lookup. Home is a search region, never a reason to keep a nearby "Community Center".
    private func distinctivePlace(matching phrase: String) async -> ResolvedPlace? {
        let lastKnown = locationProvider.lastKnownForSearch()
        let home = await geocodedHome()
        var centers: [CLLocation] = []
        var seen = Set<String>()
        func add(_ location: CLLocation?) {
            guard let location else { return }
            let key = String(format: "%.4f,%.4f", location.coordinate.latitude, location.coordinate.longitude)
            guard seen.insert(key).inserted else { return }
            centers.append(location)
        }
        add(lastKnown)
        add(home)
        add(Self.fallbackSearchLocation)

        for query in Self.lookupQueries(for: phrase) {
            for center in centers {
                if let place = await nameMatchedPlace(
                    matching: query,
                    near: center,
                    radius: Self.fallbackSearchRadiusMeters
                ) {
                    return place
                }
            }
            if var place = await geocodedResolvedAddress(query, fallbackName: query) {
                place.caption = ScedraString("Best name match")
                return place
            }
        }
        return nil
    }

    private func nameMatchedPlace(
        matching query: String,
        near center: CLLocation,
        radius: CLLocationDistance
    ) async -> ResolvedPlace? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        request.region = Self.localSearchRegion(around: center, radius: radius)
        do {
            let response = try await MKLocalSearch(request: request).start()
            let candidates = response.mapItems.compactMap(Self.candidate(from:))
            guard let picked = Self.preferredCandidate(
                from: candidates,
                query: query,
                near: center,
                distinctive: true
            ) else {
                return nil
            }
            return picked.asResolvedPlace(caption: ScedraString("Best name match"))
        } catch {
            return nil
        }
    }

    private func anchoredPlace(matching phrase: String, allowLiveGPS: Bool) async -> ResolvedPlace? {
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

        let lastKnown = locationProvider.lastKnownForSearch()
        let policy = plan.originPolicy(
            homeAddressIsSet: Self.isHomeAddressSet,
            searchFrom: PlaceSearchFrom.resolved(),
            hasLocationPin: lastKnown != nil
        )
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
        if let lastKnown,
           let place = await closestPlace(
               matching: plan.fullPhrase,
               near: lastKnown,
               caption: ScedraString("Nearby match"),
               radius: radius,
               maxDistance: maxDistance
           ) {
            return place
        }

        // Distinctive names skip the live-fix wait — unscoped + default region is next.
        // Existing calendar events must not wait on GPS either.
        if allowLiveGPS,
           !plan.isDistinctiveVenue,
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
        let centers = Self.geocodeRegionCenters(
            lastKnown: locationProvider.lastKnownForSearch(),
            home: await geocodedHome()
        )
        for center in centers {
            for candidate in Self.addressLookupCandidates(from: query) {
                if let place = await closestPlace(
                    matching: candidate,
                    near: center,
                    caption: ScedraString("Address"),
                    radius: Self.wideSearchRadiusMeters,
                    maxDistance: Self.fallbackSearchRadiusMeters
                ) {
                    return place
                }
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

    /// Search region: current/last-known over Home when Search from is Current location.
    /// Fallback Home, then the continental default. Never a travel origin.
    static func searchHint(
        home: CLLocation?,
        lastKnown: CLLocation?,
        searchFrom: PlaceSearchFrom = .currentLocation
    ) -> CLLocation {
        if searchFrom == .currentLocation {
            return lastKnown ?? home ?? fallbackSearchLocation
        }
        return home ?? lastKnown ?? fallbackSearchLocation
    }

    /// Last-known, then Home, then the continental default. Empty/throw on one
    /// region retries the next — a stale GPS pin must not be the only hint.
    static func geocodeRegionCenters(lastKnown: CLLocation?, home: CLLocation?) -> [CLLocation] {
        var centers: [CLLocation] = []
        var seen = Set<String>()
        func add(_ location: CLLocation?) {
            guard let location else { return }
            let key = String(format: "%.4f,%.4f", location.coordinate.latitude, location.coordinate.longitude)
            guard seen.insert(key).inserted else { return }
            centers.append(location)
        }
        add(lastKnown)
        add(home)
        add(fallbackSearchLocation)
        return centers
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

    /// Confirmed distinctive venues (Westwind) reuse the saved pin — no second Maps roll of the dice.
    private func resolvedRememberedPlace(matching query: String) async -> ResolvedPlace? {
        guard !PlaceMemory.isGenericPOI(query) else { return nil }
        guard let remembered = PlaceMemory.remembered(matchingPlaceQuery: query)
            ?? PlaceMemory.remembered(forTitle: query)
        else { return nil }
        if let place = Self.resolvedPlace(fromRemembered: remembered) {
            return place
        }
        if let place = await resolvedAddress(remembered.location) {
            return ResolvedPlace(
                name: place.name,
                address: place.address,
                latitude: place.latitude,
                longitude: place.longitude,
                caption: ScedraString("Remembered")
            )
        }
        return nil
    }

    static func resolvedPlace(fromRemembered remembered: RememberedPlace) -> ResolvedPlace? {
        guard let latitude = remembered.latitude, let longitude = remembered.longitude else {
            return nil
        }
        let line = remembered.location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        let parts = line.split(separator: "·", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let name = parts.first ?? line
        let address = parts.count > 1 ? parts[1] : ""
        return ResolvedPlace(
            name: name,
            address: address,
            latitude: latitude,
            longitude: longitude,
            caption: ScedraString("Remembered")
        )
    }

    func geocodedAddress(_ address: String) async -> CLLocation? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? await geocodeMarks(trimmed).first?.location
    }

    /// Origin for Review drive estimates: current/last-known when that setting is on.
    func travelOrigin() async -> CLLocation? {
        await resolvedTravelOrigin()?.location
    }

    struct TravelOriginPin {
        var location: CLLocation
        var fromHome: Bool
    }

    func resolvedTravelOrigin() async -> TravelOriginPin? {
        let home = await geocodedHome()
        let searchFrom = PlaceSearchFrom.resolved()
        let lastKnown = locationProvider.lastKnownForSearch()
        // Always read Core Location (When In Use) when we may route from here.
        let current = searchFrom == .currentLocation
            ? await locationProvider.currentFix()
            : (home == nil ? await locationProvider.currentFix() : nil)
        let trustCurrent = TravelEstimator.shouldTrustCurrentFix(
            homeAddressIsSet: home != nil,
            isSimulator: false,
            searchFrom: searchFrom
        )
        guard let pin = TravelEstimator.preferredOrigin(
            current: current,
            home: home,
            currentIsTrusted: trustCurrent && current != nil,
            lastKnown: lastKnown,
            searchFrom: searchFrom
        ) else { return nil }
        return travelOriginPin(pin, home: home)
    }

    /// Home / last-known region for calendar backfill. Does not wait on a live GPS fix.
    func resolvedSearchOrigin() async -> TravelOriginPin? {
        let home = await geocodedHome()
        let lastKnown = locationProvider.lastKnownForSearch()
        let searchFrom = PlaceSearchFrom.resolved()
        guard let pin = TravelEstimator.preferredOrigin(
            current: nil,
            home: home,
            currentIsTrusted: false,
            lastKnown: lastKnown,
            searchFrom: searchFrom
        ) else { return nil }
        return travelOriginPin(pin, home: home)
    }

    private func travelOriginPin(_ pin: CLLocation, home: CLLocation?) -> TravelOriginPin {
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

    /// Testable origin policy: named area wins, else Home when that setting is on
    /// or there is no pin, else the current pin.
    static func originPolicy(
        for query: String,
        homeAddressIsSet: Bool,
        searchFrom: PlaceSearchFrom = .currentLocation,
        hasLocationPin: Bool = false
    ) -> PlaceSearchOriginPolicy {
        searchPlan(for: query).originPolicy(
            homeAddressIsSet: homeAddressIsSet,
            searchFrom: searchFrom,
            hasLocationPin: hasLocationPin
        )
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

    /// Full query, split-brand repair, then filler stripped. Distinctive names keep
    /// "community barn" — only articles / prepositions drop.
    static func lookupQueries(for query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var queries: [String] = []
        var seen = Set<String>()
        func add(_ value: String) {
            let next = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !next.isEmpty, seen.insert(folded(next)).inserted else { return }
            queries.append(next)
        }
        add(trimmed)
        add(joinSplitBrandTokens(trimmed))
        add(stripFillerWords(trimmed))
        add(stripFillerWords(joinSplitBrandTokens(trimmed)))
        return queries
    }

    static func stripFillerWords(_ query: String) -> String {
        query
            .split { $0.isWhitespace }
            .filter { !lookupFiller.contains(folded(String($0)).trimmingCharacters(in: .punctuationCharacters)) }
            .joined(separator: " ")
    }

    /// Distinctive names always try last-known, Home, and the US, then geocode.
    /// Generic "coffee" / McDonald's keep Home-first when Search from is Home.
    static func lookupPlan(
        for query: String,
        searchFrom: PlaceSearchFrom = .currentLocation,
        homeAddressIsSet: Bool,
        hasLocationPin: Bool = false
    ) -> PlaceLookupPlan {
        let search = searchPlan(for: query)
        let queries = lookupQueries(for: query)
        if search.prefersNamedArea {
            return PlaceLookupPlan(
                queries: queries,
                isDistinctiveVenue: search.isDistinctiveVenue,
                prefersNamedArea: true,
                searchAnchors: [],
                geocodeAfterSearch: false
            )
        }
        if search.isDistinctiveVenue {
            var anchors: [PlaceLookupAnchor] = []
            if hasLocationPin { anchors.append(.lastKnown) }
            if homeAddressIsSet { anchors.append(.home) }
            anchors.append(.continentalUS)
            return PlaceLookupPlan(
                queries: queries,
                isDistinctiveVenue: true,
                prefersNamedArea: false,
                searchAnchors: anchors,
                geocodeAfterSearch: true
            )
        }
        let policy = search.originPolicy(
            homeAddressIsSet: homeAddressIsSet,
            searchFrom: searchFrom,
            hasLocationPin: hasLocationPin
        )
        let anchors: [PlaceLookupAnchor]
        switch policy {
        case .namedArea:
            anchors = []
        case .home:
            anchors = homeAddressIsSet ? [.home] : (hasLocationPin ? [.lastKnown] : [])
        case .currentLocation:
            anchors = hasLocationPin ? [.lastKnown] : (homeAddressIsSet ? [.home] : [])
        }
        return PlaceLookupPlan(
            queries: queries,
            isDistinctiveVenue: false,
            prefersNamedArea: false,
            searchAnchors: anchors,
            geocodeAfterSearch: false
        )
    }

    static let distinctiveMatchMinimum = 150

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

    static func candidate(from item: MKMapItem) -> PlaceCandidate? {
        let coordinate = item.placemark.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let address = shortAddress(item.placemark)
        guard !name.isEmpty || !address.isEmpty else { return nil }
        return PlaceCandidate(
            name: name,
            address: address,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }

    /// Distinctive: best name match, even if a generic POI sits closer to Home.
    /// Generic: nearest within the usual radius.
    static func preferredCandidate(
        from items: [PlaceCandidate],
        query: String,
        near center: CLLocation?,
        distinctive: Bool
    ) -> PlaceCandidate? {
        if distinctive {
            let scored = items.compactMap { item -> (PlaceCandidate, Int)? in
                let score = distinctiveMatchScore(query: query, name: item.name, address: item.address)
                guard score >= distinctiveMatchMinimum else { return nil }
                return (item, score)
            }
            return scored.max { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                guard let center else { return false }
                return lhs.0.location.distance(from: center) > rhs.0.location.distance(from: center)
            }?.0
        }
        guard let center else { return items.first }
        return items.min { lhs, rhs in
            lhs.location.distance(from: center) < rhs.location.distance(from: center)
        }
    }

    static func distinctiveMatchScore(query: String, name: String, address: String = "") -> Int {
        let q = significantTokens(query)
        guard !q.isEmpty else { return 0 }
        let foldedName = folded(name)
        let foldedQuery = folded(query)
        if foldedName == foldedQuery { return 1000 }
        if foldedName.contains(foldedQuery) { return 800 + q.count * 10 }
        let hay = significantTokens(name) + significantTokens(address)
        let overlap = q.filter { token in
            hay.contains { candidate in
                candidate == token || candidate.hasPrefix(token) || token.hasPrefix(candidate)
            }
        }
        if overlap.count == q.count { return 600 + overlap.count * 10 }
        if overlap.count >= 2 { return 200 + overlap.count * 10 }
        if let first = q.first, first.count >= 5, overlap.contains(first) { return 150 }
        return 0
    }

    static func significantTokens(_ text: String) -> [String] {
        text.split { $0.isWhitespace }
            .map { folded(String($0)).trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty && !lookupFiller.contains($0) }
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

    /// Street-like span inside a longer notes line ("Meet at 27210 Altamont Rd, Los Altos Hills").
    static func addressInText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let nsText = trimmed as NSString
        let full = NSRange(location: 0, length: nsText.length)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue)
        if let match = detector?.firstMatch(in: trimmed, options: [], range: full),
           match.resultType.contains(.address) {
            let snippet = nsText.substring(with: match.range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if isSpecificAddress(snippet) { return snippet }
        }
        if let regex = try? NSRegularExpression(pattern: #"\b\d{1,6}\s+\p{L}[^,\n]{1,}(?:,\s*[^,\n]+)*"#),
           let match = regex.firstMatch(in: trimmed, options: [], range: full) {
            let snippet = nsText.substring(with: match.range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if isSpecificAddress(snippet) { return snippet }
        }
        if isSpecificAddress(trimmed) { return trimmed }
        return nil
    }

    private static let homePinLock = NSLock()
    private static var cachedHomePin: (address: String, location: CLLocation?)?

    private func geocodedHome() async -> CLLocation? {
        let address = UserDefaults.standard.string(forKey: Self.homeAddressKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !address.isEmpty else { return nil }
        Self.homePinLock.lock()
        if Self.cachedHomePin?.address == address {
            let cached = Self.cachedHomePin?.location
            Self.homePinLock.unlock()
            return cached
        }
        Self.homePinLock.unlock()
        // Home itself uses the US region then unbounded so a bad last-known
        // cannot recurse through geocodeMarks → geocodedHome.
        let location = try? await geocodeMarks(
            address,
            centers: [Self.fallbackSearchLocation]
        ).first?.location
        Self.homePinLock.lock()
        Self.cachedHomePin = (address, location)
        Self.homePinLock.unlock()
        return location
    }

    private static let articles: Set<String> = ["a", "an", "the"]
    private static let lookupFiller: Set<String> = [
        "a", "an", "the", "at", "in", "near", "around", "by", "on", "to", "from", "and"
    ]

    private func geocodedArea(_ area: String) async -> CLLocation? {
        do {
            let marks = try await geocodeMarks(area)
            guard let mark = marks.first, Self.looksLikeNamedArea(mark, area: area) else { return nil }
            return mark.location
        } catch {
            return nil
        }
    }

    /// Last-known, then Home, then the US region, then unbounded. A previous empty
    /// or thrown result (wrong GPS region) retries instead of giving up.
    private func geocodeMarks(
        _ address: String,
        centers: [CLLocation]? = nil
    ) async throws -> [CLPlacemark] {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let hints: [CLLocation]
        if let centers {
            hints = centers
        } else {
            hints = Self.geocodeRegionCenters(
                lastKnown: locationProvider.lastKnownForSearch(),
                home: await geocodedHome()
            )
        }
        var seen = Set<String>()
        for hint in hints {
            let key = String(format: "%.4f,%.4f", hint.coordinate.latitude, hint.coordinate.longitude)
            guard seen.insert(key).inserted else { continue }
            let region = CLCircularRegion(
                center: hint.coordinate,
                radius: Self.geocodeHintRadiusMeters,
                identifier: "scedra.geocode"
            )
            do {
                let marks = try await CLGeocoder().geocodeAddressString(trimmed, in: region)
                if !marks.isEmpty { return marks }
            } catch {
                continue
            }
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
        return Self.searchHint(
            home: home,
            lastKnown: locationProvider.lastKnownForSearch(),
            searchFrom: PlaceSearchFrom.resolved()
        )
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
