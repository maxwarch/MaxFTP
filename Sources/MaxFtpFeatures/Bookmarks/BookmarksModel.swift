import Foundation
import MaxFtpCore
import Observation

/// Liste des favoris + accès à leurs secrets. Source de vérité unique pour toutes les fenêtres.
@MainActor
@Observable
public final class BookmarksModel {
    public private(set) var bookmarks: [ServerBookmark] = []
    public var errorMessage: String?

    private let repository: any BookmarkRepository
    private let secretStore: any SecretStore

    public init(repository: any BookmarkRepository, secretStore: any SecretStore) {
        self.repository = repository
        self.secretStore = secretStore
        do {
            bookmarks = try repository.loadBookmarks()
        } catch {
            errorMessage = "Impossible de lire les favoris : \(error.localizedDescription)"
        }
    }

    /// Crée ou met à jour un favori.
    /// - Parameter secret: `nil` = inchangé, chaîne vide = supprimé du Keychain.
    public func save(_ bookmark: ServerBookmark, secret: String?) {
        if let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[index] = bookmark
        } else {
            bookmarks.append(bookmark)
        }
        perform {
            if let secret {
                if secret.isEmpty {
                    try secretStore.removeSecret(for: bookmark.secretAccount)
                } else {
                    try secretStore.setSecret(secret, for: bookmark.secretAccount)
                }
            }
            try repository.saveBookmarks(bookmarks)
        }
    }

    /// Enregistre une connexion (rapide) en favori, sous ce nom, avec son secret.
    @discardableResult
    public func addFavorite(from configuration: ConnectionConfiguration, name: String) -> ServerBookmark {
        let (bookmark, secret) = ServerBookmark.from(configuration, name: name.trimmingCharacters(in: .whitespaces))
        save(bookmark, secret: secret)
        return bookmark
    }

    /// Favori visant ce serveur, s'il existe.
    public func bookmark(forServerKey serverKey: String) -> ServerBookmark? {
        bookmarks.first { $0.serverKey == serverKey }
    }

    public func delete(_ bookmark: ServerBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        perform {
            try secretStore.removeSecret(for: bookmark.secretAccount)
            try repository.saveBookmarks(bookmarks)
        }
    }

    public func duplicate(_ bookmark: ServerBookmark) {
        var copy = bookmark
        copy.id = UUID()
        copy.name = bookmark.displayName + " (copie)"
        save(copy, secret: secret(for: bookmark))
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        bookmarks.move(fromOffsets: source, toOffset: destination)
        perform { try repository.saveBookmarks(bookmarks) }
    }

    public func secret(for bookmark: ServerBookmark) -> String? {
        try? secretStore.secret(for: bookmark.secretAccount)
    }

    public func configuration(for bookmark: ServerBookmark) -> ConnectionConfiguration {
        bookmark.configuration(secret: secret(for: bookmark))
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
