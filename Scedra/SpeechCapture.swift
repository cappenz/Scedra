import AVFoundation
import Foundation
import Speech

nonisolated enum SpeechCaptureError: LocalizedError, Equatable {
    case speechPermissionDenied
    case speechPermissionNotDetermined
    case microphonePermissionDenied
    case recognizerUnavailableForLanguage
    case recognizerOffline
    case microphoneUnavailable
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .speechPermissionDenied:
            "Speech recognition is turned off for Scedra. Turn on Speech Recognition in Settings → Scedra, or type the appointment."
        case .speechPermissionNotDetermined:
            "Scedra needs permission to turn speech into text. Tap Start listen again and choose Allow."
        case .microphonePermissionDenied:
            "The microphone is turned off for Scedra. Turn on Microphone in Settings → Scedra, or type the appointment."
        case .recognizerUnavailableForLanguage:
            "Listening isn’t available for your phone’s language yet. Type the appointment instead."
        case .recognizerOffline:
            "Listening isn’t available right now. Check your internet connection, or type the appointment."
        case .microphoneUnavailable:
            #if targetEnvironment(simulator)
            "The Simulator has no working microphone. Try Voice on a real iPhone, or type the appointment."
            #else
            "The microphone isn’t available right now. Close other apps using it, or type the appointment."
            #endif
        case .noSpeechDetected:
            "Didn’t catch anything. Tap Start listen and speak, or type the appointment."
        }
    }
}

/// Holds the live recognition request so the real-time audio tap can feed it
/// without touching main-actor state. Keeps a short rolling buffer so a
/// restarted task still hears the words spoken during Apple's pause/end.
private nonisolated final class RecognitionRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recent: [AVAudioPCMBuffer] = []
    /// ~1s at 48kHz / 1024-frame callbacks — enough to survive a restart.
    private let maxRecent = 48

    /// Attach only after `recognitionTask(with:)` so the request is listening.
    func replace(with request: SFSpeechAudioBufferRecognitionRequest?, replayRecent: Bool = false) {
        lock.lock()
        self.request = request
        let warmup = replayRecent ? recent : []
        lock.unlock()
        guard let request else { return }
        for buffer in warmup {
            request.append(buffer)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if let copy = Self.copy(buffer) {
            recent.append(copy)
            if recent.count > maxRecent {
                recent.removeFirst(recent.count - maxRecent)
            }
        }
        // A nil request means the task is not armed yet — keep the buffer
        // in `recent` but do not append into a deaf request.
        let current = request
        lock.unlock()
        current?.append(buffer)
    }

    func endAudio() {
        lock.lock()
        let current = request
        lock.unlock()
        current?.endAudio()
    }

    func reset() {
        lock.lock()
        request = nil
        recent.removeAll()
        lock.unlock()
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let sourceList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let destinationList = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (source, destination) in zip(sourceList, destinationList) {
            guard let sourceBytes = source.mData, let destinationBytes = destination.mData else { continue }
            memcpy(destinationBytes, sourceBytes, Int(source.mDataByteSize))
        }
        return copy
    }
}

/// Microphone dictation for the Voice capture path.
///
/// The mic stays open until the user taps Stop. iOS ends a recognition task at
/// every natural pause, so each finished task is folded into `transcript` and a
/// fresh one is started against the same running audio engine. Audio is only
/// ever held in memory buffers — nothing is written to disk.
@MainActor
@Observable
final class SpeechCapture {
    private enum Phase {
        case idle
        case listening
        /// Stop was tapped; waiting for the last few words to come back.
        case finishing
    }

    /// Everything heard so far in this session, including the in-progress phrase.
    private(set) var transcript = ""
    private(set) var isListening = false
    private(set) var fallbackMessage: String?

    private var phase: Phase = .idle
    private var recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let requestBox = RecognitionRequestBox()
    private var tapInstalled = false
    private var engineObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var isRecoveringEngine = false
    private var lastEngineStart = Date.distantPast

    /// Phrases already finalised, kept separate so a restarted task can't erase them.
    private var committedText = ""
    private var livePhrase = ""
    /// Bumped on every restart so callbacks from a retired task are ignored.
    private var segmentToken = 0
    /// When the next segment should hear the last second of audio (mid-phrase abort).
    private var replayWarmupOnNextSegment = false

    func toggle() async {
        if isListening {
            stop()
        } else {
            await start()
        }
    }

    func start() async {
        if phase == .finishing {
            finishUp()
        }
        guard phase == .idle else { return }
        fallbackMessage = nil
        transcript = ""
        committedText = ""
        livePhrase = ""
        replayWarmupOnNextSegment = false
        requestBox.reset()

        // Two separate iOS prompts. Missing either usage string crashes on the ask.
        let speechStatus = await Self.requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            fail(with: Self.error(for: speechStatus))
            return
        }

        guard await Self.requestMicrophone() else {
            fail(with: .microphonePermissionDenied)
            return
        }

        guard let recognizer = Self.makeRecognizer() else {
            fail(with: .recognizerUnavailableForLanguage)
            return
        }
        if recognizer.isAvailable {
            self.recognizer = recognizer
        } else if let fallback = SFSpeechRecognizer(locale: Locale(identifier: SpeechRecognizerLocale.fallbackIdentifier)),
                  fallback.isAvailable {
            self.recognizer = fallback
        } else {
            fail(with: .recognizerOffline)
            return
        }

        do {
            try startAudioEngine()
        } catch {
            teardown()
            fail(with: .microphoneUnavailable)
            return
        }

        phase = .listening
        isListening = true
        observeAudioLifecycle()
        // Engine + tap are already running; replay that warmup after the
        // recognition task starts so the first words are not dropped.
        replayWarmupOnNextSegment = true
        startSegment()
    }

    func stop() {
        guard phase == .listening else {
            if phase == .idle { teardown() }
            return
        }
        phase = .finishing
        isListening = false

        // Freeze what we already heard so Review/Hear don't wait on Apple.
        commitLivePhrase()

        // Flush the tail of the sentence before tearing the engine down.
        stopAudioInput()
        requestBox.endAudio()
        recognitionTask?.finish()

        let token = segmentToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.phase == .finishing, self.segmentToken == token else { return }
            self.finishUp()
        }
    }

    /// Hard reset used when the capture screen goes away.
    func cancel() {
        phase = .idle
        isListening = false
        teardown()
    }

    /// Drop leftover Voice words after a successful Calendar save.
    func clearHeardText() {
        transcript = ""
        committedText = ""
        livePhrase = ""
        fallbackMessage = nil
    }

    // MARK: - Audio

    private func startAudioEngine() throws {
        try activateSession()
        let engine = audioEngine ?? AVAudioEngine()
        try attachTap(to: engine)
        engine.prepare()
        try engine.start()
        audioEngine = engine
        lastEngineStart = Date()
    }

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        // playAndRecord survives Hear playback, Bluetooth, and route changes.
        // .record succeeds on a phone and then drops the session on interruption.
        // .measurement (not .default) keeps AEC from silencing the built-in mic.
        let mode: AVAudioSession.Mode = SpeechLiveTranscriptPolicy.usesMeasurementMode
            ? .measurement
            : .default
        do {
            try session.setCategory(
                .playAndRecord,
                mode: mode,
                options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true)
        } catch {
            // Keep measurement — falling back to .default is the silent-mic path.
            try session.setCategory(
                .playAndRecord,
                mode: mode,
                options: [.duckOthers, .defaultToSpeaker]
            )
            try session.setActive(true)
        }
        try? session.overrideOutputAudioPort(.speaker)
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }
    }

    private func attachTap(to engine: AVAudioEngine) throws {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        let input = engine.inputNode
        if SpeechLiveTranscriptPolicy.disablesVoiceProcessing, input.isVoiceProcessingEnabled {
            try? input.setVoiceProcessingEnabled(false)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeechCaptureError.microphoneUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [requestBox] buffer, _ in
            requestBox.append(buffer)
        }
        tapInstalled = true
    }

    private func stopAudioInput() {
        if tapInstalled {
            audioEngine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if audioEngine?.isRunning == true {
            audioEngine?.stop()
        }
    }

    private func observeAudioLifecycle() {
        removeAudioObservers()
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recoverEngineIfNeeded()
            }
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleInterruption(notification)
            }
        }
    }

    private func removeAudioObservers() {
        if let engineObserver {
            NotificationCenter.default.removeObserver(engineObserver)
            self.engineObserver = nil
        }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard phase == .listening else { return }
        let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        let type = typeValue.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
        guard type == .ended else { return }
        recoverEngineIfNeeded(force: true)
    }

    private func recoverEngineIfNeeded(force: Bool = false) {
        guard phase == .listening, !isRecoveringEngine else { return }
        // A live engine is not a hang-up. Rebuilding it mid-phrase drops audio.
        if !force, audioEngine?.isRunning == true { return }
        if !force, Date().timeIntervalSince(lastEngineStart) < 0.35 { return }
        isRecoveringEngine = true
        defer { isRecoveringEngine = false }
        do {
            try activateSession()
            stopAudioInput()
            try startAudioEngine()
            replayWarmupOnNextSegment = true
            startSegment()
        } catch {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, self.phase == .listening else { return }
                self.recoverEngineIfNeeded(force: true)
            }
        }
    }

    private func teardown() {
        segmentToken += 1
        removeAudioObservers()
        stopAudioInput()
        audioEngine = nil
        requestBox.endAudio()
        requestBox.reset()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognizer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Recognition

    private func startSegment() {
        guard let recognizer, phase == .listening else { return }
        if audioEngine?.isRunning != true {
            recoverEngineIfNeeded(force: true)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = SpeechLiveTranscriptPolicy.shouldReportPartialResults
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = SpeechLiveTranscriptPolicy.shouldForceOnDeviceRecognition
        // Do not force on-device. Requiring it is the real-phone cutoff:
        // iOS endpoints after a breath and then rejects the next task.

        // Retire the previous phrase's task before the new one starts listening.
        // Do not cancel — Apple already ended it, and cancel races the next task.
        segmentToken += 1
        let token = segmentToken
        recognitionTask = nil
        let replay = replayWarmupOnNextSegment
        replayWarmupOnNextSegment = false

        // Task first, then arm the tap. Appending before recognitionTask(with:)
        // is the empty-transcript kill path — especially after a 1700 restart.
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Pull the string before the actor hop — the result object is
            // not guaranteed to still carry bestTranscription later.
            let phrase = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal
            Task { @MainActor [weak self] in
                self?.handle(phrase: phrase, isFinal: isFinal, error: error, token: token)
            }
        }
        if SpeechLiveTranscriptPolicy.shouldDeliverAudioToRequest(recognitionTaskStarted: true) {
            requestBox.replace(with: request, replayRecent: replay)
        }
    }

    private func handle(phrase: String?, isFinal: Bool?, error: Error?, token: Int) {
        guard token == segmentToken, phase != .idle else { return }

        if let phrase {
            livePhrase = SpeechTranscriptStitch.stabilize(
                current: livePhrase,
                incoming: phrase,
                isFinal: isFinal ?? false
            )
            refreshTranscript()
        }

        let segmentEnded = isFinal == true || error != nil
        guard segmentEnded else { return }

        commitLivePhrase()

        switch phase {
        case .finishing:
            finishUp()
        case .idle:
            break
        case .listening:
            if SpeechRestartPolicy.shouldEndListening(
                userRequestedStop: false,
                consecutiveErrors: 0,
                error: error
            ) {
                return
            }
            guard SpeechRestartPolicy.shouldRestart(
                isListening: true,
                userRequestedStop: false,
                isFinal: isFinal == true,
                error: error
            ) else { return }
            replayWarmupOnNextSegment = SpeechRestartPolicy.shouldReplayBufferedAudio(
                isFinal: isFinal == true,
                error: error
            )
            startSegment()
        }
    }

    private func commitLivePhrase() {
        committedText = SpeechTranscriptStitch.appending(committedText, livePhrase)
        livePhrase = ""
        refreshTranscript()
    }

    private func refreshTranscript() {
        let next = SpeechTranscriptStitch.appending(committedText, livePhrase)
        transcript = SpeechTranscriptStitch.preferringLonger(transcript, next)
    }

    private func finishUp() {
        phase = .idle
        isListening = false
        teardown()
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fallbackMessage = SpeechCaptureError.noSpeechDetected.errorDescription
        }
    }

    private func fail(with error: SpeechCaptureError) {
        phase = .idle
        isListening = false
        fallbackMessage = error.errorDescription
    }

    // MARK: - Availability and permissions

    /// Phone language, resolved to a Speech-supported identifier.
    /// `Locale.current` alone is the German→English silent-empty path (`en_DE`).
    static func makeRecognizer() -> SFSpeechRecognizer? {
        let identifier = SpeechRecognizerLocale.supportedIdentifier(
            matching: .autoupdatingCurrent,
            preferredLanguages: Locale.preferredLanguages,
            availableIdentifiers: SFSpeechRecognizer.supportedLocales().map(\.identifier)
        )
        if let match = SFSpeechRecognizer(locale: Locale(identifier: identifier)) {
            return match
        }
        return SFSpeechRecognizer(locale: Locale(identifier: SpeechRecognizerLocale.fallbackIdentifier))
            ?? SFSpeechRecognizer()
    }

    static func error(for status: SFSpeechRecognizerAuthorizationStatus) -> SpeechCaptureError {
        switch status {
        case .denied, .restricted: .speechPermissionDenied
        case .notDetermined: .speechPermissionNotDetermined
        default: .speechPermissionDenied
        }
    }

    /// Pauses, cancellations and "no speech yet" are routine while the mic is open.
    static func isFatal(_ error: Error) -> Bool {
        SpeechRestartPolicy.isFatal(error)
    }

    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current != .notDetermined { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private nonisolated static func requestMicrophone() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: break
        }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
