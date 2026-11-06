import Foundation

/// Appelé avec le nombre d'octets transférés depuis le début du fichier courant.
public typealias TransferProgressHandler = @Sendable (Int64) -> Void

/// Contrat central de l'application : un système de fichiers distant.
///
/// Chaque protocole (SFTP, FTP, FTPS…) fournit UN adaptateur conforme, implémenté
/// sous forme d'`actor` pour isoler l'état réseau. Le reste de l'app ne manipule
/// que `any RemoteFileSystem` (pattern Strategy / Ports & Adapters).
///
/// Les adaptateurs n'implémentent que des **primitives** ; les opérations composées
/// (suppression récursive, parcours d'arborescence…) sont écrites une seule fois
/// dans l'extension ci-dessous et profitent à tous les protocoles.
///
/// Règles pour les implémentations :
/// - `connect()` est idempotent ; les autres méthodes se reconnectent si besoin.
/// - Les transferts vérifient `Task.isCancelled` entre deux blocs.
/// - Les erreurs sont traduites en ``RemoteError`` quand c'est pertinent.
public protocol RemoteFileSystem: Actor {
    var configuration: ConnectionConfiguration { get }

    func connect() async throws
    func disconnect() async

    /// Dossier de connexion de l'utilisateur (`PWD` / `realpath(".")`).
    func homeDirectory() async throws -> RemotePath
    func contentsOfDirectory(at path: RemotePath) async throws -> [RemoteItem]

    func createDirectory(at path: RemotePath) async throws
    func removeFile(at path: RemotePath) async throws
    /// Supprime un dossier **vide**. Voir ``removeItem(_:)`` pour le récursif.
    func removeDirectory(at path: RemotePath) async throws
    func moveItem(at source: RemotePath, to destination: RemotePath) async throws
    func setPermissions(_ permissions: POSIXPermissions, at path: RemotePath) async throws

    func download(_ path: RemotePath, to localURL: URL, progress: @escaping TransferProgressHandler) async throws
    func upload(_ localURL: URL, to path: RemotePath, progress: @escaping TransferProgressHandler) async throws
}

// MARK: - Opérations composées (Template Method)

extension RemoteFileSystem {
    /// Supprime un fichier, ou un dossier et tout son contenu.
    public func removeItem(_ item: RemoteItem) async throws {
        guard item.isDirectory else {
            try await removeFile(at: item.path)
            return
        }
        for child in try await contentsOfDirectory(at: item.path) {
            try Task.checkCancellation()
            try await removeItem(child)
        }
        try await removeDirectory(at: item.path)
    }

    /// Liste récursivement tous les éléments sous `path` (dossiers avant leur contenu).
    public func walk(_ path: RemotePath) async throws -> [RemoteItem] {
        var result: [RemoteItem] = []
        for child in try await contentsOfDirectory(at: path) {
            try Task.checkCancellation()
            result.append(child)
            if child.isDirectory {
                result += try await walk(child.path)
            }
        }
        return result
    }

    /// Crée `path` et ses parents manquants (`mkdir -p`).
    public func createDirectoryIfNeeded(at path: RemotePath) async throws {
        for ancestor in path.ancestors.dropFirst() {
            // Pas de primitive `exists` commune à tous les protocoles : on tente la
            // création et on ignore l'échec ; une vraie erreur réapparaîtra à l'étape suivante.
            try? await createDirectory(at: ancestor)
        }
    }
}

/// Fabrique d'adaptateurs : la seule pièce qui connaît les implémentations concrètes.
public protocol RemoteFileSystemFactory: Sendable {
    func makeFileSystem(for configuration: ConnectionConfiguration) -> any RemoteFileSystem
}
