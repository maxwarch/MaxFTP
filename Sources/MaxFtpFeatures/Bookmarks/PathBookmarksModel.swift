import Foundation
import MaxFtpCore
import Observation

/// Signets (dossiers / fichiers) de chaque serveur. Partagé par toutes les fenêtres.
@MainActor
@Observable
public final class PathBookmarksModel {
    public private(set) var bookmarksByServer: [String: [PathBookmark]] = [:]
    public var errorMessage: String?

    private let repository: any PathBookmarkRepository

    public init(repository: any PathBookmarkRepository) {
        self.repository = repository
        do {
            bookmarksByServer = try repository.loadPathBookmarks()
        } catch {
            errorMessage = "Impossible de lire les signets : \(error.localizedDescription)"
        }
    }

    public func bookmarks(for serverKey: String) -> [PathBookmark] {
        bookmarksByServer[serverKey] ?? []
    }

    public func bookmark(for path: RemotePath, on serverKey: String) -> PathBookmark? {
        bookmarks(for: serverKey).first { $0.path == path }
    }

    /// Ajoute un signet ; sans effet si ce chemin en a déjà un.
    public func add(_ path: RemotePath, isDirectory: Bool, on serverKey: String) {
        guard bookmark(for: path, on: serverKey) == nil else { return }
        bookmarksByServer[serverKey, default: []].append(PathBookmark(path: path, isDirectory: isDirectory))
        persist()
    }

    public func remove(_ bookmark: PathBookmark, on serverKey: String) {
        bookmarksByServer[serverKey]?.removeAll { $0.id == bookmark.id }
        if bookmarksByServer[serverKey]?.isEmpty == true {
            bookmarksByServer[serverKey] = nil
        }
        persist()
    }

    /// Ajoute le signet s'il n'existe pas, le retire sinon (bouton étoile).
    public func toggle(_ path: RemotePath, isDirectory: Bool, on serverKey: String) {
        if let existing = bookmark(for: path, on: serverKey) {
            remove(existing, on: serverKey)
        } else {
            add(path, isDirectory: isDirectory, on: serverKey)
        }
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int, on serverKey: String) {
        bookmarksByServer[serverKey]?.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func persist() {
        do {
            try repository.savePathBookmarks(bookmarksByServer)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
