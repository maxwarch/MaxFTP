import Foundation
import MaxFtpCore

/// Signets stockés dans `~/Library/Application Support/MaxFtp/path-bookmarks.json`.
///
/// Fichier distinct de `bookmarks.json` : les signets suivent le serveur (et donc
/// aussi la connexion rapide), pas le favori. Voir ADR 0006.
public struct JSONPathBookmarkRepository: PathBookmarkRepository {
    struct Document: Codable, Sendable {
        static let currentVersion = 1
        var schemaVersion = currentVersion
        var servers: [String: [PathBookmark]]
    }

    private let store: JSONFileStore<Document>

    public init(fileURL: URL = AppDirectories.applicationSupport.appendingPathComponent("path-bookmarks.json")) {
        self.store = JSONFileStore(fileURL: fileURL)
    }

    public func loadPathBookmarks() throws -> [String: [PathBookmark]] {
        try store.read()?.servers ?? [:]
    }

    public func savePathBookmarks(_ bookmarks: [String: [PathBookmark]]) throws {
        try store.write(Document(servers: bookmarks))
    }
}
