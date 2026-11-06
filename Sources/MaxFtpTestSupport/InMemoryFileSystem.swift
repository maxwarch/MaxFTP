import Foundation
import MaxFtpCore

/// Faux serveur en mémoire, conforme à ``RemoteFileSystem``.
///
/// Sert aux tests des modèles de vue et du moteur de transferts sans réseau.
public actor InMemoryFileSystem: RemoteFileSystem {
    public nonisolated let configuration: ConnectionConfiguration
    public private(set) var files: [RemotePath: Data] = [:]
    public private(set) var directories: Set<RemotePath> = [.root]
    public private(set) var permissions: [RemotePath: POSIXPermissions] = [:]
    public private(set) var isConnected = false
    public private(set) var connectCount = 0
    public var home: RemotePath = "/home/test"
    /// Si défini, `connect()` échoue avec cette erreur.
    public var connectionError: RemoteError?

    public init(configuration: ConnectionConfiguration = .test, files: [String: String] = [:]) {
        self.configuration = configuration
        directories.insert("/home")
        directories.insert("/home/test")
        for (path, content) in files {
            let remote = RemotePath(path)
            self.files[remote] = Data(content.utf8)
            for ancestor in remote.parent.ancestors { directories.insert(ancestor) }
        }
    }

    /// Si défini, `connect()` reste bloqué ce temps-là SANS réagir à l'annulation,
    /// comme un serveur qui ne répond jamais.
    public var connectionHang: Duration?

    public func failConnections(with error: RemoteError?) { connectionError = error }

    public func hangConnections(for duration: Duration?) { connectionHang = duration }

    public func connect() async throws {
        if let connectionHang {
            let deadline = ContinuousClock.now + connectionHang
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))  // `try?` : ignore volontairement l'annulation
            }
        }
        if let connectionError { throw connectionError }
        isConnected = true
        connectCount += 1
    }

    public func disconnect() async { isConnected = false }

    public func homeDirectory() async throws -> RemotePath { home }

    public func contentsOfDirectory(at path: RemotePath) async throws -> [RemoteItem] {
        guard directories.contains(path) else { throw RemoteError.serverError(code: 550, message: "No such directory") }
        let dirs = directories.filter { $0.parent == path && !$0.isRoot }.map {
            RemoteItem(path: $0, kind: .directory, permissions: permissions[$0])
        }
        let regular = files.filter { $0.key.parent == path }.map {
            RemoteItem(path: $0.key, kind: .file, size: Int64($0.value.count), permissions: permissions[$0.key])
        }
        return dirs + regular
    }

    public func createDirectory(at path: RemotePath) async throws {
        guard directories.contains(path.parent) else { throw RemoteError.serverError(code: 550, message: "No parent") }
        guard !directories.contains(path) else { throw RemoteError.serverError(code: 550, message: "Exists") }
        directories.insert(path)
    }

    public func removeFile(at path: RemotePath) async throws {
        guard files.removeValue(forKey: path) != nil else { throw RemoteError.serverError(code: 550, message: "No such file") }
    }

    public func removeDirectory(at path: RemotePath) async throws {
        let hasChildren = directories.contains { $0.parent == path && $0 != path } || files.keys.contains { $0.parent == path }
        guard !hasChildren else { throw RemoteError.serverError(code: 550, message: "Directory not empty") }
        directories.remove(path)
    }

    public func moveItem(at source: RemotePath, to destination: RemotePath) async throws {
        if let data = files.removeValue(forKey: source) {
            files[destination] = data
        } else if directories.remove(source) != nil {
            directories.insert(destination)
        } else {
            throw RemoteError.serverError(code: 550, message: "No such item")
        }
    }

    public func setPermissions(_ permissions: POSIXPermissions, at path: RemotePath) async throws {
        self.permissions[path] = permissions
    }

    public func download(_ path: RemotePath, to localURL: URL, progress: @escaping TransferProgressHandler) async throws {
        guard let data = files[path] else { throw RemoteError.serverError(code: 550, message: "No such file") }
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: localURL)
        progress(Int64(data.count))
    }

    public func upload(_ localURL: URL, to path: RemotePath, progress: @escaping TransferProgressHandler) async throws {
        guard directories.contains(path.parent) else { throw RemoteError.serverError(code: 553, message: "No parent") }
        let data = try Data(contentsOf: localURL)
        files[path] = data
        progress(Int64(data.count))
    }

    public func contents(of path: RemotePath) -> String? {
        files[path].map { String(decoding: $0, as: UTF8.self) }
    }
}

/// Factory renvoyant toujours le même serveur en mémoire.
public struct InMemoryFileSystemFactory: RemoteFileSystemFactory {
    public let fileSystem: InMemoryFileSystem

    public init(fileSystem: InMemoryFileSystem) {
        self.fileSystem = fileSystem
    }

    public func makeFileSystem(for configuration: ConnectionConfiguration) -> any RemoteFileSystem {
        fileSystem
    }
}

extension ConnectionConfiguration {
    public static let test = ConnectionConfiguration(
        connectionProtocol: .sftp,
        host: "test.local",
        username: "test",
        credential: .password("secret")
    )
}
