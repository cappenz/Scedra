import SwiftUI

/// Collapsed title + optional subtitle. Lives in the page scroll —
/// never sticky, never a nested scroll of its own.
struct CollapsibleNoticeCard<Detail: View>: View {
    let headline: String
    var subtitle: String? = nil
    let accent: Color
    @ViewBuilder var detail: () -> Detail
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 10 : 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headline)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(accent)
                            .fixedSize(horizontal: false, vertical: true)
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(accent)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityTitle)
            .accessibilityHint(isExpanded ? ScedraString("Collapse") : ScedraString("Show details"))
            .accessibilityValue(isExpanded ? ScedraString("Expanded") : ScedraString("Collapsed"))

            if isExpanded {
                detail()
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(accent)
                .frame(width: 4)
        }
        .scedraCard()
    }

    private var accessibilityTitle: String {
        let extra = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if extra.isEmpty { return headline }
        return "\(headline), \(extra)"
    }
}

/// Shared stay-out / conflict / transit card. Going home is assumed —
/// nothing here moves a calendar event. Collapsed to title + optional subtitle.
struct HomeGapCard: View {
    let suggestion: HomeGapSuggestion

    private var accent: Color {
        suggestion.kind == .cannotBeLived ? ScedraTheme.conflict : ScedraTheme.purple
    }

    var body: some View {
        CollapsibleNoticeCard(
            headline: suggestion.collapsedHeadline,
            subtitle: suggestion.collapsedSubtitle,
            accent: accent
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if suggestion.headline != suggestion.collapsedHeadline,
                   suggestion.collapsedSubtitle == nil {
                    Text(suggestion.headline)
                        .font(.system(size: 20, weight: .regular, design: .serif))
                        .foregroundStyle(ScedraTheme.deepPurple)
                }
                Text(suggestion.detail)
                    .font(.subheadline)
                    .foregroundStyle(ScedraTheme.deepPurple)
                if let nearby = suggestion.nearbyTransitLine {
                    Text(nearby)
                        .font(.caption)
                        .foregroundStyle(ScedraTheme.purple)
                }
                if let transit = suggestion.transitNote {
                    Text(transit)
                        .font(.caption)
                        .foregroundStyle(ScedraTheme.purple)
                }
                if let walking = suggestion.walkingNote {
                    Text(walking)
                        .font(.caption)
                        .foregroundStyle(ScedraTheme.purple)
                }
                if !suggestion.bringItems.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What to bring")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ScedraTheme.purple)
                        ForEach(suggestion.bringItems, id: \.self) { item in
                            Text(item)
                                .font(.subheadline)
                                .foregroundStyle(ScedraTheme.deepPurple)
                        }
                        Text("A guess — change if needed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if suggestion.kind == .cannotBeLived {
                    Text("Won’t move existing events.")
                        .font(.caption)
                        .foregroundStyle(ScedraTheme.purple)
                }
                if let latitude = suggestion.destinationLatitude,
                   let longitude = suggestion.destinationLongitude {
                    NavigateRow(
                        latitude: latitude,
                        longitude: longitude,
                        name: suggestion.secondTitle
                    )
                }
            }
        }
    }
}

/// Driving vs Public transport under a resolved address. Lavender when selected.
struct AppointmentTravelModeToggle: View {
    @Binding var mode: TravelMode

    var body: some View {
        HStack(spacing: 8) {
            chip(.drive)
            chip(.transit)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("How you’ll get there")
    }

    private func chip(_ value: TravelMode) -> some View {
        let selected = TravelMode.appointmentDefault(fromSettings: mode) == value
        return Button {
            mode = value
        } label: {
            Text(value.appointmentTitle)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(selected ? ScedraTheme.lavender : ScedraTheme.blush, in: Capsule())
                .foregroundStyle(selected ? ScedraTheme.deepPurple : ScedraTheme.purple)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value.appointmentTitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Apple Maps directions, with optional Google / Waze extras.
struct NavigateRow: View {
    var latitude: Double
    var longitude: Double
    var name: String
    var leaveNow: Bool = false
    var mode: TravelMode? = nil
    @AppStorage(UserProfile.travelModeKey) private var travelModeRaw = TravelMode.drive.rawValue

    private var travelMode: TravelMode {
        mode ?? TravelMode(rawValue: travelModeRaw) ?? .drive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                MapsHandoff.openAppleMaps(
                    latitude: latitude,
                    longitude: longitude,
                    name: name,
                    mode: travelMode
                )
            } label: {
                Label(leaveNow ? "Leave now" : "Navigate", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(ScedraTheme.lavender, in: Capsule())
                    .foregroundStyle(ScedraTheme.deepPurple)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(leaveNow ? "Leave now" : "Navigate")

            HStack(spacing: 8) {
                extraButton("Google") {
                    MapsHandoff.openGoogleMaps(
                        latitude: latitude,
                        longitude: longitude,
                        mode: travelMode
                    )
                }
                if travelMode != .transit {
                    extraButton("Waze") {
                        MapsHandoff.openWaze(latitude: latitude, longitude: longitude)
                    }
                }
            }
        }
    }

    private func extraButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(ScedraTheme.blush, in: Capsule())
                .foregroundStyle(ScedraTheme.purple)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Navigate with \(title)")
    }
}

/// Loads live home-gap suggestions for a day’s stops.
struct HomeGapSection: View {
    let stops: [HomeGapStop]
    var involving: Set<String> = []
    /// Overlap conflicts already on screen — don’t add a second conflict card.
    var hidesLivedConflicts: Bool = false

    @AppStorage(UserProfile.homeGapKey) private var homeGap = UserProfile.defaultHomeGapMinutes
    @AppStorage(UserProfile.workOutKey) private var minHomeMinutes = UserProfile.defaultMinimumHomeMinutes
    @AppStorage(UserProfile.standingBringKey) private var standingBring = ""
    @AppStorage(UserProfile.walkMinutesKey) private var walkMinutes = 15
    @AppStorage(UserProfile.travelModeKey) private var travelModeRaw = TravelMode.drive.rawValue
    @State private var suggestions: [HomeGapSuggestion] = []
    @State private var loading = false
    @State private var resolver = PlaceResolver()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if loading, suggestions.isEmpty, hasPairs {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(ScedraTheme.purple)
                    Text("Checking the gap…")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ScedraTheme.purple)
                }
            }
            ForEach(visibleSuggestions) { suggestion in
                HomeGapCard(suggestion: suggestion)
            }
        }
        .task(id: signature) {
            await refresh()
        }
    }

    private var hasPairs: Bool {
        !HomeGapLogic.consecutivePairs(from: stops).isEmpty
    }

    private var visibleSuggestions: [HomeGapSuggestion] {
        // Going home is assumed — never pin a “you can go home” card.
        let surfaced = suggestions.filter { $0.kind != .goHome }
        if hidesLivedConflicts {
            return surfaced.filter { $0.kind != .cannotBeLived }
        }
        return surfaced
    }

    private var signature: String {
        stops.map {
            "\($0.id)-\($0.officialStart.timeIntervalSince1970)-\($0.officialEnd.timeIntervalSince1970)-\($0.extraBeforeMinutes)-\($0.extraAfterMinutes)-\($0.latitude ?? 0)-\($0.longitude ?? 0)"
        }
        .joined(separator: "|")
        + "-\(homeGap)-\(minHomeMinutes)-\(standingBring)-\(walkMinutes)-\(travelModeRaw)-\(involving.sorted().joined())"
    }

    private func refresh() async {
        let pairs = HomeGapLogic.consecutivePairs(from: stops)
        let relevant = pairs.filter { first, second in
            involving.isEmpty || involving.contains(first.id) || involving.contains(second.id)
        }
        guard !relevant.isEmpty else {
            suggestions = []
            loading = false
            return
        }
        loading = true
        let home = await resolver.geocodedHomeLocation()
        let resolved = await resolveMissingPins(stops)
        let next = await HomeGapRouter.suggestions(
            stops: resolved,
            home: home,
            leavingHomeBuffer: homeGap,
            walkMinutes: walkMinutes,
            preferTransit: travelModeRaw == TravelMode.transit.rawValue,
            minHomeMinutes: minHomeMinutes,
            standingBring: UserProfile.standingItems(from: standingBring),
            involving: involving
        )
        guard !Task.isCancelled else { return }
        suggestions = next
        loading = false
    }

    /// Memory first, then a place search. Never invents a pin.
    private func resolveMissingPins(_ stops: [HomeGapStop]) async -> [HomeGapStop] {
        var seen: [String: HomeGapStop] = [:]
        var ordered: [HomeGapStop] = []
        for stop in stops {
            if seen[stop.id] != nil { continue }
            var next = HomeGapLogic.enrichFromMemory(stop)
            if HomeGapLogic.pin(for: next, home: nil) == nil,
               !next.usesHome {
                let query = next.place.trimmingCharacters(in: .whitespacesAndNewlines)
                if !query.isEmpty, let place = await resolver.resolve(query) {
                    next.latitude = place.latitude
                    next.longitude = place.longitude
                }
            }
            seen[next.id] = next
            ordered.append(next)
        }
        return ordered
    }
}
