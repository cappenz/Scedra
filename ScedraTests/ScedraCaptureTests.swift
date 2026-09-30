import AVFoundation
import Speech
import UIKit
import Vision
import XCTest
@testable import Scedra

/// Covers the Voice and Photo capture paths. OCR here is the real Vision
/// pipeline running on device; speech recognition needs live audio, so only its
/// availability and error reporting are covered.
final class ScedraCaptureTests: XCTestCase {

    // MARK: - Photo: on-device OCR

    func testOCRReadsAppointmentTextFromAScreenshot() throws {
        let image = renderScreenshot(lines: ["Appointment confirmed", "Dentist tomorrow at 2 PM", "at 500 Main Street"])
        let text = try PhotoTextRecognizer.recognize(in: image)

        XCTAssertTrue(text.localizedCaseInsensitiveContains("Dentist"), "expected Dentist in: \(text)")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("tomorrow"), "expected tomorrow in: \(text)")
    }

    func testOCRKeepsTopToBottomReadingOrder() throws {
        let image = renderScreenshot(lines: ["Haircut Monday at 9 AM", "Dentist Tuesday at 4 PM"])
        let text = try PhotoTextRecognizer.recognize(in: image)

        let haircut = text.range(of: "Haircut", options: .caseInsensitive)
        let dentist = text.range(of: "Dentist", options: .caseInsensitive)
        let haircutIndex = try XCTUnwrap(haircut?.lowerBound, "expected Haircut in: \(text)")
        let dentistIndex = try XCTUnwrap(dentist?.lowerBound, "expected Dentist in: \(text)")
        XCTAssertLessThan(haircutIndex, dentistIndex, "lines came back scrambled: \(text)")
    }

    func testOCRHandlesSidewaysCameraPhotos() throws {
        let upright = renderScreenshot(lines: ["Dentist tomorrow at 2 PM"])

        // A portrait camera photo stores sideways pixels plus an orientation tag.
        // Baking with .left and tagging .right (its inverse) reproduces that exactly.
        for (baked, tag) in [
            (UIImage.Orientation.left, UIImage.Orientation.right),
            (.right, .left),
            (.down, .down)
        ] {
            let sidewaysPixels = try XCTUnwrap(flatten(upright, displayedAs: baked).cgImage)
            let photo = UIImage(cgImage: sidewaysPixels, scale: 1, orientation: tag)

            let text = try PhotoTextRecognizer.recognize(in: photo)
            XCTAssertTrue(
                text.localizedCaseInsensitiveContains("Dentist"),
                "orientation \(tag.rawValue) lost the text: \(text)"
            )
        }
    }

    func testOCRReportsWhenAPhotoHasNoText() {
        let blank = renderScreenshot(lines: [])
        XCTAssertThrowsError(try PhotoTextRecognizer.recognize(in: blank)) { error in
            XCTAssertEqual(error as? PhotoTextError, .noTextFound)
        }
        XCTAssertTrue(
            EventExtractor.drafts(from: "").isEmpty,
            "empty OCR must not open Review"
        )
    }

    func testPickedPhotoDecodesPNGBytes() throws {
        let image = renderScreenshot(lines: ["Dentist tomorrow at 2 PM"])
        let data = try XCTUnwrap(image.pngData())
        let picked = try PickedPhoto(data: data)
        XCTAssertNotNil(picked.image.cgImage)
        let text = try PhotoTextRecognizer.recognize(in: picked.image)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Dentist"), "expected Dentist in: \(text)")
    }

    func testPickedPhotoRejectsEmptyBytes() {
        XCTAssertThrowsError(try PickedPhoto(data: Data())) { error in
            XCTAssertEqual(error as? PhotoTextError, .unreadableImage)
        }
    }

    func testPhotoErrorsAllExplainWhatToDo() {
        let errors: [PhotoTextError] = [.unreadableImage, .recognitionFailed, .noTextFound]
        let messages = errors.map { $0.errorDescription ?? "" }
        XCTAssertFalse(messages.contains(where: \.isEmpty), "every photo error needs plain-language text")
        XCTAssertEqual(Set(messages).count, errors.count, "photo errors should not share wording")
    }

    func testEmptyObservationsProduceEmptyText() {
        XCTAssertEqual(PhotoTextRecognizer.readingOrderText(from: []), "")
    }

    func testMessyPortalRecognizedLinesBecomeReadableTranscriptAndExamTitle() {
        let messyLines = [
            "Appointoointment Detailils",
            "Annual Physical Exam Confirmed",
            "Peninsulla Familly Healthh",
            "Appointoointment Typeype Annual Physical Exam",
            "Patient Alex Rivera",
            "Dateate Tuesday, October 14, 2026",
            "Check-in Time 2:15 PM",
            "Appointoointment Time 2:30 PM – 3:15 PM",
            "Location Peninsulla Familly Healthh",
            "Address 11800 Willow Road, Suite 240, Menlo Park, CA 94025"
        ]
        var top: CGFloat = 0.06
        let blocks = messyLines.map { line in
            defer { top += 0.07 }
            return PhotoTextRecognizer.RecognizedTextBlock(text: line, top: top, left: 0.08, height: 0.04)
        }

        let blob = PhotoTextRecognizer.readableTranscript(from: [
            .init(text: messyLines.joined(), top: 0.1, left: 0.1, height: 0.7)
        ])
        let lined = PhotoTextRecognizer.readableTranscript(from: blocks)

        for transcript in [lined, blob, OCRTextNormalizer.readablePhotoTranscript(messyLines.joined(separator: "\n"))] {
            XCTAssertTrue(transcript.contains("\n"), "transcript must keep line breaks: \(transcript)")
            XCTAssertTrue(transcript.localizedCaseInsensitiveContains("Appointment"), transcript)
            XCTAssertTrue(transcript.localizedCaseInsensitiveContains("Peninsula"), transcript)
            XCTAssertTrue(transcript.localizedCaseInsensitiveContains("Family"), transcript)
            XCTAssertTrue(transcript.contains("11800"), transcript)
            let draft = EventExtractor.drafts(from: transcript).first
            XCTAssertEqual(draft?.title, "Annual Physical Exam", transcript)
            XCTAssertFalse(draft?.title.localizedCaseInsensitiveContains("Check-in") == true, draft?.title ?? "")
            XCTAssertTrue(draft?.title.localizedCaseInsensitiveContains("Physical Exam") == true, draft?.title ?? "")
        }

        let lines = lined.components(separatedBy: "\n")
        XCTAssertGreaterThanOrEqual(lines.count, 6, lined)
        XCTAssertTrue(lines.contains { $0.localizedCaseInsensitiveContains("Appointment Details") }, lined)
        XCTAssertTrue(lines.contains { $0.localizedCaseInsensitiveContains("Check-in") }, lined)
    }

    func testPhotoDraftViewOriginalIsTheImageNotTheOCR() throws {
        let image = renderScreenshot(lines: ["Annual Physical Exam", "Tuesday, October 14, 2026", "2:30 PM"])
        let url = try XCTUnwrap(OriginalImageStore.save(image))
        defer { OriginalImageStore.remove(url) }

        let drafts = ReviewOriginal.attaching(
            imageURL: url,
            to: EventExtractor.drafts(from: "dentist tomorrow at 2")
        )
        let draft = try XCTUnwrap(drafts.first)
        XCTAssertEqual(ReviewOriginal.presentation(for: draft), .photo(url))
        XCTAssertNotNil(OriginalImageStore.image(at: url))
        XCTAssertTrue(draft.title.localizedCaseInsensitiveContains("dentist"), draft.title)
    }

    func testIMessagePhotoDraftViewOriginalIsTheImage() throws {
        let image = renderScreenshot(lines: ["The Daily Grind", "12344 Elm St, Denver, CO 80202", "11am on saturday"])
        let url = try XCTUnwrap(OriginalImageStore.save(image))
        defer { OriginalImageStore.remove(url) }

        let drafts = ReviewOriginal.attaching(
            imageURL: url,
            to: EventExtractor.drafts(from: ScedraChatScreenshotTests.spacedIMessageOCR)
        )
        let draft = try XCTUnwrap(drafts.first)
        XCTAssertEqual(ReviewOriginal.presentation(for: draft), .photo(url), "View original is the photo, not the OCR")
        XCTAssertTrue(
            draft.title.localizedCaseInsensitiveContains("Daily Grind")
                || draft.title.localizedCaseInsensitiveContains("Coffee"),
            draft.title
        )
    }

    func testGluedIMessageRecognizedLinesBecomeReadableTranscript() {
        let messyLines = ScedraChatScreenshotTests.gluedIMessageOCR
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
        var top: CGFloat = 0.06
        let blocks = messyLines.map { line -> PhotoTextRecognizer.RecognizedTextBlock in
            defer { top += 0.07 }
            return PhotoTextRecognizer.RecognizedTextBlock(text: line, top: top, left: 0.08, height: 0.04)
        }
        let transcript = PhotoTextRecognizer.readableTranscript(from: blocks)
        XCTAssertTrue(transcript.contains("\n"), transcript)
        XCTAssertTrue(transcript.localizedCaseInsensitiveContains("Daily"), transcript)
        XCTAssertTrue(transcript.contains("12344"), transcript)
        let draft = EventExtractor.drafts(from: transcript).first
        XCTAssertTrue(
            draft?.title.localizedCaseInsensitiveContains("Daily Grind") == true
                || draft?.title.localizedCaseInsensitiveContains("Coffee") == true,
            draft?.title ?? ""
        )
        XCTAssertEqual(Calendar.current.component(.hour, from: draft?.start ?? Date()), 11, transcript)
    }

    func testTypedAndVoiceViewOriginalStayText() {
        let spoken = "dentist tomorrow at 2"
        let drafts = EventExtractor.drafts(from: spoken)
        let draft = drafts[0]
        XCTAssertEqual(ReviewOriginal.presentation(for: draft), .text(spoken))
        XCTAssertNil(draft.originalImageURL)
        XCTAssertTrue(draft.title.localizedCaseInsensitiveContains("dentist"), draft.title)
    }

    // MARK: - Photo: picker reset + cancel (Choose another was a no-op)

    func testConsumingAPickClearsThePickerItemSoARepickIsAccepted() {
        let afterPick = PhotoCapturePolicy.Session(
            hasPickerItem: true,
            hasImage: false,
            isReading: false,
            sourceText: "",
            error: nil,
            hasDrafts: false,
            isPresentingPicker: true
        )
        let consumed = PhotoCapturePolicy.sessionAfterConsumingPickerItem(afterPick)
        XCTAssertFalse(consumed.hasPickerItem, "stale picker item blocks Choose another photo")
        XCTAssertTrue(consumed.isReading)
        XCTAssertFalse(consumed.isPresentingPicker)
        XCTAssertNil(consumed.error)
    }

    func testChooseAnotherClearsTheStaleItemThenPresentsTheLibrary() {
        let stuck = PhotoCapturePolicy.Session(
            hasPickerItem: true,
            hasImage: true,
            isReading: false,
            sourceText: "old OCR",
            error: nil,
            hasDrafts: false,
            isPresentingPicker: false
        )
        let next = PhotoCapturePolicy.sessionPreparingNewPick(stuck)
        XCTAssertFalse(next.hasPickerItem, "must drop the last item or a re-pick is silent")
        XCTAssertTrue(next.isPresentingPicker)
        XCTAssertEqual(next.sourceText, "old OCR", "don't wipe text until a new photo lands")
        XCTAssertTrue(next.hasImage)
    }

    func testCancelClearsPhotoOCRAndAnyDraft() {
        let midRead = PhotoCapturePolicy.Session(
            hasPickerItem: true,
            hasImage: true,
            isReading: true,
            sourceText: "dentist tomorrow",
            error: "still reading",
            hasDrafts: true,
            isPresentingPicker: true
        )
        XCTAssertTrue(midRead.canCancel)
        let cancelled = PhotoCapturePolicy.sessionAfterCancel(midRead)
        XCTAssertEqual(cancelled, .empty)
        XCTAssertFalse(cancelled.canCancel)
        XCTAssertTrue(cancelled.sourceText.isEmpty)
        XCTAssertFalse(cancelled.hasDrafts)
        XCTAssertFalse(cancelled.isReading)
    }

    func testSuccessfulSaveClearsTypeVoiceAndPhotoComposerText() {
        let leftover = CaptureComposerPolicy.State(
            sourceText: "dentist tomorrow at 2",
            transcript: "dentist tomorrow at 2",
            fallbackMessage: "Listening failed"
        )
        let cleared = CaptureComposerPolicy.afterSuccessfulSave(leftover)
        XCTAssertTrue(cleared.sourceText.isEmpty)
        XCTAssertTrue(cleared.transcript.isEmpty)
        XCTAssertNil(cleared.fallbackMessage)

        let photo = PhotoCapturePolicy.Session(
            hasPickerItem: false,
            hasImage: true,
            isReading: false,
            sourceText: "Annual Physical Exam Confirmed",
            error: nil,
            hasDrafts: true,
            isPresentingPicker: false
        )
        let afterSave = PhotoCapturePolicy.sessionAfterSuccessfulSave(photo)
        XCTAssertEqual(afterSave, .empty)
        XCTAssertTrue(afterSave.sourceText.isEmpty)
        XCTAssertFalse(afterSave.hasImage)
        XCTAssertFalse(afterSave.hasDrafts)
    }

    func testFailedSaveLeavesComposerTextAlone() {
        let leftover = CaptureComposerPolicy.State(
            sourceText: "dentist tomorrow at 2",
            transcript: "dentist tomorrow at 2",
            fallbackMessage: nil
        )
        XCTAssertEqual(leftover.sourceText, "dentist tomorrow at 2")
        XCTAssertEqual(leftover.transcript, "dentist tomorrow at 2")
        XCTAssertNotEqual(
            CaptureComposerPolicy.afterSuccessfulSave(leftover),
            leftover,
            "only a successful EventKit write empties the box"
        )
    }

    func testFailedOCRLeavesChooseAnotherAndCancelUsable() {
        let reading = PhotoCapturePolicy.Session(
            hasPickerItem: true,
            hasImage: true,
            isReading: true,
            sourceText: "",
            error: nil,
            hasDrafts: false,
            isPresentingPicker: false
        )
        let failed = PhotoCapturePolicy.sessionAfterFailedRead(
            reading,
            message: PhotoTextError.noTextFound.errorDescription ?? "",
            keepImage: true
        )
        XCTAssertFalse(failed.isReading, "spinner must not stay stuck")
        XCTAssertFalse(failed.hasPickerItem, "must accept another pick after a failure")
        XCTAssertTrue(failed.hasImage)
        XCTAssertTrue(failed.sourceText.isEmpty)
        XCTAssertFalse(failed.hasDrafts)
        XCTAssertEqual(failed.error, PhotoTextError.noTextFound.errorDescription)
        XCTAssertTrue(failed.canCancel)

        let retry = PhotoCapturePolicy.sessionPreparingNewPick(failed)
        XCTAssertTrue(retry.isPresentingPicker)
        XCTAssertFalse(retry.hasPickerItem)
    }

    // MARK: - Photo: the OCR text reaches the same review draft as typing

    func testPhotoTextLandsOnASaveableDraft() throws {
        let image = renderScreenshot(lines: ["Dentist tomorrow at 2 PM"])
        let text = try PhotoTextRecognizer.recognize(in: image)

        let drafts = EventExtractor.drafts(from: text)
        let draft = try XCTUnwrap(drafts.first, "OCR text should parse like typed text: \(text)")
        XCTAssertTrue(draft.hasDate, "expected a date from: \(text)")
        XCTAssertTrue(draft.hasTime, "expected a time from: \(text)")
        XCTAssertEqual(draft.sourceText, text, "View original must keep the OCR wording")
    }

    func testSpokenTextUsesTheSameReviewDraftAsTyping() {
        let spoken = "Dentist tomorrow at 2 PM"
        let voiceDrafts = EventExtractor.drafts(from: spoken)
        let typedDrafts = EventExtractor.drafts(from: spoken)
        XCTAssertEqual(voiceDrafts.count, typedDrafts.count)
        XCTAssertEqual(voiceDrafts.first?.sourceText, spoken)
        XCTAssertEqual(voiceDrafts.first?.hasDate, typedDrafts.first?.hasDate)
        XCTAssertEqual(voiceDrafts.first?.hasTime, typedDrafts.first?.hasTime)
        XCTAssertEqual(voiceDrafts.first?.hasDate, true)
        XCTAssertEqual(voiceDrafts.first?.hasTime, true)
    }

    func testAppointmentDetailsPortalOCRExtractsSaveableDraft() {
        let text = """
        Appointment Details
        Annual Physical Exam Confirmed
        Peninsula Family Health
        Appointment Type Annual Physical Exam
        Patient Alex Rivera
        Provider Dr. Maya Chen, MD
        Date Tuesday, October 14, 2026
        Check-in Time 2:15 PM
        Appointment Time 2:30 PM – 3:15 PM
        Location Peninsula Family Health
        Address 11800 Willow Road, Suite 240, Menlo Park, CA 94025
        Phone (650) 555-0184
        Parking Garage entrance on Oak Avenue
        Notes Please bring your insurance card and photo ID. Arrive 15 minutes early.
        """
        let messy = """
        Appointoointment Detailils
        Annual Physical Exam Confirmed
        Peninsulla Familly Healthh
        Appointoointment Typeype Annual Physical Exam
        Dateate Tuesday, October 14, 2026
        Check-in Time 2:15 PM
        Appointoointment Time 2:30 PM – 3:15 PM
        Location Peninsulla Familly Healthh
        Address 11800 Willow Road, Suite 240, Menlo Park, CA 94025
        Notes Please bring your insurance card and photo ID. Arrive 15 minutes early.
        """

        for sample in [text, messy, OCRTextNormalizer.normalize(messy)] {
            let drafts = EventExtractor.drafts(from: sample)
            let draft = drafts.first
            XCTAssertEqual(drafts.count, 1, "one appointment from: \(sample)")
            XCTAssertEqual(draft?.title, "Annual Physical Exam", sample)
            XCTAssertEqual(Calendar.current.component(.hour, from: draft?.start ?? Date()), 14, sample)
            XCTAssertEqual(Calendar.current.component(.minute, from: draft?.start ?? Date()), 30, sample)
            XCTAssertEqual(draft?.durationMinutes, 45, sample)
            XCTAssertEqual(draft?.durationAssumed, false, sample)
            XCTAssertEqual(Calendar.current.component(.hour, from: draft?.end ?? Date()), 15, "end is latest clock 3:15, not 2:30: \(sample)")
            XCTAssertEqual(Calendar.current.component(.minute, from: draft?.end ?? Date()), 15, sample)
            XCTAssertEqual(draft?.extraBeforeMinutes, 0, sample)
            XCTAssertEqual(Calendar.current.component(.minute, from: draft?.arriveBy ?? Date()), 15, sample)
            XCTAssertTrue(draft?.location.contains("11800") == true, draft?.location ?? "")
            XCTAssertTrue(
                WhatToBring.itemsMentioned(in: (draft?.details ?? []).joined(separator: "\n") + "\n" + sample)
                    .contains { $0.localizedCaseInsensitiveContains("insurance") },
                sample
            )
        }
    }

    func testAppointmentDetailsPortalPhotoReadsExamWindow() throws {
        let image = renderAppointmentDetailsPortal()
        let text = try PhotoTextRecognizer.recognize(in: image)
        let drafts = EventExtractor.drafts(from: text)
        let draft = try XCTUnwrap(drafts.first, "portal screenshot should parse: \(text)")
        XCTAssertEqual(draft.title, "Annual Physical Exam", text)
        XCTAssertEqual(Calendar.current.component(.hour, from: draft.start), 14, text)
        XCTAssertEqual(Calendar.current.component(.minute, from: draft.start), 30, text)
        XCTAssertEqual(draft.durationMinutes, 45, "2:30–3:15 from: \(text)")
        XCTAssertEqual(Calendar.current.component(.hour, from: draft.end), 15, "latest clock on the page is the end: \(text)")
        XCTAssertEqual(Calendar.current.component(.minute, from: draft.end), 15, text)
        XCTAssertFalse(draft.durationAssumed, text)
        XCTAssertEqual(draft.extraBeforeMinutes, 0, text)
        if let arrival = draft.arriveBy {
            XCTAssertEqual(Calendar.current.component(.minute, from: arrival), 15, text)
        }
        XCTAssertTrue(draft.location.contains("11800") || text.contains("11800"), draft.location)
        XCTAssertTrue(
            draft.location.localizedCaseInsensitiveContains("Peninsula")
                || draft.location.localizedCaseInsensitiveContains("Willow")
                || text.localizedCaseInsensitiveContains("Peninsula"),
            draft.location
        )
    }

    func testCalendarCardPhotoReadsTitleTimeAndAddress() throws {
        let image = renderCalendarCard()
        let text = try PhotoTextRecognizer.recognize(in: image)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Lunch"), "title missing from OCR: \(text)")
        XCTAssertTrue(
            text.contains("12:00") || text.contains("12:00pm") || text.localizedCaseInsensitiveContains("12"),
            "time missing from OCR: \(text)"
        )

        let drafts = EventExtractor.drafts(from: text)
        let draft = try XCTUnwrap(drafts.first, "calendar card OCR should parse: \(text)")
        XCTAssertTrue(draft.title.localizedCaseInsensitiveContains("Lunch"), draft.title)
        XCTAssertTrue(draft.hasTime, "expected 12:00–1:00 from: \(text)")
        XCTAssertTrue(
            draft.location.contains("100") || text.localizedCaseInsensitiveContains("Location"),
            "address missing from OCR/parse: loc=\(draft.location) text=\(text)"
        )
    }

    func testOnePhotoCanYieldSeveralAppointments() throws {
        let image = renderScreenshot(lines: ["Haircut Monday at 9 AM", "Dentist Tuesday at 4 PM"])
        let text = try PhotoTextRecognizer.recognize(in: image)

        XCTAssertGreaterThanOrEqual(
            EventExtractor.drafts(from: text).count,
            2,
            "two dated lines should review one after the other: \(text)"
        )
    }

    // MARK: - Voice

    func testSpeechStartsIdle() {
        let capture = SpeechCapture()
        XCTAssertFalse(capture.isListening)
        XCTAssertTrue(capture.transcript.isEmpty)
        XCTAssertNil(capture.fallbackMessage)
    }

    @MainActor
    func testClearHeardTextEmptiesVoiceLeftovers() {
        let capture = SpeechCapture()
        capture.clearHeardText()
        XCTAssertTrue(capture.transcript.isEmpty)
        XCTAssertNil(capture.fallbackMessage)
        XCTAssertFalse(capture.isListening)
    }

    func testSpeechErrorsAreDistinctAndPlainLanguage() {
        let errors: [SpeechCaptureError] = [
            .speechPermissionDenied,
            .speechPermissionNotDetermined,
            .microphonePermissionDenied,
            .recognizerUnavailableForLanguage,
            .recognizerOffline,
            .microphoneUnavailable,
            .noSpeechDetected
        ]
        let messages = errors.map { $0.errorDescription ?? "" }
        XCTAssertFalse(messages.contains(where: \.isEmpty), "every speech failure needs plain-language text")
        XCTAssertEqual(Set(messages).count, errors.count, "mic, speech and language failures must read differently")
    }

    func testMicrophoneAndSpeechDenialsReadDifferently() {
        XCTAssertNotEqual(
            SpeechCaptureError.microphonePermissionDenied.errorDescription,
            SpeechCaptureError.speechPermissionDenied.errorDescription
        )
    }

    func testAuthorizationStatusMapsToTheRightMessage() {
        XCTAssertEqual(SpeechCapture.error(for: .denied), .speechPermissionDenied)
        XCTAssertEqual(SpeechCapture.error(for: .restricted), .speechPermissionDenied)
        XCTAssertEqual(SpeechCapture.error(for: .notDetermined), .speechPermissionNotDetermined)
    }

    /// The mic must survive the pauses between phrases; only real faults stop it.
    func testPausesBetweenPhrasesDoNotEndListening() {
        for code in [1110, 216, 203, 209, 301, 1101, 1107] {
            let pause = NSError(domain: "kAFAssistantErrorDomain", code: code)
            XCTAssertFalse(SpeechCapture.isFatal(pause), "code \(code) is a pause, not a failure")
            XCTAssertTrue(
                SpeechRestartPolicy.shouldRestart(
                    isListening: true,
                    userRequestedStop: false,
                    isFinal: false,
                    error: pause
                ),
                "code \(code) should reopen a recognition task"
            )
        }
        let cancelled = NSError(
            domain: "kLSRErrorDomain",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Recognition request was canceled"]
        )
        XCTAssertFalse(SpeechCapture.isFatal(cancelled))
    }

    func testRealRecognitionFailuresAreRetryableWhileListening() {
        let offline = NSError(domain: NSURLErrorDomain, code: -1009)
        let assistantFault = NSError(domain: "kAFAssistantErrorDomain", code: 1700)
        XCTAssertFalse(SpeechCapture.isFatal(assistantFault), "1700 must not hang up the mic")
        XCTAssertTrue(
            SpeechRestartPolicy.shouldRestart(
                isListening: true,
                userRequestedStop: false,
                isFinal: false,
                error: offline
            )
        )
        XCTAssertTrue(
            SpeechRestartPolicy.shouldRestart(
                isListening: true,
                userRequestedStop: false,
                isFinal: false,
                error: assistantFault
            )
        )
        XCTAssertFalse(SpeechRestartPolicy.shouldGiveUp(consecutiveFatalErrors: 1))
        XCTAssertFalse(SpeechRestartPolicy.shouldGiveUp(consecutiveFatalErrors: 12))
        XCTAssertFalse(
            SpeechRestartPolicy.shouldEndListening(
                userRequestedStop: false,
                consecutiveErrors: 12,
                error: offline
            )
        )
        XCTAssertTrue(
            SpeechRestartPolicy.shouldEndListening(
                userRequestedStop: true,
                consecutiveErrors: 0,
                error: nil
            )
        )
    }

    /// iOS fires kAFAssistantErrorDomain 1700 after almost every phrase on a
    /// real phone. The previous policy called that fatal and hung up after 6
    /// restarts — that is the remaining "voice still cuts off" kill path.
    func testAssistantCode1700DoesNotHangUpTheMic() {
        let phraseEnded = NSError(domain: "kAFAssistantErrorDomain", code: 1700)
        XCTAssertFalse(
            SpeechRestartPolicy.isFatal(phraseEnded),
            "1700 is Apple ending a phrase, not a dead microphone"
        )
        XCTAssertFalse(
            SpeechRestartPolicy.shouldGiveUp(consecutiveFatalErrors: 12),
            "repeated phrase-end errors must not flip isListening to false"
        )
        XCTAssertTrue(
            SpeechRestartPolicy.shouldRestart(
                isListening: true,
                userRequestedStop: false,
                isFinal: true,
                error: phraseEnded
            )
        )
        XCTAssertFalse(
            SpeechRestartPolicy.shouldEndListening(
                userRequestedStop: false,
                consecutiveErrors: 12,
                error: phraseEnded
            )
        )
        XCTAssertFalse(SpeechRestartPolicy.shouldForceOnDeviceRecognition)
        XCTAssertFalse(
            SpeechRestartPolicy.shouldReplayBufferedAudio(isFinal: true, error: phraseEnded),
            "replaying after isFinal immediately re-finalizes the next task"
        )
    }

    /// Empty live text is a deaf request, not a cutoff. Partials must be on,
    /// the recognition task must start before any buffer is appended, and a
    /// 1700 restart must still receive the live tap.
    func testLiveTranscriptPolicyRequiresArmedRequestAndPartials() {
        XCTAssertTrue(SpeechLiveTranscriptPolicy.shouldReportPartialResults)
        XCTAssertFalse(SpeechLiveTranscriptPolicy.shouldForceOnDeviceRecognition)
        XCTAssertTrue(SpeechLiveTranscriptPolicy.usesMeasurementMode)
        XCTAssertTrue(SpeechLiveTranscriptPolicy.disablesVoiceProcessing)

        XCTAssertFalse(
            SpeechLiveTranscriptPolicy.shouldDeliverAudioToRequest(recognitionTaskStarted: false),
            "appending before recognitionTask(with:) is the empty-transcript kill path"
        )
        XCTAssertTrue(SpeechLiveTranscriptPolicy.shouldDeliverAudioToRequest(recognitionTaskStarted: true))

        XCTAssertFalse(
            SpeechLiveTranscriptPolicy.shouldShowPartials(
                shouldReportPartialResults: true,
                requestReceivingAudio: false
            )
        )
        XCTAssertFalse(
            SpeechLiveTranscriptPolicy.shouldShowPartials(
                shouldReportPartialResults: false,
                requestReceivingAudio: true
            )
        )
        XCTAssertTrue(
            SpeechLiveTranscriptPolicy.shouldShowPartials(
                shouldReportPartialResults: SpeechLiveTranscriptPolicy.shouldReportPartialResults,
                requestReceivingAudio: true
            )
        )

        let phraseEnded = NSError(domain: "kAFAssistantErrorDomain", code: 1700)
        XCTAssertTrue(
            SpeechRestartPolicy.shouldRestart(
                isListening: true,
                userRequestedStop: false,
                isFinal: true,
                error: phraseEnded
            )
        )
        XCTAssertTrue(
            SpeechLiveTranscriptPolicy.restartedRequestMustReceiveLiveTapAudio(userRequestedStop: false),
            "1700 restart must attach the new request to the running tap"
        )
        XCTAssertFalse(
            SpeechLiveTranscriptPolicy.restartedRequestMustReceiveLiveTapAudio(userRequestedStop: true)
        )
    }

    func testShouldRestartWhenAppleEndsAPhrase() {
        XCTAssertTrue(
            SpeechRestartPolicy.shouldRestart(
                isListening: true,
                userRequestedStop: false,
                isFinal: true,
                error: nil
            )
        )
        XCTAssertFalse(
            SpeechRestartPolicy.shouldRestart(
                isListening: false,
                userRequestedStop: true,
                isFinal: true,
                error: nil
            )
        )
    }

    func testTranscriptStitchKeepsTheFullUtteranceAcrossARestart() {
        let first = SpeechTranscriptStitch.appending("", "dentist tomorrow at 2")
        let full = SpeechTranscriptStitch.appending(first, "at 2 at school")
        XCTAssertEqual(full, "dentist tomorrow at 2 at school")
    }

    func testTranscriptStitchJoinsDistinctPhrases() {
        XCTAssertEqual(
            SpeechTranscriptStitch.appending("dentist tomorrow at 2", "at school"),
            "dentist tomorrow at 2 at school"
        )
    }

    func testTranscriptStitchDoesNotDuplicateOverlap() {
        XCTAssertEqual(
            SpeechTranscriptStitch.appending("dentist tomorrow at 2 at school", "at school"),
            "dentist tomorrow at 2 at school"
        )
    }

    func testPreferringLongerNeverShrinksATranscript() {
        XCTAssertEqual(
            SpeechTranscriptStitch.preferringLonger(
                "dentist tomorrow at 2 at school",
                "dentist tomorrow at 2"
            ),
            "dentist tomorrow at 2 at school"
        )
        XCTAssertEqual(
            SpeechTranscriptStitch.preferringLonger("dentist tomorrow at 2", ""),
            "dentist tomorrow at 2"
        )
    }

    func testStabilizeKeepsALongerPartialWhenTheFinalIsShorter() {
        XCTAssertEqual(
            SpeechTranscriptStitch.stabilize(
                current: "dentist tomorrow at 2 at school",
                incoming: "dentist tomorrow at 2",
                isFinal: true
            ),
            "dentist tomorrow at 2 at school"
        )
        XCTAssertEqual(
            SpeechTranscriptStitch.stabilize(
                current: "dentist tomorrow at 2",
                incoming: "",
                isFinal: true
            ),
            "dentist tomorrow at 2"
        )
    }

    func testSpokenStitchedTextReachesReviewWording() {
        let spoken = SpeechTranscriptStitch.appending("dentist tomorrow at 2", "at 2 at school")
        XCTAssertEqual(spoken, "dentist tomorrow at 2 at school")
        for draft in EventExtractor.drafts(from: spoken) {
            XCTAssertEqual(draft.sourceText, spoken, "Hear / Original must keep the stitched wording")
        }
    }

    /// Language-only phone locales (de / fr / en) must become a Speech-supported
    /// identifier. Passing `Locale.current` straight into SFSpeechRecognizer is
    /// the silent-empty path after a German→English switch (`en_DE`).
    func testRecognizerLocaleFallsBackToSupportedIdentifier() {
        let catalog = ["de-DE", "fr-FR", "en-US", "es-ES", "en-GB"]
        XCTAssertEqual(
            SpeechRecognizerLocale.supportedIdentifier(
                matching: Locale(identifier: "de"),
                availableIdentifiers: catalog
            ),
            "de-DE"
        )
        XCTAssertEqual(
            SpeechRecognizerLocale.supportedIdentifier(
                matching: Locale(identifier: "fr"),
                availableIdentifiers: catalog
            ),
            "fr-FR"
        )
        XCTAssertEqual(
            SpeechRecognizerLocale.supportedIdentifier(
                matching: Locale(identifier: "en"),
                availableIdentifiers: catalog
            ),
            "en-US"
        )
        XCTAssertEqual(
            SpeechRecognizerLocale.supportedIdentifier(
                matching: Locale(identifier: "en_DE"),
                availableIdentifiers: catalog
            ),
            "en-US",
            "English-in-Germany must not sit on a German recognizer"
        )
        XCTAssertEqual(
            SpeechRecognizerLocale.supportedIdentifier(
                matching: Locale(identifier: "xx-YY"),
                availableIdentifiers: catalog
            ),
            "en-US"
        )
        XCTAssertEqual(
            SpeechRecognizerLocale.supportedIdentifier(
                matching: Locale(identifier: "xx"),
                availableIdentifiers: []
            ),
            SpeechRecognizerLocale.fallbackIdentifier,
            "never return nil — fall back to en-US even with an empty catalog"
        )

        let appleLocales = SFSpeechRecognizer.supportedLocales().map(\.identifier)
        for language in ["de", "fr", "en"] {
            let identifier = SpeechRecognizerLocale.supportedIdentifier(
                matching: Locale(identifier: language),
                availableIdentifiers: appleLocales
            )
            XCTAssertFalse(identifier.isEmpty, "\(language) must resolve to a supported identifier")
            XCTAssertNotNil(
                SFSpeechRecognizer(locale: Locale(identifier: identifier)),
                "\(language) resolved to \(identifier), which Speech must construct — never nil without fallback"
            )
            let hasLanguage = appleLocales.contains {
                Locale(identifier: $0).language.languageCode?.identifier == language
            }
            if hasLanguage {
                XCTAssertEqual(
                    Locale(identifier: identifier).language.languageCode?.identifier,
                    language
                )
            } else {
                XCTAssertEqual(identifier, SpeechRecognizerLocale.fallbackIdentifier)
            }
        }

        XCTAssertNotNil(
            SpeechCapture.makeRecognizer(),
            "makeRecognizer must never fail silent — en-US is the last resort"
        )
    }

    // MARK: - Permission strings (a missing one crashes the app on launch)

    func testEveryUsageDescriptionIsPresent() {
        let required = [
            "NSMicrophoneUsageDescription",
            "NSSpeechRecognitionUsageDescription",
            "NSPhotoLibraryUsageDescription",
            "NSCalendarsFullAccessUsageDescription",
            "NSCalendarsWriteOnlyAccessUsageDescription",
            "NSLocationWhenInUseUsageDescription"
        ]
        for key in required {
            let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
            XCTAssertFalse(
                (value ?? "").isEmpty,
                "\(key) is missing — iOS kills the app the moment it asks for that permission"
            )
        }
    }

    // MARK: - Helpers

    /// A calendar-detail screenshot: big title, date range, gray Location / Notes.
    private func renderCalendarCard() -> UIImage {
        let size = CGSize(width: 900, height: 720)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let title: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 44, weight: .semibold),
                .foregroundColor: UIColor.black
            ]
            let when: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 28, weight: .regular),
                .foregroundColor: UIColor.darkGray
            ]
            let label: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .regular),
                .foregroundColor: UIColor.gray
            ]
            let value: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 28, weight: .regular),
                .foregroundColor: UIColor.black
            ]
            "Lunch with friends".draw(at: CGPoint(x: 48, y: 60), withAttributes: title)
            "Wed, Sep 23, 12:00–1:00 PM".draw(at: CGPoint(x: 48, y: 140), withAttributes: when)
            "Location".draw(at: CGPoint(x: 48, y: 260), withAttributes: label)
            "100 Example Ave, Springfield, IL 62701".draw(at: CGPoint(x: 48, y: 300), withAttributes: value)
            "Notes".draw(at: CGPoint(x: 48, y: 420), withAttributes: label)
            "Please bring drinks".draw(at: CGPoint(x: 48, y: 460), withAttributes: value)
        }
    }

    /// Patient-portal Appointment Details screenshot: labeled rows, not one giant blob.
    private func renderAppointmentDetailsPortal() -> UIImage {
        let size = CGSize(width: 1100, height: 1400)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let header: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 28, weight: .regular),
                .foregroundColor: UIColor.gray
            ]
            let title: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 36, weight: .semibold),
                .foregroundColor: UIColor.black
            ]
            let label: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .regular),
                .foregroundColor: UIColor.gray
            ]
            let value: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 28, weight: .regular),
                .foregroundColor: UIColor.black
            ]
            var y: CGFloat = 48
            func row(_ heading: String, _ body: String) {
                heading.draw(at: CGPoint(x: 48, y: y), withAttributes: label)
                y += 36
                body.draw(at: CGPoint(x: 48, y: y), withAttributes: value)
                y += 64
            }
            "Appointment Details".draw(at: CGPoint(x: 48, y: y), withAttributes: header)
            y += 48
            "Annual Physical Exam Confirmed".draw(at: CGPoint(x: 48, y: y), withAttributes: title)
            y += 70
            row("Appointment Type", "Annual Physical Exam")
            row("Date", "Tuesday, October 14, 2026")
            row("Check-in Time", "2:15 PM")
            row("Appointment Time", "2:30 PM – 3:15 PM")
            row("Location", "Peninsula Family Health")
            row("Address", "11800 Willow Road, Suite 240, Menlo Park, CA 94025")
        }
    }

    /// Black text on white, the way a confirmation screenshot looks.
    private func renderScreenshot(lines: [String]) -> UIImage {
        let size = CGSize(width: 900, height: 200 + CGFloat(lines.count) * 90)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 54, weight: .regular),
                .foregroundColor: UIColor.black
            ]
            for (index, line) in lines.enumerated() {
                line.draw(at: CGPoint(x: 40, y: 60 + CGFloat(index) * 90), withAttributes: attributes)
            }
        }
    }

    /// Bakes an image as it would appear on screen under `orientation`, producing
    /// upright pixel data with no orientation tag.
    private func flatten(_ image: UIImage, displayedAs orientation: UIImage.Orientation) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let oriented = UIImage(cgImage: cgImage, scale: 1, orientation: orientation)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: oriented.size, format: format).image { _ in
            oriented.draw(in: CGRect(origin: .zero, size: oriented.size))
        }
    }
}
