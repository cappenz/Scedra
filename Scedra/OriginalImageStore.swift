import Foundation
import UIKit

/// Writes the captured screenshot to Caches so Review can open it after she
/// leaves the Capture card, without keeping a UIImage on every draft.
enum OriginalImageStore {
    private static let folderName = "ScedraOriginals"

    static func save(_ image: UIImage) -> URL? {
        guard let directory = directoryURL() else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).jpg")
        guard let data = image.jpegData(compressionQuality: 0.88) ?? image.pngData() else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    static func image(at url: URL) -> UIImage? {
        UIImage(contentsOfFile: url.path)
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func directoryURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(folderName, isDirectory: true)
    }
}

/// Review's View original: the photo when she scanned one, otherwise the wording.
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
}
