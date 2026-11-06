import Foundation

/// Petits utilitaires d'E/S locales partagés par les adaptateurs réseau.
public enum LocalFileIO {
    /// Taille des blocs lus sur disque pour les uploads.
    public static let chunkSize = 256 * 1024

    /// Crée (ou tronque) le fichier de destination et renvoie un handle en écriture.
    public static func createFileForWriting(at url: URL) throws -> FileHandle {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw RemoteError.localFileError("Création impossible : \(url.path)")
            }
            return try FileHandle(forWritingTo: url)
        } catch let error as RemoteError {
            throw error
        } catch {
            throw RemoteError.localFileError(error.localizedDescription)
        }
    }

    public static func openForReading(_ url: URL) throws -> FileHandle {
        do {
            return try FileHandle(forReadingFrom: url)
        } catch {
            throw RemoteError.localFileError(error.localizedDescription)
        }
    }

    /// Renvoie `url` si libre, sinon `nom 2.ext`, `nom 3.ext`… (comme le Finder).
    public static func uniqueURL(for url: URL, fileManager: FileManager = .default) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for index in 2... {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}
