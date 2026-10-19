import Foundation
import UIKit

/// Writes the captured screenshot to Application Support so Review and a later
/// "View original" can open the photo — not the OCR — after Confirm.
enum OriginalImageStore {
    private static let folderName = "ScedraOriginals"
    private static let mapKey = "scedra.originalImageByEventID"

    static func save(_ image: UIImage) -> URL? {
        guard let directory = directoryURL() else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let encoded = encoded(image) else { return nil }
        let url = directory.appendingPathComponent("\(UUID().uuidString).\(encoded.ext)")
        do {
            try encoded.data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Keep the Review file under the EventKit identifier so appointment details
    /// can show the same photo after the draft is gone.
    static func remember(_ url: URL, for eventID: String) {
        guard !eventID.isEmpty else { return }
        guard let directory = directoryURL() else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let filename: String
        if isInOriginalsFolder(url, directory: directory) {
            filename = url.lastPathComponent
        } else {
            let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            filename = "\(UUID().uuidString).\(ext)"
            let destination = directory.appendingPathComponent(filename)
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                return
            }
        }

        var map = filenames()
        if let previous = map[eventID], previous != filename {
            removeFile(named: previous)
        }
        map[eventID] = filename
        UserDefaults.standard.set(map, forKey: mapKey)
    }

    static func imageURL(for eventID: String) -> URL? {
        guard !eventID.isEmpty, let filename = filenames()[eventID], !filename.isEmpty else {
            return nil
        }
        guard let directory = directoryURL() else { return nil }
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func image(for eventID: String) -> UIImage? {
        guard let url = imageURL(for: eventID) else { return nil }
        return image(at: url)
    }

    static func image(at url: URL) -> UIImage? {
        if let image = UIImage(contentsOfFile: url.path) {
            return image
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func forget(_ eventID: String) {
        guard !eventID.isEmpty else { return }
        var map = filenames()
        if let filename = map.removeValue(forKey: eventID) {
            removeFile(named: filename)
        }
        UserDefaults.standard.set(map, forKey: mapKey)
    }

    private static func encoded(_ image: UIImage) -> (data: Data, ext: String)? {
        let flattened = rasterized(image)
        if let jpeg = flattened.jpegData(compressionQuality: 0.88) {
            return (jpeg, "jpg")
        }
        if let png = flattened.pngData() {
            return (png, "png")
        }
        return nil
    }

    /// Bake orientation into pixels so a later `UIImage(contentsOfFile:)` still
    /// matches what she captured (Photo library images often carry an EXIF flag).
    private static func rasterized(_ image: UIImage) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale > 0 ? image.scale : 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func filenames() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: mapKey) as? [String: String] ?? [:]
    }

    private static func removeFile(named filename: String) {
        guard !filename.isEmpty, let directory = directoryURL() else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
    }

    private static func isInOriginalsFolder(_ url: URL, directory: URL) -> Bool {
        let folder = directory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
            || url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
    }

    private static func directoryURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(folderName, isDirectory: true)
    }
}

/// Review / appointment details: the photo when she scanned one, otherwise the wording.
enum ReviewOriginal: Equatable {
    case photo(URL)
    case text(String)

    static func attaching(imageURL: URL?, to drafts: [DraftEvent]) -> [DraftEvent] {
        drafts.map { draft in
            var next = draft
            next.originalImageURL = imageURL
            return next
        }
    }

    static func presentation(for draft: DraftEvent) -> ReviewOriginal {
        if let url = draft.originalImageURL, OriginalImageStore.image(at: url) != nil {
            return .photo(url)
        }
        return .text(draft.sourceText)
    }

    static func presentation(for item: TodayItem) -> ReviewOriginal? {
        if let url = OriginalTextStore.imageURL(for: item.id), OriginalImageStore.image(at: url) != nil {
            return .photo(url)
        }
        if let text = item.originalText, !text.isEmpty {
            return .text(text)
        }
        return nil
    }
}
