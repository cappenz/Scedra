import SwiftUI

struct SettingsView: View {
    @AppStorage(UserProfile.nameKey) private var name = ""
    @AppStorage("scedra.homeAddress") private var homeAddress = ""
    @AppStorage(UserProfile.homeGapKey) private var homeGap = UserProfile.defaultHomeGapMinutes
    @AppStorage(UserProfile.workOutKey) private var minHomeMinutes = UserProfile.defaultMinimumHomeMinutes
    @AppStorage(UserProfile.standingBringKey) private var standingBring = ""
    @AppStorage(UserProfile.travelModeKey) private var travelModeRaw = TravelMode.drive.rawValue
    @AppStorage(UserProfile.walkMinutesKey) private var walkMinutes = 15
    @AppStorage(ScedraThemeStore.key) private var themeID = ScedraThemeID.lavender.rawValue
    @State private var details = ProfileDetailsStore.load()
    @FocusState private var focusedField: SettingsField?
    @Environment(\.dismiss) private var dismiss

    private enum SettingsField: Hashable {
        case name, standingBring, home, notes
        case placeLabel(UUID)
        case placeAddress(UUID)
    }

    private var travelMode: Binding<TravelMode> {
        Binding(
            get: { TravelMode(rawValue: travelModeRaw) ?? .drive },
            set: { travelModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScedraTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        profileCard
                        moveCard
                        betweenStopsCard
                        homeCard
                        detailsCard
                    }
                    .padding(20)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .scedraDismissesKeyboard($focusedField)
            .scedraUsesSelectedTheme()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(alignment: .center) {
                    Text("Settings")
                        .font(.system(size: 30, weight: .regular, design: .serif))
                        .foregroundStyle(ScedraTheme.purple)
                    Spacer()
                    Button("Done") { dismiss() }
                        .font(.body.weight(.medium))
                        .foregroundStyle(ScedraTheme.purple)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .background(ScedraTheme.background.ignoresSafeArea(edges: .top))
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                        ScedraKeyboard.resign()
                    }
                }
            }
        }
        .preferredColorScheme(selectedTheme.preferredColorScheme)
    }

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mini profile")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ScedraTheme.deepPurple)
            TextField("Your name", text: $name)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .name)
                .submitLabel(.done)
                .onSubmit { focusedField = nil }
                .padding(12)
                .background(ScedraTheme.blush, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text("For the greeting. Blank is just “Hi”.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            themeRow
        }
        .scedraCard()
    }

    private var selectedTheme: ScedraThemeID {
        ScedraThemeID(rawValue: themeID) ?? .lavender
    }

    private var themeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Look")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ScedraTheme.deepPurple)
            HStack(spacing: 8) {
                ForEach(ScedraThemeID.allCases) { id in
                    let palette = ScedraTheme.palette(for: id)
                    let selected = selectedTheme == id
                    Button {
                        themeID = id.rawValue
                    } label: {
                        VStack(spacing: 5) {
                            Circle()
                                .fill(palette.swatch)
                                .frame(width: 22, height: 22)
                                .overlay {
                                    Circle()
                                        .strokeBorder(selected ? palette.deepPurple : .clear, lineWidth: 2)
                                        .padding(-3)
                                }
                            Text(id.title)
                                .font(.caption2.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? ScedraTheme.deepPurple : .secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(id.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private var moveCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How I move")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ScedraTheme.deepPurple)

            Picker("Travel", selection: travelMode) {
                ForEach(TravelMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .tint(ScedraTheme.purple)

            labeledStepper("I’ll walk up to", value: $walkMinutes, suffix: .minutes)

            Text("Walk is a mention only. Events never move.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .scedraCard()
    }

    private var betweenStopsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Between stops")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ScedraTheme.deepPurple)

            labeledStepper("Leaving home", value: $homeGap, suffix: .minutesExtra)
            Text("To get out the door after a home stop.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            labeledStepper("If I only have", value: $minHomeMinutes, suffix: .minutesAtHome)
            Text("Shorter than this at home? Stay out.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("Remind me to bring")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ScedraTheme.deepPurple)
            TextField("charger, helmet…", text: $standingBring, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3...6)
                .focused($focusedField, equals: .standingBring)
                .padding(12)
                .background(ScedraTheme.blush, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text("One per line or commas. Always on stay-out and transit.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .scedraCard()
    }

    private var homeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Home address")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ScedraTheme.deepPurple)
            TextField("123 Main Street", text: $homeAddress)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .home)
                .submitLabel(.done)
                .onSubmit { focusedField = nil }
                .padding(12)
                .background(ScedraTheme.blush, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text("Review drive times start here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .scedraCard()
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("More details")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ScedraTheme.deepPurple)
            Text("Work, school, extra homes. Saying “work” uses this address.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextField("Notes — hours, parking…", text: $details.notes, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3...8)
                .focused($focusedField, equals: .notes)
                .padding(12)
                .background(ScedraTheme.blush, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onChange(of: details) { _, new in
                    ProfileDetailsStore.save(new)
                }

            ForEach($details.places) { $place in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Work, school…", text: $place.label)
                            .textFieldStyle(.plain)
                            .focused($focusedField, equals: .placeLabel(place.id))
                            .submitLabel(.done)
                            .onSubmit { focusedField = nil }
                        Button(role: .destructive) {
                            details.places.removeAll { $0.id == place.id }
                            ProfileDetailsStore.save(details)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(ScedraTheme.purple)
                        }
                        .accessibilityLabel("Remove this address")
                    }
                    TextField("Address", text: $place.address)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .placeAddress(place.id))
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                }
                .padding(12)
                .background(ScedraTheme.blush, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onChange(of: place) { _, _ in
                    ProfileDetailsStore.save(details)
                }
            }

            Button {
                details.places.append(ProfilePlace(label: "", address: ""))
                ProfileDetailsStore.save(details)
            } label: {
                Label("Add an address", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ScedraTheme.purple)
            }
            .buttonStyle(.plain)
        }
        .scedraCard()
    }

    private enum StepperSuffix {
        case minutes
        case minutesExtra
        case minutesAtHome

        func label(_ value: Int) -> String {
            switch self {
            case .minutes: ScedraString("\(value) min")
            case .minutesExtra: ScedraString("\(value) min extra")
            case .minutesAtHome: ScedraString("\(value) min at home")
            }
        }
    }

    private func labeledStepper(_ title: LocalizedStringKey, value: Binding<Int>, suffix: StepperSuffix) -> some View {
        Stepper(value: value, in: 0...90, step: 5) {
            HStack {
                Text(title)
                    .foregroundStyle(ScedraTheme.deepPurple)
                Spacer()
                Text(suffix.label(value.wrappedValue))
                    .foregroundStyle(ScedraTheme.purple)
            }
            .font(.subheadline.weight(.medium))
        }
    }
}
