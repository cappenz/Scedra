import CoreTransferable
import UIKit
import UniformTypeIdentifiers
import Vision

nonisolated enum PhotoTextError: LocalizedError, Equatable {
    case unreadableImage
    case recognitionFailed
    case noTextFound

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            ScedraString("Couldn’t open that photo. Pick another, or type it.")
        case .recognitionFailed:
            ScedraString("Couldn’t read that photo. Try a clearer shot, or type it.")
        case .noTextFound:
            ScedraString("No text in that photo. Try a clearer shot, or type it.")
        }
    }
}

nonisolated enum PhotoTextRecognizer {
    /// Reads text out of a photo or screenshot. Vision runs entirely on device —
    /// the image never leaves the phone.
    static func recognize(in image: UIImage) throws -> String {
        guard let cgImage = image.cgImage ?? image.ciImage.flatMap(cgImage(from:)) else {
            throw PhotoTextError.unreadableImage
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = preferredRecognitionLanguages(for: request)
        request.customWords = [
            "Location", "Notes", "When", "Where", "AM", "PM",
            "Ave", "Avenue", "Street", "Blvd", "Road", "Suite",
            "Appointment", "Type", "Check-in", "Patient", "Provider",
            "Confirmed", "Address", "Parking",
            "Appointment Type", "Appointment Time", "Check-in Time",
            "Annual", "Physical", "Exam", "Peninsula", "Willow", "Menlo",
            "Saturday", "Daily", "Grind", "Denver", "Elm", "coffee", "weekend"
        ]
        if #available(iOS 16.0, *) {
            request.automaticallyDetectsLanguage = true
        }

        // A photo taken in portrait stores a sideways CGImage; without this the
        // text is rotated and Vision finds nothing.
        func read(_ pixels: CGImage, orientation: CGImagePropertyOrientation) throws -> String {
            let pass = VNRecognizeTextRequest()
            pass.recognitionLevel = request.recognitionLevel
            pass.usesLanguageCorrection = request.usesLanguageCorrection
            pass.recognitionLanguages = request.recognitionLanguages
            pass.customWords = request.customWords
            if #available(iOS 16.0, *) {
                pass.automaticallyDetectsLanguage = request.automaticallyDetectsLanguage
            }
            let handler = VNImageRequestHandler(
                cgImage: pixels,
                orientation: orientation,
                options: [:]
            )
            do {
                try handler.perform([pass])
            } catch {
                throw PhotoTextError.recognitionFailed
            }
            return readingOrderText(from: pass.results ?? [])
        }

        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        var text = (try? read(cgImage, orientation: orientation)) ?? ""
        if isWeakOCR(text), let sharper = sharpened(cgImage) {
            let retry = (try? read(sharper, orientation: orientation)) ?? ""
            if retry.count > text.count { text = retry }
        }
        text = OCRTextNormalizer.readablePhotoTranscript(text)
        guard !text.isEmpty else { throw PhotoTextError.noTextFound }
        return text
    }

    /// Gray "Location" / "Notes" labels on a calendar card are easy to miss.
    private static func isWeakOCR(_ text: String) -> Bool {
        let lines = text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if lines.count < 3 { return true }
        let folded = text.lowercased()
        return !folded.contains("location") && !folded.contains(where: \.isNumber)
    }

    private static func sharpened(_ image: CGImage) -> CGImage? {
        let ciImage = CIImage(cgImage: image)
        let contrast = ciImage.applyingFilter(
            "CIColorControls",
            parameters: [kCIInputContrastKey: 1.35, kCIInputSaturationKey: 0]
        )
        let sharp = contrast.applyingFilter(
            "CISharpenLuminance",
            parameters: [kCIInputSharpnessKey: 0.6]
        )
        return CIContext().createCGImage(sharp, from: sharp.extent)
    }

    /// Vision is CPU-heavy, so keep it off the main thread while the UI shows a spinner.
    static func recognizeText(in image: UIImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try recognize(in: image)
        }.value
    }

    /// One Vision hit. Tests build these by Y so a blob can be turned back into lines.
    struct RecognizedTextBlock: Equatable {
        var text: String
        var top: CGFloat
        var left: CGFloat
        var height: CGFloat
    }

    /// Screenshots wrap onto many short lines. Rebuild top-to-bottom,
    /// left-to-right reading order so dates and times stay next to their words.
    static func readingOrderText(from observations: [VNRecognizedTextObservation]) -> String {
        readableTranscript(from: observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            // Vision's origin is bottom-left; flip so larger means further down.
            return RecognizedTextBlock(
                text: candidate.string,
                top: 1 - box.maxY,
                left: box.minX,
                height: box.height
            )
        })
    }

    /// Restore vertical order, put distinct Y blocks on their own lines, then
    /// run photo OCR cleanup so Review can show a readable transcript.
    static func readableTranscript(from blocks: [RecognizedTextBlock]) -> String {
        OCRTextNormalizer.readablePhotoTranscript(assembleLines(blocks))
    }

    static func assembleLines(_ blocks: [RecognizedTextBlock]) -> String {
        guard !blocks.isEmpty else { return "" }

        let sorted = blocks.sorted { left, right in
            abs(left.top - right.top) > lineTolerance(left, right) ? left.top < right.top : left.left < right.left
        }

        var lines: [String] = []
        var currentLine: [String] = []
        var previous: RecognizedTextBlock?

        for piece in sorted {
            if let previous, abs(piece.top - previous.top) <= lineTolerance(piece, previous) {
                currentLine.append(piece.text)
            } else {
                if !currentLine.isEmpty { lines.append(currentLine.joined(separator: " ")) }
                currentLine = [piece.text]
            }
            previous = piece
        }
        if !currentLine.isEmpty { lines.append(currentLine.joined(separator: " ")) }

        return lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lineTolerance(_ a: RecognizedTextBlock, _ b: RecognizedTextBlock) -> CGFloat {
        max(min(a.height, b.height) * 0.45, 0.008)
    }

    private static func cgImage(from ciImage: CIImage) -> CGImage? {
        CIContext().createCGImage(ciImage, from: ciImage.extent)
    }

    /// Reads the phone's languages when Vision supports them, so a non-English
    /// screenshot still parses. Event titles are never translated.
    static func preferredRecognitionLanguages(for request: VNRecognizeTextRequest) -> [String] {
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        guard !supported.isEmpty else { return [] }
        let preferred = Locale.preferredLanguages.filter { supported.contains($0) }
        let base = Locale.preferredLanguages
            .compactMap { Locale(identifier: $0).language.languageCode?.identifier }
            .flatMap { code in supported.filter { $0 == code || $0.hasPrefix("\(code)-") } }
        var ordered: [String] = []
        for language in preferred + base + ["en-US"] where supported.contains(language) && !ordered.contains(language) {
            ordered.append(language)
        }
        return ordered
    }
}

/// PhotosPicker's `Data` transferable asks for `public.data`, which a photo
/// item does not vend — that path silently returns nil. This type asks for
/// image bytes (and a file URL for iCloud originals) instead.
nonisolated struct PickedPhoto: Transferable {
    let data: Data

    init(data: Data) throws {
        guard UIImage(data: data) != nil else { throw PhotoTextError.unreadableImage }
        self.data = data
    }

    var image: UIImage {
        UIImage(data: data) ?? UIImage()
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            try PickedPhoto(data: data)
        }
        DataRepresentation(importedContentType: .jpeg) { data in
            try PickedPhoto(data: data)
        }
        DataRepresentation(importedContentType: .png) { data in
            try PickedPhoto(data: data)
        }
        DataRepresentation(importedContentType: .heic) { data in
            try PickedPhoto(data: data)
        }
        FileRepresentation(importedContentType: .image) { received in
            let accessed = received.file.startAccessingSecurityScopedResource()
            defer {
                if accessed { received.file.stopAccessingSecurityScopedResource() }
            }
            return try PickedPhoto(data: Data(contentsOf: received.file))
        }
    }
}

/// PhotosPicker only fires `onChange` when the bound item's identity changes.
/// After we consume a pick the selection must be cleared, or "Choose another
/// photo" — including the same screenshot — is a silent no-op.
nonisolated enum PhotoCapturePolicy {
    struct Session: Equatable {
        var hasPickerItem: Bool
        var hasImage: Bool
        var isReading: Bool
        var sourceText: String
        var error: String?
        var hasDrafts: Bool
        var isPresentingPicker: Bool

        static let empty = Session(
            hasPickerItem: false,
            hasImage: false,
            isReading: false,
            sourceText: "",
            error: nil,
            hasDrafts: false,
            isPresentingPicker: false
        )

        var canCancel: Bool {
            hasPickerItem
                || hasImage
                || isReading
                || hasDrafts
                || error != nil
                || !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Drop the bound item so the next library tap is a new selection event.
    static func sessionAfterConsumingPickerItem(_ session: Session) -> Session {
        var next = session
        next.hasPickerItem = false
        next.isReading = true
        next.error = nil
        next.isPresentingPicker = false
        return next
    }

    /// Open the library again. A leftover item would make a re-pick silent.
    static func sessionPreparingNewPick(_ session: Session) -> Session {
        var next = session
        next.hasPickerItem = false
        next.isPresentingPicker = true
        return next
    }

    /// Stop OCR and return to Capture with no leftover draft.
    static func sessionAfterCancel(_: Session) -> Session {
        .empty
    }

    /// Confirm saved a real calendar event. Drop leftover OCR text and the photo.
    static func sessionAfterSuccessfulSave(_: Session) -> Session {
        .empty
    }

    /// Failed OCR must leave Cancel usable — never a stuck spinner.
    static func sessionAfterFailedRead(_ session: Session, message: String, keepImage: Bool) -> Session {
        var next = session
        next.hasPickerItem = false
        next.isReading = false
        next.hasImage = keepImage ? session.hasImage : false
        next.sourceText = ""
        next.hasDrafts = false
        next.error = message
        next.isPresentingPicker = false
        return next
    }
}

nonisolated extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
