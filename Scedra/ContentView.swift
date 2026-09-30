import Photos
import PhotosUI
import SwiftUI
import UIKit

/// After Confirm writes a real EventKit event, empty the Capture box so the
/// next appointment can be spoken, photographed, or typed. Failed saves leave
/// the text alone.
nonisolated enum CaptureComposerPolicy {
    struct State: Equatable {
        var sourceText: String
        var transcript: String
        var fallbackMessage: String?
    }

    static func afterSuccessfulSave(_ state: State) -> State {
        State(sourceText: "", transcript: "", fallbackMessage: nil)
    }
}

enum CaptureMode: String, CaseIterable, Identifiable {
    case voice
    case photo
    case type

    var id: String { rawValue }

    var title: String {
        switch self {
        case .voice: ScedraString("Voice")
        case .photo: ScedraString("Photo")
        case .type: ScedraString("Type mode")
        }
    }

    var icon: String {
        switch self {
        case .voice: "waveform"
        case .photo: "camera"
        case .type: "text.alignleft"
        }
    }
}

struct RootView: View {
    @State private var calendar = CalendarStore()
    @State private var tasks = TaskRepository()
    @AppStorage(ScedraThemeStore.key) private var themeID = ScedraThemeID.lavender.rawValue

    var body: some View {
        TabView {
            ContentView(calendar: calendar)
                .tabItem {
                    Label("Capture", systemImage: "waveform")
                }
            CalendarTabView(calendar: calendar)
                .tabItem {
                    Label("Calendar", systemImage: "calendar")
                }
            TasksTabView(calendar: calendar, tasks: tasks)
                .tabItem {
                    Label("Tasks", systemImage: "checkmark.circle")
                }
        }
        .tint(ScedraTheme.palette(for: ScedraThemeID(rawValue: themeID) ?? .lavender).purple)
        // Phone language for chrome; Midnight dark is only the color scheme.
        .environment(\.locale, Locale.autoupdatingCurrent)
        .preferredColorScheme((ScedraThemeID(rawValue: themeID) ?? .lavender).preferredColorScheme)
        .task {
            await calendar.requestAccessAndLoad()
            await HomeGapNotifier.requestAuthorization()
            await LeaveToNavigateNotifier.requestAuthorization()
        }
    }
}

struct ContentView: View {
    var calendar: CalendarStore

    @AppStorage(UserProfile.nameKey) private var profileName = ""
    @State private var speech = SpeechCapture()
    @State private var mode: CaptureMode = .voice
    @State private var sourceText = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var photoImage: UIImage?
    @State private var isReadingPhoto = false
    @State private var showPhotoPicker = false
    @State private var photoReadTask: Task<Void, Never>?
    @State private var photoReadGeneration = 0
    @State private var drafts: [DraftEvent] = []
    @State private var showReview = false
    @State private var showSettings = false
    @State private var captureError: String?
    @State private var savedBanner: String?
    @State private var pendingDelete: TodayItem?
    @State private var selectedAppointment: SelectedAppointment?
    /// Shown under the Today list, not in the capture card: a failed delete has to
    /// appear where she tapped, or it reads as "I tapped delete and nothing happened".
    @State private var deleteError: String?
    /// Recreates the Capture text field after a successful save so SwiftUI
    /// cannot keep showing the old string after the binding is emptied.
    @State private var composerFieldID = 0
    /// Set only after EventKit Confirm succeeds. Swipe-back / failed save leave text.
    @State private var shouldClearComposerAfterReview = false

    private var greeting: String {
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? ScedraString("Hi") : ScedraString("Hi, \(name)")
    }

    private var settingsGreetingLabel: String {
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty
            ? ScedraString("Settings")
            : ScedraString("Hi, \(name). Settings")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScedraTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Button {
                            showSettings = true
                        } label: {
                            Text(greeting)
                                .font(.system(size: 34, weight: .regular, design: .serif))
                                .foregroundStyle(ScedraTheme.deepPurple)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(settingsGreetingLabel)
                        captureCard
                        todaySection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                ScedraScreenHeader(title: "Scedra") {
                    showSettings = true
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 6)
                .background(ScedraTheme.background.ignoresSafeArea(edges: .top))
            }
            .scedraUsesSelectedTheme()
            .navigationDestination(isPresented: $showReview) {
                ReviewView(drafts: $drafts, calendar: calendar) {
                    savedBanner = ScedraString("Saved to Calendar")
                    calendar.loadToday()
                    calendar.loadSelectedDay()
                    shouldClearComposerAfterReview = true
                }
            }
            // Hide the system bar so iOS 26 cannot draw a corner ⋯. Settings
            // is the in-page gear (and the Hi greeting), not a toolbar menu.
            .toolbar(.hidden, for: .navigationBar)
            // Review's Confirm lives at the bottom. Hide the tab bar so Capture /
            // Calendar cannot steal those taps, then bring it back when she leaves.
            .toolbar(showReview ? .hidden : .automatic, for: .tabBar)
            .sheet(isPresented: $showSettings, onDismiss: {
                calendar.refreshHomeGapNotifications()
            }) {
                SettingsView()
            }
            .sheet(item: $selectedAppointment) { selected in
                EventDetailsSheet(
                    item: selected.item,
                    dayItems: calendar.today,
                    calendar: calendar
                ) { item in
                    selectedAppointment = nil
                    delete(item)
                }
            }
            .scedraDeleteConfirmation(item: $pendingDelete, onConfirm: delete)
            .onChange(of: showReview) { _, presented in
                if !presented {
                    calendar.loadToday()
                    if shouldClearComposerAfterReview {
                        shouldClearComposerAfterReview = false
                        clearComposerAfterSuccessfulSave()
                    }
                }
            }
            .onAppear {
                if calendar.access == .full || calendar.access == .writeOnly {
                    calendar.loadToday()
                }
            }
            .onChange(of: speech.transcript) { _, newValue in
                if mode == .voice, !newValue.isEmpty {
                    sourceText = SpeechTranscriptStitch.preferringLonger(sourceText, newValue)
                }
            }
            // Do not cancel here. NavigationStack / TabView fire onDisappear
            // when pushing Review, opening a sheet, or switching tabs — that
            // was hanging up the mic mid-sentence. Stop is the only hang-up.
        }
    }

    private var captureCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            modePicker

            switch mode {
            case .voice:
                voiceBody
            case .photo:
                photoBody
            case .type:
                typeBody
            }

            if let captureError {
                Text(captureError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if let savedBanner {
                Text(savedBanner)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(ScedraTheme.purple)
            }

            Button(action: reviewTapped) {
                Text("Review")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(ScedraTheme.purple, in: Capsule())
                    .foregroundStyle(.white)
            }
            .disabled(sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isReadingPhoto)
        }
        .scedraCard()
    }

    private var modePicker: some View {
        HStack(spacing: 6) {
            ForEach(CaptureMode.allCases) { item in
                Button {
                    if item != .voice, speech.isListening {
                        speech.cancel()
                    }
                    if item != .photo {
                        abandonInFlightPhotoRead()
                    }
                    mode = item
                    captureError = nil
                } label: {
                    Label(item.title, systemImage: item.icon)
                        .font(.subheadline.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(mode == item ? ScedraTheme.purple : Color.clear, in: Capsule())
                        .foregroundStyle(mode == item ? .white : ScedraTheme.deepPurple)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(ScedraTheme.lavender.opacity(0.55), in: Capsule())
    }

    private var voiceBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                Task {
                    if speech.isListening {
                        speech.stop()
                    } else {
                        sourceText = ""
                        captureError = nil
                        await speech.start()
                    }
                }
            } label: {
                HStack {
                    Image(systemName: speech.isListening ? "stop.fill" : "mic.fill")
                    Text(speech.isListening ? "Stop" : "Start listen")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(speech.isListening ? ScedraTheme.purple : ScedraTheme.lavender, in: Capsule())
                .foregroundStyle(speech.isListening ? .white : ScedraTheme.deepPurple)
            }
            .buttonStyle(.plain)

            if speech.isListening {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                    Text(
                        speech.transcript.isEmpty
                            ? "Listening… speak the appointment"
                            : "Listening… tap Stop when done"
                    )
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ScedraTheme.purple)
            }

            if let fallback = speech.fallbackMessage {
                Text(fallback)
                    .font(.footnote)
                    .foregroundStyle(ScedraTheme.deepPurple.opacity(0.8))
            }

            TextField("Spoken text — or type if listening fails", text: voiceFieldText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3...6)
                .padding(12)
                .background(ScedraTheme.blush, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .id(composerFieldID)
        }
    }

    /// Prefer the live transcript while listening so words show even if an
    /// `onChange` hop lags behind Apple's partials.
    private var voiceFieldText: Binding<String> {
        Binding(
            get: {
                if mode == .voice, speech.isListening {
                    return SpeechTranscriptStitch.preferringLonger(sourceText, speech.transcript)
                }
                return sourceText
            },
            set: { sourceText = $0 }
        )
    }

    private var photoBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Cancel already clears the session. Don't offer a second
            // "choose another" path while confirmation, OCR, or an error is up.
            if !photoSession.canCancel {
                Button {
                    prepareToChooseAnotherPhoto()
                } label: {
                    HStack {
                        Image(systemName: "photo.on.rectangle")
                        Text("Choose photo")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(ScedraTheme.lavender, in: Capsule())
                    .foregroundStyle(ScedraTheme.deepPurple)
                }
                .buttonStyle(.plain)
            }

            if let photoImage {
                Image(uiImage: photoImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxHeight: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            if isReadingPhoto {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Reading text…")
                        .font(.subheadline)
                        .foregroundStyle(ScedraTheme.purple)
                    Spacer(minLength: 0)
                }
            }

            if photoSession.canCancel {
                Button("Cancel", role: .cancel) {
                    cancelPhotoCapture()
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(ScedraTheme.deepPurple)
            }

            TextField("Photo text — type if nothing is found", text: $sourceText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3...6)
                .padding(12)
                .background(ScedraTheme.blush, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .id(composerFieldID)
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoItem,
            matching: .images,
            preferredItemEncoding: .compatible
        )
        .onChange(of: photoItem) { _, newItem in
            consumePickedPhoto(newItem)
        }
    }

    private var typeBody: some View {
        TextField("dentist tomorrow at 2 at Stanford", text: $sourceText, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(4...8)
            .padding(12)
            .background(ScedraTheme.blush, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .id(composerFieldID)
    }

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Today")
                .font(.system(size: 20, weight: .semibold, design: .serif))
                .foregroundStyle(ScedraTheme.deepPurple)

            switch calendar.access {
            case .unknown:
                todayPlaceholder(ScedraString("Checking Calendar access…"))
            case .denied:
                todayPlaceholder(ScedraString("Calendar access is off. Enable it in Settings."))
            case .writeOnly, .full:
                if calendar.today.isEmpty {
                    todayPlaceholder(
                        calendar.access == .writeOnly
                            ? ScedraString("Nothing listed yet. Grant full access to see other events.")
                            : ScedraString("Nothing today.")
                    )
                } else {
                    EventListView(
                        items: calendar.today,
                        onSelect: { selectedAppointment = SelectedAppointment(item: $0) },
                        onDelete: { pendingDelete = $0 }
                    )
                    .scedraCard()
                    HomeGapSection(
                        stops: calendar.today.filter { !$0.isAllDay }.map { $0.asHomeGapStop() }
                    )
                    Text("Tap for details. Trash to delete.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let deleteError {
                Text(deleteError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private func todayPlaceholder(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scedraCard()
    }

    /// Confirm already wrote the EventKit event. Empty type / voice / photo
    /// text so the next capture starts blank. Do not call this on a failed save.
    private func clearComposerAfterSuccessfulSave() {
        let next = CaptureComposerPolicy.afterSuccessfulSave(
            .init(
                sourceText: sourceText,
                transcript: speech.transcript,
                fallbackMessage: speech.fallbackMessage
            )
        )
        speech.cancel()
        speech.clearHeardText()
        sourceText = next.sourceText
        applyPhotoSession(PhotoCapturePolicy.sessionAfterSuccessfulSave(photoSession))
        composerFieldID += 1
    }

    private func reviewTapped() {
        savedBanner = nil
        if mode == .voice {
            if speech.isListening {
                speech.stop()
            }
            // Prefer the longer stitched transcript if a live update raced Review.
            let heard = speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            let typed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !heard.isEmpty, heard.count > typed.count {
                sourceText = speech.transcript
            }
        }
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            captureError = emptyPrompt
            return
        }
        let parsed = EventExtractor.drafts(from: text)
        guard !parsed.isEmpty else {
            captureError = ScedraString("Couldn’t read an appointment.")
            return
        }
        captureError = nil
        let imageURL: URL? = {
            guard mode == .photo, let photoImage else { return nil }
            return OriginalImageStore.save(photoImage)
        }()
        drafts = ReviewOriginal.attaching(imageURL: imageURL, to: parsed)
        showReview = true
    }

    private var emptyPrompt: String {
        switch mode {
        case .voice: ScedraString("Listen or type an appointment first.")
        case .photo: ScedraString("Pick a photo or type it.")
        case .type: ScedraString("Type an appointment first.")
        }
    }

    private func delete(_ item: TodayItem) {
        do {
            try calendar.delete(item)
            deleteError = nil
        } catch {
            deleteError = error.localizedDescription
        }
        pendingDelete = nil
    }

    private var photoSession: PhotoCapturePolicy.Session {
        PhotoCapturePolicy.Session(
            hasPickerItem: photoItem != nil,
            hasImage: photoImage != nil,
            isReading: isReadingPhoto,
            sourceText: sourceText,
            error: captureError,
            hasDrafts: !drafts.isEmpty,
            isPresentingPicker: showPhotoPicker
        )
    }

    /// Clear the stale picker item first — otherwise PhotosPicker treats a
    /// re-pick of the same screenshot as "already selected" and does nothing.
    private func prepareToChooseAnotherPhoto() {
        let next = PhotoCapturePolicy.sessionPreparingNewPick(photoSession)
        photoItem = nil
        showPhotoPicker = false
        guard next.isPresentingPicker else { return }
        Task { @MainActor in
            showPhotoPicker = true
        }
    }

    private func consumePickedPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        let next = PhotoCapturePolicy.sessionAfterConsumingPickerItem(photoSession)
        photoItem = nil
        showPhotoPicker = next.isPresentingPicker
        startPhotoRead(item)
    }

    private func startPhotoRead(_ item: PhotosPickerItem) {
        photoReadGeneration += 1
        let generation = photoReadGeneration
        photoReadTask?.cancel()
        photoReadTask = Task {
            await readPhoto(item, generation: generation)
        }
    }

    /// Stop OCR and return to an empty Capture card — no leftover draft.
    private func cancelPhotoCapture() {
        photoReadGeneration += 1
        photoReadTask?.cancel()
        photoReadTask = nil
        applyPhotoSession(PhotoCapturePolicy.sessionAfterCancel(photoSession))
        savedBanner = nil
    }

    /// Leaving Photo must not leave Review disabled behind a stuck spinner.
    private func abandonInFlightPhotoRead() {
        guard isReadingPhoto else { return }
        photoReadGeneration += 1
        photoReadTask?.cancel()
        photoReadTask = nil
        isReadingPhoto = false
    }

    private func applyPhotoSession(_ session: PhotoCapturePolicy.Session) {
        if !session.hasPickerItem { photoItem = nil }
        if !session.hasImage { photoImage = nil }
        isReadingPhoto = session.isReading
        sourceText = session.sourceText
        captureError = session.error
        if !session.hasDrafts {
            drafts = []
            showReview = false
        }
        showPhotoPicker = session.isPresentingPicker
    }

    private func readPhoto(_ item: PhotosPickerItem, generation: Int) async {
        guard generation == photoReadGeneration, !Task.isCancelled else { return }
        isReadingPhoto = true
        captureError = nil
        savedBanner = nil
        sourceText = ""

        defer {
            if generation == photoReadGeneration {
                isReadingPhoto = false
            }
        }

        let image: UIImage
        do {
            guard let loaded = try await loadImage(from: item) else {
                applyFailedRead(keepImage: false, generation: generation)
                return
            }
            image = loaded
        } catch {
            applyFailedRead(keepImage: false, generation: generation)
            return
        }

        guard generation == photoReadGeneration, !Task.isCancelled else { return }
        photoImage = image
        do {
            let text = try await PhotoTextRecognizer.recognizeText(in: image)
            guard generation == photoReadGeneration, !Task.isCancelled else { return }
            sourceText = text
            captureError = nil
        } catch is CancellationError {
            return
        } catch {
            guard generation == photoReadGeneration, !Task.isCancelled else { return }
            let next = PhotoCapturePolicy.sessionAfterFailedRead(
                photoSession,
                message: error.localizedDescription,
                keepImage: true
            )
            applyPhotoSession(next)
        }
    }

    private func applyFailedRead(keepImage: Bool, generation: Int) {
        guard generation == photoReadGeneration, !Task.isCancelled else { return }
        let next = PhotoCapturePolicy.sessionAfterFailedRead(
            photoSession,
            message: PhotoTextError.unreadableImage.errorDescription ?? PhotoTextError.unreadableImage.localizedDescription,
            keepImage: keepImage
        )
        applyPhotoSession(next)
    }

    /// Image UTIs first (generic `Data` is `public.data` and silently fails),
    /// then a security-scoped file URL, then the iCloud PHAsset.
    private func loadImage(from item: PhotosPickerItem) async throws -> UIImage? {
        if let picked = try? await item.loadTransferable(type: PickedPhoto.self) {
            return picked.image
        }
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage(data: data) {
            return image
        }
        if let url = try? await item.loadTransferable(type: URL.self) {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                return image
            }
        }
        if let identifier = item.itemIdentifier {
            return await imageFromPhotoLibrary(identifier: identifier)
        }
        return nil
    }

    private func imageFromPhotoLibrary(identifier: String) async -> UIImage? {
        let allowed: Bool
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            allowed = true
        case .notDetermined:
            allowed = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    continuation.resume(returning: status == .authorized || status == .limited)
                }
            }
        default:
            allowed = false
        }
        guard allowed else { return nil }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = assets.firstObject else { return nil }

        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.version = .current
            var finished = false
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                guard !finished else { return }
                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                    finished = true
                    continuation.resume(returning: nil)
                    return
                }
                if info?[PHImageErrorKey] != nil {
                    finished = true
                    continuation.resume(returning: nil)
                    return
                }
                if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded {
                    return
                }
                finished = true
                continuation.resume(returning: data.flatMap { UIImage(data: $0) })
            }
        }
    }
}

#Preview {
    RootView()
}
