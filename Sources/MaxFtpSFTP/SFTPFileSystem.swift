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
    private let sudoPasswords: (any SudoPasswordProvider)?

    private var ssh: SSHClient?
    private var sftp: SFTPClient?

    /// Taille des requêtes de lecture (le serveur peut renvoyer moins).
    private let readChunkSize: UInt32 = 64 * 1024

    public init(
        configuration: ConnectionConfiguration,
        hostKeyTrust: any HostKeyTrustPolicy,
        sudoPasswords: (any SudoPasswordProvider)? = nil
    ) {
        self.configuration = configuration
        self.hostKeyTrust = hostKeyTrust
        self.sudoPasswords = sudoPasswords
    }

    // MARK: Connexion

    public func connect() async throws {
        if let sftp, sftp.isActive { return }
        await disconnect()
        do {
            let client = try await SSHConnector.connect(configuration, hostKeyTrust: hostKeyTrust)
            ssh = client
            sftp = try await client.openSFTP()
        } catch {
            await disconnect()
            throw SSHConnector.translate(error, host: configuration.host)
        }
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
        do {
            try await sftpUpload(localURL, to: path, progress: progress)
        } catch where Self.isPermissionDenied(error) {
            guard let sudoPasswords else { throw error }
            try await uploadWithSudo(localURL, to: path, sudoPasswords: sudoPasswords, progress: progress)
        }
    }

    private func sftpUpload(_ localURL: URL, to path: RemotePath, progress: @escaping TransferProgressHandler) async throws {
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

    private func uploadWithSudo(
        _ localURL: URL,
        to path: RemotePath,
        sudoPasswords: any SudoPasswordProvider,
        progress: @escaping TransferProgressHandler
    ) async throws {
        guard #available(macOS 15, *) else {
            throw RemoteError.unsupportedOperation("L'élévation sudo nécessite macOS 15.")
        }
        try await connect()
        guard let ssh else { throw RemoteError.notConnected }

        let tempPath = RemotePath("/tmp/.maxftp-sudo-\(UUID().uuidString)")
        try await sftpUpload(localURL, to: tempPath, progress: progress)

        let command = "sudo -S -p '' sh -c 'cat \"$1\" > \"$2\" && echo __MAXFTP_OK__' _ \(ShellCommand.quote(tempPath.string)) \(ShellCommand.quote(path.string))"

        do {
            var previousFailed = false
            for attempt in 0..<3 {
                guard let password = await sudoPasswords.password(
                    for: configuration.serverKey,
                    path: path,
                    previousAttemptFailed: previousFailed
                ) else {
                    throw RemoteError.authenticationFailed("Authentification sudo annulée.")
                }

                var stdoutText = ""
                var stderrText = ""
                var commandFailed = false
                do {
                    try await ssh.withExec(command) { inbound, outbound in
                        try await outbound.write(ByteBuffer(string: password + "\n"))
                        for try await chunk in inbound {
                            switch chunk {
                            case .stdout(let buffer):
                                stdoutText += String(buffer: buffer)
                            case .stderr(let buffer):
                                stderrText += String(buffer: buffer)
                            }
                        }
                    }
                } catch is SSHClient.CommandFailed {
                    commandFailed = true
                } catch let error as ChannelError where error == .alreadyClosed {
                    // Le serveur a déjà fermé le canal à la fin de la commande.
                }

                if stdoutText.contains("__MAXFTP_OK__") && !commandFailed {
                    try? await sftp?.remove(at: tempPath.string)
                    return
                }

                let cleanedStderr = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                let looksLikeWrongPassword = Self.isWrongSudoPassword(cleanedStderr) || (cleanedStderr.isEmpty && attempt < 2)
                if looksLikeWrongPassword && attempt < 2 {
                    previousFailed = true
                    continue
                }
                await sudoPasswords.clear(for: configuration.serverKey)
                throw RemoteError.serverError(
                    code: 403,
                    message: cleanedStderr.isEmpty ? "Échec de l'enregistrement avec sudo." : cleanedStderr
                )
            }
            await sudoPasswords.clear(for: configuration.serverKey)
            throw RemoteError.authenticationFailed("Mot de passe sudo incorrect.")
        } catch {
            try? await sftp?.remove(at: tempPath.string)
            throw error
        }
    }

    private static func isPermissionDenied(_ error: any Error) -> Bool {
        if case SFTPError.errorStatus(let status) = error {
            return status.errorCode == .permissionDenied
        }
        if let status = error as? SFTPMessage.Status {
            return status.errorCode == .permissionDenied
        }
        return false
    }

    private static func isWrongSudoPassword(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("try again") || lower.contains("incorrect password") || lower.contains("mot de passe")
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
}
