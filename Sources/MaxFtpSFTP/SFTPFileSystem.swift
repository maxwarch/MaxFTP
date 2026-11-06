@preconcurrency import Citadel
import Foundation
import MaxFtpCore
import NIOCore

/// Adaptateur SFTP basé sur Citadel (SwiftNIO SSH).
///
/// SFTP multiplexe les requêtes sur un seul canal : plusieurs opérations peuvent
/// donc être en vol simultanément sur la même connexion.
public actor SFTPFileSystem: RemoteFileSystem {
    public nonisolated let configuration: ConnectionConfiguration
    private let hostKeyTrust: any HostKeyTrustPolicy

    private var ssh: SSHClient?
    private var sftp: SFTPClient?

    /// Taille des requêtes de lecture (le serveur peut renvoyer moins).
    private let readChunkSize: UInt32 = 64 * 1024

    public init(configuration: ConnectionConfiguration, hostKeyTrust: any HostKeyTrustPolicy) {
        self.configuration = configuration
        self.hostKeyTrust = hostKeyTrust
    }

    // MARK: Connexion

    public func connect() async throws {
        if let sftp, sftp.isActive { return }
        await disconnect()

        let untrusted = HostKeyValidationDelegate.Box()
        do {
            try await openSession(recordingUntrustedKeyIn: untrusted)
            return
        } catch {
            await disconnect()
            guard let challenge = untrusted.challenge else {
                throw Self.translate(error, host: configuration.host)
            }
            // Clé inconnue ou changée : on demande à l'utilisateur HORS poignée de main
            // (il peut prendre son temps), puis on se reconnecte avec la clé désormais approuvée.
            guard await hostKeyTrust.confirm(challenge) else {
                throw RemoteError.hostKeyRejected(host: configuration.host)
            }
        }
        do {
            try await openSession(recordingUntrustedKeyIn: HostKeyValidationDelegate.Box())
        } catch {
            await disconnect()
            throw Self.translate(error, host: configuration.host)
        }
    }

    private func openSession(recordingUntrustedKeyIn untrusted: HostKeyValidationDelegate.Box) async throws {
        let authentication = try SSHAuthenticationFactory.method(for: configuration)
        let validator = SSHHostKeyValidator.custom(HostKeyValidationDelegate(
            host: KnownHostIdentifier(host: configuration.host, port: configuration.port),
            policy: hostKeyTrust,
            untrusted: untrusted
        ))
        let client = try await SSHClient.connect(
            host: configuration.host,
            port: configuration.port,
            authenticationMethod: authentication,
            hostKeyValidator: validator,
            reconnect: .never,
            connectTimeout: .seconds(20)
        )
        ssh = client
        sftp = try await client.openSFTP()
    }

    public func disconnect() async {
        try? await sftp?.close()
        try? await ssh?.close()
        sftp = nil
        ssh = nil
    }

    private func client() async throws -> SFTPClient {
        try await connect()
        guard let sftp else { throw RemoteError.notConnected }
        return sftp
    }

    // MARK: Navigation

    public func homeDirectory() async throws -> RemotePath {
        RemotePath(try await client().getRealPath(atPath: "."))
    }

    public func contentsOfDirectory(at path: RemotePath) async throws -> [RemoteItem] {
        let sftp = try await client()
        let names = try await sftp.listDirectory(atPath: path.string)
        var items: [RemoteItem] = []
        for component in names.flatMap(\.components) where component.filename != "." && component.filename != ".." {
            var item = Self.makeItem(component.attributes, path: path.appending(component.filename))
            // `readdir` renvoie les attributs du lien lui-même : on suit le lien pour savoir s'il mène à un dossier.
            if item.kind == .symbolicLink,
               let target = try? await sftp.getAttributes(at: item.path.string),
               Self.kind(of: target) == .directory {
                item.kind = .directory
            }
            items.append(item)
        }
        return items
    }

    // MARK: Opérations sur fichiers

    public func createDirectory(at path: RemotePath) async throws {
        try await client().createDirectory(atPath: path.string)
    }

    public func removeFile(at path: RemotePath) async throws {
        try await client().remove(at: path.string)
    }

    public func removeDirectory(at path: RemotePath) async throws {
        try await client().rmdir(at: path.string)
    }

    public func moveItem(at source: RemotePath, to destination: RemotePath) async throws {
        try await client().rename(at: source.string, to: destination.string)
    }

    public func setPermissions(_ permissions: POSIXPermissions, at path: RemotePath) async throws {
        var attributes = SFTPFileAttributes()
        attributes.permissions = UInt32(permissions.rawValue)
        try await client().setAttributes(at: path.string, to: attributes)
    }

    // MARK: Transferts

    public func download(_ path: RemotePath, to localURL: URL, progress: @escaping TransferProgressHandler) async throws {
        let file = try await client().openFile(filePath: path.string, flags: .read)
        let output = try LocalFileIO.createFileForWriting(at: localURL)
        defer { try? output.close() }

        do {
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let buffer = try await file.read(from: offset, length: readChunkSize)
                guard buffer.readableBytes > 0 else { break }
                try output.write(contentsOf: Data(buffer.readableBytesView))
                offset += UInt64(buffer.readableBytes)
                progress(Int64(offset))
            }
            try await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }

    public func upload(_ localURL: URL, to path: RemotePath, progress: @escaping TransferProgressHandler) async throws {
        let input = try LocalFileIO.openForReading(localURL)
        defer { try? input.close() }
        let file = try await client().openFile(filePath: path.string, flags: [.write, .create, .truncate])

        do {
            var offset: UInt64 = 0
            while let data = try input.read(upToCount: LocalFileIO.chunkSize), !data.isEmpty {
                try Task.checkCancellation()
                try await file.write(ByteBuffer(bytes: data), at: offset)
                offset += UInt64(data.count)
                progress(Int64(offset))
            }
            try await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }

    // MARK: Conversion des attributs SFTP → domaine

    static func kind(of attributes: SFTPFileAttributes) -> RemoteItem.Kind {
        guard let mode = attributes.permissions else { return .file }
        switch mode & 0o170000 {
        case 0o040000: return .directory
        case 0o120000: return .symbolicLink
        case 0o100000: return .file
        default: return .other
        }
    }

    static func makeItem(_ attributes: SFTPFileAttributes, path: RemotePath) -> RemoteItem {
        RemoteItem(
            path: path,
            kind: kind(of: attributes),
            size: attributes.size.map { Int64(clamping: $0) },
            modificationDate: attributes.accessModificationTime?.modificationTime,
            permissions: attributes.permissions.map { POSIXPermissions(rawValue: UInt16(truncatingIfNeeded: $0)) },
            owner: attributes.uidgid.map { String($0.userId) },
            group: attributes.uidgid.map { String($0.groupId) }
        )
    }

    static func translate(_ error: any Error, host: String) -> any Error {
        if error is RemoteError || error is CancellationError { return error }
        // Clé encore refusée après confirmation (elle a changé entre les deux tentatives).
        if error is HostKeyValidationDelegate.Untrusted { return RemoteError.hostKeyRejected(host: host) }
        let description = String(describing: error)
        if description.localizedCaseInsensitiveContains("auth") {
            return RemoteError.authenticationFailed(nil)
        }
        return RemoteError.connectionFailed(description)
    }
}
