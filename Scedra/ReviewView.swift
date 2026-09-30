import AVFoundation
import CoreLocation
import SwiftUI
import UIKit

@Observable
final class Speaker {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.47
        synthesizer.speak(utterance)
    }
}

enum TravelState: Equatable {
    case idle
    case estimating
    case ready(TravelEstimate)
    /// Shown as plain text so the screen never hides a failure behind blank space.
    case unavailable(String)
}

struct ReviewView: View {
    @Binding var drafts: [DraftEvent]
    var calendar: CalendarStore
    var onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(UserProfile.homeGapKey) private var homeGap = UserProfile.defaultHomeGapMinutes
    @State private var index = 0
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var showOriginal = false
    @State private var speaker = Speaker()
    @State private var placeResolver = PlaceResolver()
    @State private var isResolvingLocation = false
    @State private var locationNote: String?
    @State private var resolveTask: Task<Void, Never>?
    @State private var conflicts: [CalendarConflict] = []
    @State private var travel: TravelState = .idle
    @State private var travelTask: Task<Void, Never>?
    @State private var nearbyTransitLine: String?
    @FocusState private var focusedField: ReviewField?
    @State private var startText = ""
    @State private var endText = ""
    @State private var extraBeforeText = "0"
    @State private var extraAfterText = "0"
    @State private var didApplyDefaultTravelMode: Set<UUID> = []

    private enum ReviewField: Hashable {
        case title, start, end, extraBefore, extraAfter, location
    }

    var body: some View {
        ZStack {
            ScedraTheme.background.ignoresSafeArea(edges: .top)

            if drafts.indices.contains(index) {
                // Draft first, then one-line notice cards in this same scroll —
                // not a modal, not sticky, and Confirm stays in the footer.
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 16) {
                        if drafts.count > 1 {
                            Text("\(index + 1) of \(drafts.count)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(ScedraTheme.purple)
                        }

                        reviewCard
                        conflictCard
                        homeGapCard
                        extraTimeRow
                        actionRow
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDisabled(false)
                .scrollDismissesKeyboard(.immediately)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .scedraDismissesKeyboard($focusedField)
        .scedraUsesSelectedTheme()
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.automatic, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            confirmFooter
        }
        .sheet(isPresented: $showOriginal) {
            originalSheet
        }
        .onAppear {
            syncTypedFields(force: true)
        }
        .onChange(of: focusedField) { oldValue, _ in
            _ = commitField(oldValue)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    dismissKeyboard()
                }
            }
        }
        .task(id: index) {
            syncTypedFields(force: true)
            applyDefaultTravelModeIfNeeded()
            locationNote = nil
            resolveTask?.cancel()
            travelTask?.cancel()
            travel = showsDriveSection ? .estimating : .idle
            let task = Task {
                await resolveCurrentPlace()
            }
            resolveTask = task
            await task.value
            refreshConflicts()
            scheduleTravelEstimate()
        }
        .task(id: conflictSignature) {
            refreshConflicts()
            scheduleTravelEstimate()
        }
        .onDisappear {
            resolveTask?.cancel()
            travelTask?.cancel()
        }
    }

    @ViewBuilder
    private var locationResolutionRow: some View {
        if isResolvingLocation {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(ScedraTheme.purple)
                Text(findingPlaceLabel)
            }
            .font(.caption)
            .foregroundStyle(ScedraTheme.purple)
        } else if let resolved = current.resolvedLocation, !resolved.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(resolved)
                    .font(.body.weight(.medium))
                    .foregroundStyle(ScedraTheme.deepPurple)
                Text(current.resolvedCaption ?? ScedraString("Nearby match"))
                    .font(.caption)
                    .foregroundStyle(ScedraTheme.purple)
            }
        } else if let locationNote {
            Text(locationNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Always visible when there is a place and a start — loading, result, or an honest failure.
    @ViewBuilder
    private var travelRow: some View {
        if showsDriveSection {
            switch travel {
            case .idle, .estimating:
                driveStatus(
                    TravelEstimator.loadingMessage(for: current.travelMode),
                    systemImage: nil,
                    spinning: true
                )
            case .ready(let estimate):
                VStack(alignment: .leading, spacing: 2) {
                    Label(
                        TravelEstimator.line(for: estimate),
                        systemImage: travelIcon(estimate.fellBackToDriving ? .drive : estimate.mode)
                    )
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ScedraTheme.purple)
                    if let note = TravelEstimator.note(for: estimate) {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            case .unavailable(let reason):
                driveStatus(
                    reason,
                    systemImage: current.travelMode == .transit ? "tram" : "car",
                    spinning: false
                )
            }
            if let nearbyTransitLine {
                Text(nearbyTransitLine)
                    .font(.caption)
                    .foregroundStyle(ScedraTheme.purple)
            }
        }
    }

    private var showsDriveSection: Bool {
        guard drafts.indices.contains(index) else { return false }
        return TravelEstimator.shouldEstimate(for: drafts[index])
    }

    @ViewBuilder
    private func driveStatus(_ text: String, systemImage: String?, spinning: Bool) -> some View {
        HStack(spacing: 8) {
            if spinning {
                ProgressView()
                    .tint(ScedraTheme.purple)
            } else if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(spinning ? ScedraTheme.purple : .secondary)
    }

    /// Sticky Confirm + error, kept above the home indicator (tab bar is hidden on Review).
    private var confirmFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: confirm) {
                Group {
                    if isSaving {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Confirm")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .background(ScedraTheme.purple, in: Capsule())
            .foregroundStyle(.white)
            .buttonStyle(.plain)
            .disabled(isSaving)
            .accessibilityLabel("Confirm")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background {
            ScedraTheme.background
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func travelIcon(_ mode: TravelMode) -> String {
        switch mode {
        case .drive: "car.fill"
        case .transit: "tram.fill"
        case .walk: "figure.walk"
        }
    }

    private var current: DraftEvent {
        drafts[index]
    }

    private var conflictSignature: String {
        guard drafts.indices.contains(index) else { return "" }
        let draft = drafts[index]
        return "\(index)-\(draft.start.timeIntervalSince1970)-\(draft.end.timeIntervalSince1970)-\(draft.arrivalTarget.timeIntervalSince1970)-\(draft.extraBeforeMinutes)-\(draft.extraAfterMinutes)-\(draft.locationToSave)-\(draft.locationLatitude ?? 0)-\(draft.locationLongitude ?? 0)-\(draft.travelMode.rawValue)"
    }

    private var findingPlaceLabel: String {
        let query = current.location.trimmingCharacters(in: .whitespacesAndNewlines)
        if PlaceResolver.placeAreaSplits(from: query).isEmpty {
            return ScedraString("Finding nearby…")
        }
        return ScedraString("Finding in that area…")
    }

    private var reviewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Title", text: titleBinding)
                .font(.system(size: 28, weight: .regular, design: .serif))
                .foregroundStyle(ScedraTheme.deepPurple)
                .focused($focusedField, equals: .title)
                .submitLabel(.done)
                .onSubmit { dismissKeyboard() }

            DatePicker("Date", selection: dateBinding, displayedComponents: .date)
                .tint(ScedraTheme.purple)

            HStack(alignment: .top, spacing: 12) {
                typedTimeField("Start", text: $startText, field: .start, prompt: "2:30 PM")
                typedTimeField("End", text: $endText, field: .end, prompt: "3:30 PM")
            }
            if current.durationAssumed {
                Text("Duration assumed")
                    .font(.caption)
                    .foregroundStyle(ScedraTheme.purple)
            }
            if current.hasDisplayedDateAndTime, !current.hasDate || !current.hasTime {
                Text("Date and time filled from now — change if needed.")
                    .font(.caption)
                    .foregroundStyle(ScedraTheme.purple)
            }

            TextField("Location", text: locationBinding, prompt: Text("Location (optional)"))
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .location)
                .submitLabel(.done)
                .onSubmit { dismissKeyboard() }
                .padding(10)
                .background(ScedraTheme.blush, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            locationResolutionRow
            if showsDriveSection {
                AppointmentTravelModeToggle(mode: travelModeBinding)
            }
            travelRow
            navigateRow

            VStack(alignment: .leading, spacing: 2) {
                Text(windowLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                calendarBlockRow
            }
        }
        .scedraCard()
    }

    private var extraTimeRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Extra time")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ScedraTheme.deepPurple)

            extraMinutesField("Before", text: $extraBeforeText, field: .extraBefore)
            extraMinutesField("After", text: $extraAfterText, field: .extraAfter)
        }
        .scedraCard()
    }

    private func typedTimeField(
        _ title: LocalizedStringKey,
        text: Binding<String>,
        field: ReviewField,
        prompt: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ScedraTheme.purple)
            TextField(title, text: text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: field)
                .submitLabel(.done)
                .onSubmit { dismissKeyboard() }
                .padding(10)
                .background(ScedraTheme.blush, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("\(title) time")
        }
    }

    private func extraMinutesField(_ title: LocalizedStringKey, text: Binding<String>, field: ReviewField) -> some View {
        HStack {
            Text(title)
                .font(.body.weight(.medium))
            Spacer()
            TextField("0", text: text)
                .textFieldStyle(.plain)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .focused($focusedField, equals: field)
                .submitLabel(.done)
                .onSubmit { dismissKeyboard() }
                .padding(10)
                .frame(width: 88)
                .background(ScedraTheme.blush, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel(Text("Extra time \(title)"))
            Text("min")
                .font(.caption)
                .foregroundStyle(ScedraTheme.purple)
        }
    }

    @ViewBuilder
    private var homeGapCard: some View {
        HomeGapSection(
            stops: homeGapStops,
            involving: drafts.indices.contains(index) ? [drafts[index].id.uuidString] : [],
            hidesLivedConflicts: !conflicts.isEmpty
        )
    }

    /// Day's timed events plus this draft, so Review can see the stop next door.
    private var homeGapStops: [HomeGapStop] {
        guard drafts.indices.contains(index) else { return [] }
        let draft = drafts[index]
        _ = calendar.today
        _ = calendar.selectedDayEvents
        var stops = calendar.events(on: draft.start)
            .filter { !$0.isAllDay }
            .map { $0.asHomeGapStop() }
        stops.append(draft.asHomeGapStop())
        return stops
    }

    @ViewBuilder
    private var navigateRow: some View {
        if let latitude = current.locationLatitude, let longitude = current.locationLongitude {
            NavigateRow(
                latitude: latitude,
                longitude: longitude,
                name: current.locationToSave.isEmpty ? current.calendarTitle : current.locationToSave,
                leaveNow: isLeaveNow,
                mode: current.travelMode
            )
        }
    }

    private var isLeaveNow: Bool {
        if case .ready(let estimate) = travel {
            return Date() >= estimate.leaveBy
        }
        return false
    }

    /// Inline banner in the same scroll as the draft. Confirm stays in the footer;
    /// the card starts as one line so it cannot eat the page.
    @ViewBuilder
    private var conflictCard: some View {
        if calendar.access == .writeOnly, current.hasDisplayedDateAndTime {
            CollapsibleNoticeCard(headline: ScedraString("Conflict"), accent: ScedraTheme.conflict) {
                Text("Grant full Calendar access to check overlaps. Events won’t move.")
                    .font(.subheadline)
                    .foregroundStyle(ScedraTheme.deepPurple)
            }
            .id("write-only-\(index)")
        } else if !conflicts.isEmpty {
            CollapsibleNoticeCard(headline: ScedraString("Conflict"), accent: ScedraTheme.conflict) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(conflicts) { conflict in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Overlaps \(conflict.title)")
                                .font(.system(size: 20, weight: .regular, design: .serif))
                                .foregroundStyle(ScedraTheme.deepPurple)
                            Text(conflictTime(conflict))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if calendarBlock.isPadded {
                        Text("Includes drive. Appointment is \(TravelEstimator.appointmentWindow(from: current.start, to: current.end)).")
                            .font(.caption)
                            .foregroundStyle(ScedraTheme.deepPurple)
                    }
                    Text("Won’t move that event. Confirm still saves this.")
                        .font(.caption)
                        .foregroundStyle(ScedraTheme.purple)
                }
            }
            .id(conflictSignature)
        }
    }

    @ViewBuilder
    private var originalSheet: some View {
        NavigationStack {
            Group {
                switch ReviewOriginal.presentation(for: current) {
                case .photo(let url):
                    originalPhoto(url)
                case .text(let text):
                    originalText(text)
                }
            }
            .background(ScedraTheme.blush.ignoresSafeArea())
            .navigationTitle("Original")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showOriginal = false }
                }
            }
        }
        .presentationDetents(current.originalImageURL == nil ? [.medium, .large] : [.large])
    }

    private func originalPhoto(_ url: URL) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let image = OriginalImageStore.image(at: url) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityLabel("Original photo")
                }
                if !current.sourceText.isEmpty {
                    DisclosureGroup("Read text") {
                        Text(current.sourceText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                    .foregroundStyle(ScedraTheme.deepPurple)
                }
            }
            .padding(20)
        }
    }

    private func originalText(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                speaker.speak(spokenSummary)
            } label: {
                Label("Hear", systemImage: "speaker.wave.2.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(ScedraTheme.lavender, in: Capsule())
                    .foregroundStyle(ScedraTheme.deepPurple)
            }
            .buttonStyle(.plain)

            Button {
                showOriginal = true
            } label: {
                Label(
                    "View original",
                    systemImage: current.originalImageURL == nil ? "doc.text" : "photo"
                )
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(ScedraTheme.lavender, in: Capsule())
                    .foregroundStyle(ScedraTheme.deepPurple)
            }
            .buttonStyle(.plain)
        }
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { drafts[index].title },
            set: { drafts[index].title = $0 }
        )
    }

    private var travelModeBinding: Binding<TravelMode> {
        Binding(
            get: { drafts[index].travelMode },
            set: { newValue in
                guard drafts.indices.contains(index) else { return }
                drafts[index].travelMode = newValue
                scheduleTravelEstimate()
            }
        )
    }

    private func applyDefaultTravelModeIfNeeded() {
        guard drafts.indices.contains(index) else { return }
        let id = drafts[index].id
        guard didApplyDefaultTravelMode.insert(id).inserted else { return }
        drafts[index].travelMode = TravelMode.appointmentDefault()
    }

    private var locationBinding: Binding<String> {
        Binding(
            get: { drafts[index].location },
            set: { newValue in
                drafts[index].location = newValue
                drafts[index].clearResolvedPlace()
                locationNote = nil
                scheduleResolve()
            }
        )
    }

    private func formatClock(_ date: Date) -> String {
        date.scedraDisplay(date: .omitted, time: .shortened)
    }

    private func syncTypedFields(force: Bool) {
        guard drafts.indices.contains(index) else { return }
        let draft = drafts[index]
        if force || focusedField != .start {
            startText = formatClock(draft.start)
        }
        if force || focusedField != .end {
            endText = formatClock(draft.end)
        }
        if force || focusedField != .extraBefore {
            extraBeforeText = String(draft.extraBeforeMinutes)
        }
        if force || focusedField != .extraAfter {
            extraAfterText = String(draft.extraAfterMinutes)
        }
    }

    private func dismissKeyboard() {
        _ = commitTypedFields()
        focusedField = nil
        ScedraKeyboard.resign()
    }

    /// Applies whatever she typed. Unchanged canonical text is left alone so Confirm
    /// does not have to re-parse a locale-formatted clock.
    @discardableResult
    private func commitTypedFields() -> Bool {
        guard drafts.indices.contains(index) else { return false }
        var ok = true
        var extraChanged = false
        var appliedWindow = false

        let startCanonical = formatClock(drafts[index].start)
        if !ReviewTimeTyping.normalize(startText).isEmpty,
           !ReviewTimeTyping.clocksMatch(startText, formatted: startCanonical) {
            if let parsed = ReviewTimeTyping.parseAppointment(startText) {
                drafts[index].applyTypedAppointment(parsed, asEnd: false)
                if case .window = parsed { appliedWindow = true }
            } else {
                ok = false
            }
        }

        let endCanonical = formatClock(drafts[index].end)
        if !appliedWindow,
           !ReviewTimeTyping.normalize(endText).isEmpty,
           !ReviewTimeTyping.clocksMatch(endText, formatted: endCanonical) {
            if !drafts[index].applyTypedEnd(endText) {
                ok = false
            }
        }

        let beforeWas = drafts[index].extraBeforeMinutes
        if !ReviewTimeTyping.clocksMatch(extraBeforeText, formatted: String(beforeWas)) {
            if drafts[index].applyTypedExtraBefore(extraBeforeText) {
                extraChanged = extraChanged || drafts[index].extraBeforeMinutes != beforeWas
            } else {
                ok = false
            }
        }

        let afterWas = drafts[index].extraAfterMinutes
        if !ReviewTimeTyping.clocksMatch(extraAfterText, formatted: String(afterWas)) {
            if drafts[index].applyTypedExtraAfter(extraAfterText) {
                extraChanged = extraChanged || drafts[index].extraAfterMinutes != afterWas
            } else {
                ok = false
            }
        }

        if extraChanged {
            applyExtraToReadyTravel()
        }
        if ok {
            syncTypedFields(force: false)
        }
        return ok
    }

    @discardableResult
    private func commitField(_ field: ReviewField?) -> Bool {
        guard let field, drafts.indices.contains(index) else { return true }
        switch field {
        case .title, .location:
            return true
        case .start:
            if ReviewTimeTyping.normalize(startText).isEmpty
                || ReviewTimeTyping.clocksMatch(startText, formatted: formatClock(drafts[index].start)) {
                return true
            }
            guard drafts[index].applyTypedStart(startText) else { return false }
        case .end:
            if ReviewTimeTyping.normalize(endText).isEmpty
                || ReviewTimeTyping.clocksMatch(endText, formatted: formatClock(drafts[index].end)) {
                return true
            }
            guard drafts[index].applyTypedEnd(endText) else { return false }
        case .extraBefore:
            let was = drafts[index].extraBeforeMinutes
            if ReviewTimeTyping.clocksMatch(extraBeforeText, formatted: String(was)) {
                return true
            }
            guard drafts[index].applyTypedExtraBefore(extraBeforeText) else { return false }
            if drafts[index].extraBeforeMinutes != was {
                applyExtraToReadyTravel()
            }
        case .extraAfter:
            let was = drafts[index].extraAfterMinutes
            if ReviewTimeTyping.clocksMatch(extraAfterText, formatted: String(was)) {
                return true
            }
            guard drafts[index].applyTypedExtraAfter(extraAfterText) else { return false }
            if drafts[index].extraAfterMinutes != was {
                applyExtraToReadyTravel()
            }
        }
        syncTypedFields(force: false)
        return true
    }

    /// Extra time is not Maps time — reuse the last route and only refresh leave-by / padding.
    private func applyExtraToReadyTravel() {
        if case .ready(let estimate) = travel, drafts.indices.contains(index) {
            let draft = drafts[index]
            travel = .ready(
                TravelEstimator.estimate(
                    minutes: estimate.minutes,
                    mode: estimate.mode,
                    start: draft.arrivalTarget,
                    bufferMinutes: estimate.bufferMinutes,
                    fellBackToDriving: estimate.fellBackToDriving,
                    returnMinutes: estimate.returnMinutes,
                    fromHome: estimate.fromHome,
                    extraBeforeMinutes: draft.extraBeforeMinutes,
                    extraAfterMinutes: draft.extraAfterMinutes
                )
            )
        }
        refreshConflicts()
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { drafts[index].start },
            set: { newValue in
                let calendar = Calendar.current
                let time = calendar.dateComponents([.hour, .minute], from: drafts[index].start)
                let updated = calendar.date(
                    bySettingHour: time.hour ?? 0,
                    minute: time.minute ?? 0,
                    second: 0,
                    of: newValue
                ) ?? newValue
                if let arrive = drafts[index].arriveBy {
                    let lead = drafts[index].start.timeIntervalSince(arrive)
                    drafts[index].arriveBy = updated.addingTimeInterval(-lead)
                }
                drafts[index].start = updated
                drafts[index].hasDate = true
            }
        )
    }

    private var durationLabel: String {
        extraMinutesLabel(current.durationMinutes)
    }

    private func extraMinutesLabel(_ minutes: Int) -> String {
        if minutes % 60 == 0 {
            let hours = minutes / 60
            if hours == 0 { return ScedraString("0 min") }
            return hours == 1 ? ScedraString("1 hr") : ScedraString("\(hours) hr")
        }
        if minutes > 60 {
            return ScedraString("\(minutes / 60) hr \(minutes % 60) min")
        }
        return ScedraString("\(minutes) min")
    }

    private var windowLabel: String {
        let start = current.start.scedraDisplay(date: .abbreviated, time: .shortened)
        let end = current.end.scedraDisplay(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    /// The estimate Confirm will actually write. Nil while it is still being worked out —
    /// Confirm never waits for it.
    private var readyTravel: TravelEstimate? {
        if case .ready(let estimate) = travel { return estimate }
        return nil
    }

    /// What goes on the calendar: the appointment plus the drive and extra time.
    private var calendarBlock: TravelEstimator.CalendarBlock {
        TravelEstimator.calendarBlock(
            start: current.arrivalTarget,
            end: current.end,
            travel: readyTravel,
            extraBeforeMinutes: current.extraBeforeMinutes,
            extraAfterMinutes: current.extraAfterMinutes
        )
    }

    @ViewBuilder
    private var calendarBlockRow: some View {
        if let label = TravelEstimator.blockLabel(for: calendarBlock, mode: current.travelMode) {
            Text(label)
                .font(.caption)
                .foregroundStyle(ScedraTheme.purple)
        }
    }

    private var spokenSummary: String {
        var parts = [current.calendarTitle]
        if current.hasDisplayedDateAndTime {
            parts.append(current.start.scedraDisplay(date: .complete, time: .omitted))
            parts.append(ScedraString("at \(current.start.scedraDisplay(date: .omitted, time: .shortened))"))
        }
        parts.append(ScedraString("for \(durationLabel)"))
        if current.durationAssumed {
            parts.append(ScedraString("Duration assumed"))
        }
        let place = current.locationToSave
        if !place.isEmpty {
            parts.append(ScedraString("at \(place)"))
        }
        if current.extraBeforeMinutes > 0 {
            parts.append(ScedraString("arrive \(extraMinutesLabel(current.extraBeforeMinutes)) early"))
        }
        if current.extraAfterMinutes > 0 {
            parts.append(ScedraString("stay \(extraMinutesLabel(current.extraAfterMinutes)) after"))
        }
        return parts.joined(separator: ", ")
    }

    private func scheduleResolve() {
        travelTask?.cancel()
        resolveTask?.cancel()
        travel = showsDriveSection ? .estimating : .idle
        resolveTask = Task {
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            await resolveCurrentPlace()
            scheduleTravelEstimate()
        }
    }

    /// Fire-and-forget: the estimate is never awaited by Confirm.
    /// Drive time still has to *show* — loading or an honest failure, never a blank.
    private func scheduleTravelEstimate() {
        travelTask?.cancel()
        guard drafts.indices.contains(index) else { return }
        let draft = drafts[index]
        nearbyTransitLine = nil
        guard TravelEstimator.shouldEstimate(for: draft) else {
            travel = .idle
            return
        }
        guard let latitude = draft.locationLatitude, let longitude = draft.locationLongitude else {
            // Keep the loading line until lookup finishes — don't flash "couldn't pin"
            // while MapKit is still working, or if this task raced ahead of resolve.
            let lookupStillOpen = isResolvingLocation
                || (draft.resolvedLocation == nil
                    && locationNote == nil
                    && !PlaceResolver.isSpecificAddress(draft.location))
            travel = lookupStillOpen
                ? .estimating
                : .unavailable(TravelEstimator.noPinMessage)
            return
        }
        let buffer = homeGap
        let start = draft.arrivalTarget
        let end = draft.end
        let extraBefore = draft.extraBeforeMinutes
        let extraAfter = draft.extraAfterMinutes
        let mode = draft.travelMode
        travel = .estimating
        travelTask = Task {
            let pin = await placeResolver.resolvedTravelOrigin()
            guard !Task.isCancelled else { return }
            guard let pin else {
                travel = .unavailable(TravelEstimator.noOriginMessage)
                return
            }
            let estimate = await TravelEstimator.roundTripEstimate(
                from: pin.location,
                toLatitude: latitude,
                longitude: longitude,
                mode: mode,
                start: start,
                end: end,
                bufferMinutes: buffer,
                fromHome: pin.fromHome,
                extraBeforeMinutes: extraBefore,
                extraAfterMinutes: extraAfter
            )
            guard !Task.isCancelled else { return }
            travel = estimate.map(TravelState.ready) ?? .unavailable(TravelEstimator.noRouteMessage(for: mode))
            if let stop = await NearbyTransit.nearest(
                to: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                excluding: pin.location.coordinate
            ) {
                nearbyTransitLine = stop.line
            }
            // The block just grew by the drive, so overlaps have to be rechecked.
            refreshConflicts()
        }
    }

    private func resolveCurrentPlace() async {
        guard drafts.indices.contains(index) else { return }
        let query = drafts[index].location.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = drafts[index].title

        if drafts[index].resolvedLocation?.isEmpty == false {
            isResolvingLocation = false
            locationNote = nil
            return
        }

        var savedQueries = [query, title]
        if !query.isEmpty, !title.isEmpty { savedQueries.append("\(title) \(query)") }
        for candidate in savedQueries where !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let saved = await placeResolver.resolvedSavedPlace(matching: candidate) {
                guard !Task.isCancelled, drafts.indices.contains(index) else { return }
                drafts[index].applyResolvedPlace(saved)
                if drafts[index].location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    drafts[index].location = saved.displayLine
                }
                locationNote = nil
                isResolvingLocation = false
                return
            }
        }

        if PlaceMemory.shouldPreferMemory(title: title, locationQuery: query),
           let remembered = PlaceMemory.remembered(forTitle: title) {
            drafts[index].applyRememberedPlace(remembered)
            locationNote = nil
            isResolvingLocation = false
            return
        }

        guard !query.isEmpty else {
            drafts[index].clearResolvedPlace()
            locationNote = nil
            isResolvingLocation = false
            return
        }
        if PlaceResolver.isSpecificAddress(query) {
            isResolvingLocation = false
            locationNote = nil
            return
        }

        isResolvingLocation = true
        locationNote = nil
        let place = await placeResolver.resolve(query)
        guard !Task.isCancelled, drafts.indices.contains(index) else { return }
        isResolvingLocation = false

        if let place {
            drafts[index].applyResolvedPlace(place)
            locationNote = nil
        } else {
            drafts[index].clearResolvedPlace()
            locationNote = PlaceResolver.placeAreaSplits(from: query).isEmpty
                ? ScedraString("No nearby match — saving as entered")
                : ScedraString("No match in that area — saving as entered")
        }
    }

    /// Checked against the travel-inclusive block — that is the honest answer to
    /// "can this day be lived" — while the card still quotes the real appointment times.
    private func refreshConflicts() {
        guard drafts.indices.contains(index), drafts[index].hasDisplayedDateAndTime else {
            conflicts = []
            return
        }
        let block = calendarBlock
        conflicts = calendar.conflicts(overlapping: block.start, end: block.end)
    }

    private func conflictTime(_ conflict: CalendarConflict) -> String {
        let start = conflict.start.scedraDisplay(date: .omitted, time: .shortened)
        let end = conflict.end.scedraDisplay(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    private func confirm() {
        guard drafts.indices.contains(index) else { return }
        dismissKeyboard()
        if !commitTypedFields() {
            // Locale-formatted clocks (narrow spaces, "10 h 16") must not block
            // Confirm when the card is already showing a start–end window.
            if drafts[index].hasDisplayedDateAndTime {
                syncTypedFields(force: true)
            } else {
                errorMessage = ScedraString("Couldn’t read what you typed.")
                return
            }
        }
        // The card already shows a start–end clock window. That is the date and time.
        guard let ready = CalendarSaveGate.readyToSave(drafts[index]) else {
            errorMessage = CalendarStoreError.missingDateOrTime.errorDescription
            return
        }
        drafts[index] = ready

        isSaving = true
        errorMessage = nil
        // Do not wait for MapKit. A hung place lookup used to leave Confirm
        // spinning and never reach EventKit.
        Task { @MainActor in
            guard drafts.indices.contains(index) else {
                isSaving = false
                return
            }
            drafts[index].acceptDisplayedDateAndTime()
            do {
                // Whatever estimate is in hand right now. Nil means the event saves at
                // exactly the stated time rather than making her wait for a drive time.
                try await calendar.save(drafts[index], travel: readyTravel)
                if index + 1 < drafts.count {
                    index += 1
                } else {
                    onFinished()
                    dismiss()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}
