import Foundation

/// Whether the live Voice field can show words. Empty transcript is not a
/// cutoff — it means the recognition request never heard the mic, or
/// partials were never asked for.
nonisolated enum SpeechLiveTranscriptPolicy {
    static let shouldReportPartialResults = true
    static let shouldForceOnDeviceRecognition = SpeechRestartPolicy.shouldForceOnDeviceRecognition

    /// `playAndRecord` + `.default` turns on echo cancellation, which
    /// delivers silent tap buffers on a real iPhone. Measurement keeps the mic.
    static let usesMeasurementMode = true
    static let disablesVoiceProcessing = true

    /// Apple drops buffers appended before `recognitionTask(with:)` starts.
    /// A 1700 restart that arms the request first is born deaf.
    static func shouldDeliverAudioToRequest(recognitionTaskStarted: Bool) -> Bool {
        recognitionTaskStarted
    }

    /// The text field only updates when partials are on *and* the request
    /// is actually receiving tap audio.
    static func shouldShowPartials(
        shouldReportPartialResults: Bool,
        requestReceivingAudio: Bool
    ) -> Bool {
        shouldReportPartialResults && requestReceivingAudio
    }

    /// After 1700 / isFinal, the next request still needs the live tap.
    static func restartedRequestMustReceiveLiveTapAudio(userRequestedStop: Bool) -> Bool {
        !userRequestedStop
    }
}

/// Whether Apple ending a recognition task should open a new one, or
/// really means "stop the microphone".
nonisolated enum SpeechRestartPolicy {
    /// Never force on-device recognition. Requiring it makes iOS endpoint
    /// after a breath and refuse a follow-up task on a real iPhone.
    static let shouldForceOnDeviceRecognition = false

    /// Keep listening until Stop — Apple finishing a phrase is not the user finishing.
    static func shouldRestart(
        isListening: Bool,
        userRequestedStop: Bool,
        isFinal: Bool,
        error: Error?
    ) -> Bool {
        guard isListening, !userRequestedStop else { return false }
        return isFinal || error != nil
    }

    /// Only Stop (or leaving Voice) hangs up. Phrase-end errors must never
    /// accumulate into a session teardown — 1700 fires after almost every phrase.
    static func shouldEndListening(
        userRequestedStop: Bool,
        consecutiveErrors: Int,
        error: Error?
    ) -> Bool {
        _ = consecutiveErrors
        _ = error
        return userRequestedStop
    }

    /// Kept so older tests still compile. Always false: error counts are not a hang-up.
    static func shouldGiveUp(consecutiveFatalErrors: Int) -> Bool {
        shouldEndListening(userRequestedStop: false, consecutiveErrors: consecutiveFatalErrors, error: nil)
    }

    /// Replay the rolling audio buffer only when Apple aborted mid-phrase.
    /// Replaying after a clean `isFinal` immediately re-finalizes the next task.
    static func shouldReplayBufferedAudio(isFinal: Bool, error: Error?) -> Bool {
        error != nil && !isFinal
    }

    /// Assistant-domain codes are task lifecycle (phrase ended, retry, cancel),
    /// not a dead microphone. 1700 is the one a real iPhone fires every pause.
    static func isFatal(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == "kAFAssistantErrorDomain" { return false }
        if ns.domain == "kLSRErrorDomain" { return false }
        if ns.localizedDescription.localizedCaseInsensitiveContains("cancel") { return false }
        if ns.code == 1 { return false }
        return ns.domain == NSCocoaErrorDomain && ns.code == 4097
    }
}

/// Folds restarted recognition phrases into one utterance so a mid-sentence
/// cut does not drop "dentist tomorrow at 2 at school".
nonisolated enum SpeechTranscriptStitch {
    /// Keep already-heard words when Apple's final hypothesis is empty or shorter.
    static func stabilize(current: String, incoming: String, isFinal: Bool) -> String {
        let have = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        if next.isEmpty { return have }
        if have.isEmpty { return next }
        if isFinal || next.count < have.count {
            let haveFold = have.lowercased()
            let nextFold = next.lowercased()
            if haveFold.hasPrefix(nextFold), have.count > next.count {
                return have
            }
            if haveFold.contains(nextFold), next.count + 8 < have.count {
                return have
            }
        }
        return next
    }

    /// Never replace a longer running transcript with a shorter hypothesis.
    static func preferringLonger(_ current: String, _ incoming: String) -> String {
        let have = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        if next.isEmpty { return have }
        if have.isEmpty { return next }
        if next.count < have.count, have.lowercased().hasPrefix(next.lowercased()) {
            return have
        }
        return next
    }

    /// Append a new phrase, collapsing overlap from a restarted task.
    static func appending(_ existing: String, _ incoming: String) -> String {
        let left = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        if right.isEmpty { return left }
        if left.isEmpty { return right }

        let leftFold = left.lowercased()
        let rightFold = right.lowercased()
        if rightFold.hasPrefix(leftFold) { return right }
        if leftFold.hasSuffix(rightFold) { return left }

        let leftWords = words(in: left)
        let rightWords = words(in: right)
        let maxOverlap = min(leftWords.count, rightWords.count)
        var overlap = 0
        if maxOverlap > 0 {
            for count in stride(from: maxOverlap, through: 1, by: -1) {
                let suffix = leftWords.suffix(count).map { $0.lowercased() }
                let prefix = rightWords.prefix(count).map { $0.lowercased() }
                if suffix.elementsEqual(prefix) {
                    overlap = count
                    break
                }
            }
        }

        if overlap > 0 {
            return (leftWords + rightWords.dropFirst(overlap)).joined(separator: " ")
        }
        return left + " " + right
    }

    private static func words(in text: String) -> [String] {
        text.split { $0.isWhitespace || $0.isNewline }.map(String.init)
    }
}

/// Maps the phone language onto a locale Apple Speech actually supports.
///
/// `SFSpeechRecognizer(locale: Locale.current)` is the silent-empty path after
/// a language switch: `en_DE` / bare `de` can construct a recognizer that
/// never fires results. Always resolve against `supportedLocales()` first;
/// if nothing matches, use `en-US` instead of returning nil.
nonisolated enum SpeechRecognizerLocale {
    static let fallbackIdentifier = "en-US"

    /// Preferred regional default when the phone only gives a language code.
    private static let preferredByLanguage = [
        "en": "en-US",
        "de": "de-DE",
        "fr": "fr-FR",
        "es": "es-ES",
        "it": "it-IT",
        "pt": "pt-BR",
        "nl": "nl-NL",
        "ja": "ja-JP",
        "ko": "ko-KR",
        "zh": "zh-CN"
    ]

    /// `de` / `fr` / `en` / `en_DE` → a supported identifier. Never nil.
    static func supportedIdentifier(
        matching locale: Locale,
        preferredLanguages: [String] = [],
        availableIdentifiers: [String]
    ) -> String {
        var candidates: [String] = [locale.identifier]
        if let language = languageCode(from: locale.identifier) {
            candidates.append(language)
        }
        candidates.append(contentsOf: preferredLanguages)

        for candidate in candidates {
            if let match = bestMatch(for: candidate, in: availableIdentifiers) {
                return match
            }
        }
        if let fallback = bestMatch(for: fallbackIdentifier, in: availableIdentifiers) {
            return fallback
        }
        return fallbackIdentifier
    }

    private static func bestMatch(for raw: String, in available: [String]) -> String? {
        let normalized = normalize(raw)
        if let exact = available.first(where: { normalize($0) == normalized }) {
            return exact
        }

        guard let language = languageCode(from: raw) else { return nil }

        if let preferred = preferredByLanguage[language],
           let match = available.first(where: { normalize($0) == normalize(preferred) }) {
            return match
        }

        return available.first { identifier in
            languageCode(from: identifier) == language
        }
    }

    private static func languageCode(from identifier: String) -> String? {
        let locale = Locale(identifier: identifier.replacingOccurrences(of: "_", with: "-"))
        if let code = locale.language.languageCode?.identifier, !code.isEmpty {
            return code.lowercased()
        }
        return identifier
            .split { $0 == "-" || $0 == "_" }
            .first
            .map { String($0).lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func normalize(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}
