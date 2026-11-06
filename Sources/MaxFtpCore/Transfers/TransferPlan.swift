import Foundation

/// Liste ordonnée d'étapes élémentaires décrivant un transfert (pattern Command).
///
/// Séparer la *planification* (quoi faire) de l'*exécution* (le faire) permet de
/// connaître la taille totale avant de commencer, et de tester la logique de
/// parcours d'arborescence sans réseau.
public struct TransferPlan: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case createRemoteDirectory(RemotePath)
        case createLocalDirectory(URL)
        case upload(URL, to: RemotePath, size: Int64)
        case download(RemotePath, to: URL, size: Int64)

        var byteCount: Int64 {
            switch self {
            case .upload(_, _, let size), .download(_, _, let size): size
            case .createRemoteDirectory, .createLocalDirectory: 0
            }
        }
    }

    public var steps: [Step]

    public init(steps: [Step]) {
        self.steps = steps
    }

    public var totalBytes: Int64 { steps.reduce(0) { $0 + $1.byteCount } }
    public var fileCount: Int { steps.filter(\.isFileTransfer).count }
}

extension TransferPlan.Step {
    var isFileTransfer: Bool {
        switch self {
        case .upload, .download: true
        case .createRemoteDirectory, .createLocalDirectory: false
        }
    }
}

public enum TransferPlanner {
    /// Upload d'un fichier ou d'un dossier local (récursif) dans `remoteDirectory`.
    public static func uploadPlan(
        for localURL: URL,
        into remoteDirectory: RemotePath,
        fileManager: FileManager = .default
    ) throws -> TransferPlan {
        let destination = remoteDirectory.appending(localURL.lastPathComponent)
        let values = try localURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])

        guard values.isDirectory == true else {
            return TransferPlan(steps: [.upload(localURL, to: destination, size: Int64(values.fileSize ?? 0))])
        }

        var steps: [TransferPlan.Step] = [.createRemoteDirectory(destination)]
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: localURL, includingPropertiesForKeys: keys) else {
            throw RemoteError.localFileError("Impossible de parcourir \(localURL.path)")
        }
        let basePath = localURL.standardizedFileURL.path
        for case let url as URL in enumerator {
            let relative = String(url.standardizedFileURL.path.dropFirst(basePath.count))
            let remote = destination.appending(relative)
            let child = try url.resourceValues(forKeys: Set(keys))
            if child.isDirectory == true {
                steps.append(.createRemoteDirectory(remote))
            } else {
                steps.append(.upload(url, to: remote, size: Int64(child.fileSize ?? 0)))
            }
        }
        return TransferPlan(steps: steps)
    }

    /// Téléchargement d'un élément distant (récursif pour un dossier) vers `destination`
    /// (chemin local complet du fichier ou du dossier à créer).
    public static func downloadPlan(
        for item: RemoteItem,
        to destination: URL,
        using fileSystem: any RemoteFileSystem
    ) async throws -> TransferPlan {
        guard item.isDirectory else {
            return TransferPlan(steps: [.download(item.path, to: destination, size: item.size ?? 0)])
        }

        var steps: [TransferPlan.Step] = [.createLocalDirectory(destination)]
        for child in try await fileSystem.walk(item.path) {
            let relative = child.path.components.dropFirst(item.path.components.count).joined(separator: "/")
            let local = destination.appendingPathComponent(relative, isDirectory: child.isDirectory)
            if child.isDirectory {
                steps.append(.createLocalDirectory(local))
            } else if child.kind == .file {
                steps.append(.download(child.path, to: local, size: child.size ?? 0))
            }
        }
        return TransferPlan(steps: steps)
    }
}
