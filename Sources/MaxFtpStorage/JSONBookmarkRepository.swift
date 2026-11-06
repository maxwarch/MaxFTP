import Foundation
import MaxFtpCore

/// Favoris stockés dans `~/Library/Application Support/MaxFtp/bookmarks.json`.
///
/// Le fichier est versionné (`schemaVersion`) pour permettre de futures migrations.
/// Pour passer à SwiftData, il suffit d'écrire une autre implémentation de
/// ``BookmarkRepository`` et de la brancher dans `AppComposition`.
public struct JSONBookmarkRepository: BookmarkRepository {
    struct Document: Codable, Sendable {
        static let currentVersion = 1
        var schemaVersion = currentVersion
        var bookmarks: [ServerBookmark]
    }

    private let store: JSONFileStore<Document>

    public init(fileURL: URL = AppDirectories.applicationSupport.appendingPathComponent("bookmarks.json")) {
        self.store = JSONFileStore(fileURL: fileURL)
    }

    public func loadBookmarks() throws -> [ServerBookmark] {
        try store.read()?.bookmarks ?? []
    }

    public func saveBookmarks(_ bookmarks: [ServerBookmark]) throws {
        try store.write(Document(bookmarks: bookmarks))
    }
}
