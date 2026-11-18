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
    /// Chemins identifiés comme liens symboliques lors du listing (même s'ils pointent vers un dossier).
    private var knownSymbolicLinks: Set<RemotePath> = []

    /// Taille des requêtes de lecture (le serveur peut renvoyer moins).
    private let readChunkSize: UInt32 = 64 * 1024
    /// Taille d'une tranche d'écriture SFTP (limite d'un paquet dans Citadel).
    private let writeSliceSize = 32_000
    /// Nombre maximal de requêtes SFTP en vol simultanément par transfert (pipelining).
    private let maxInFlightRequests = 8

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

    /// Exécute une opération SFTP en se reconnectant une fois si le canal a été fermé entre-temps.
    private func withSFTP<T: Sendable>(_ operation: (SFTPClient) async throws -> T) async throws -> T {
        do {
            return try await operation(try await client())
        } catch is ChannelError {
            await disconnect()
            do {
                return try await operation(try await client())
            } catch is ChannelError {
                throw RemoteError.connectionClosed
            }
        }
    }

    // MARK: Navigation

    public func homeDirectory() async throws -> RemotePath {
        try await withSFTP { sftp in
            RemotePath(try await sftp.getRealPath(atPath: "."))
        }
    }

    public func contentsOfDirectory(at path: RemotePath) async throws -> [RemoteItem] {
        try await withSFTP { sftp in
            let names = try await sftp.listDirectory(atPath: path.string)
            knownSymbolicLinks = knownSymbolicLinks.filter { $0.parent != path }
            var items: [RemoteItem] = []
            var symlinkIndices: [Int] = []

            for component in names.flatMap(\.components) where RemotePath.isValidEntryName(component.filename) {
                let item = Self.makeItem(component.attributes, path: path.appending(component.filename))
                if item.kind == .symbolicLink {
                    knownSymbolicLinks.insert(item.path)
                    symlinkIndices.append(items.count)
                }
                items.append(item)
            }

            // `readdir` renvoie les attributs du lien lui-même : on résout les cibles en parallèle
            // sur le canal SFTP multiplexé pour éviter N allers-retours réseau séquentiels.
            if !symlinkIndices.isEmpty {
                let targets = symlinkIndices.map { ($0, items[$0].path.string) }
                await withTaskGroup(of: (Int, Bool).self) { group in
                    for (index, linkPath) in targets {
                        group.addTask {
                            let isDir = (try? await sftp.getAttributes(at: linkPath)).map { Self.kind(of: $0) == .directory } ?? false
                            return (index, isDir)
                        }
                    }
                    for await (index, isDir) in group where isDir {
                        items[index].kind = .directory
                    }
                }
            }
            return items
        }
    }

    // MARK: Opérations sur fichiers

    public func createDirectory(at path: RemotePath) async throws {
        try await withSFTP { try await $0.createDirectory(atPath: path.string) }
    }

    public func removeFile(at path: RemotePath) async throws {
        do {
            try await withSFTP { try await $0.remove(at: path.string) }
        } catch where Self.isPermissionDenied(error) {
            guard let sudoPasswords else { throw error }
            try await runWithSudo(
                command: Self.sudoRemoveFileCommand(at: path),
                path: path,
                sudoPasswords: sudoPasswords,
                failureMessage: "Échec de la suppression avec sudo."
            )
        }
    }

    public func removeDirectory(at path: RemotePath) async throws {
        do {
            try await withSFTP { try await $0.rmdir(at: path.string) }
        } catch where Self.isPermissionDenied(error) {
            guard let sudoPasswords else { throw error }
            try await runWithSudo(
                command: Self.sudoRemoveDirectoryCommand(at: path),
                path: path,
                sudoPasswords: sudoPasswords,
                failureMessage: "Échec de la suppression du dossier avec sudo."
            )
        }
    }

    public func removeItem(_ item: RemoteItem) async throws {
        guard item.isDirectory,
              item.symbolicLinkTarget == nil,
              !knownSymbolicLinks.contains(item.path) else {
            try await removeFile(at: item.path)
            return
        }
        do {
            for child in try await contentsOfDirectory(at: item.path) {
                try Task.checkCancellation()
                try await removeItem(child)
            }
            try await removeDirectory(at: item.path)
        } catch where Self.isPermissionDenied(error) {
            guard let sudoPasswords else { throw error }
            try await runWithSudo(
                command: Self.sudoRemoveTreeCommand(at: item.path),
                path: item.path,
                sudoPasswords: sudoPasswords,
                failureMessage: "Échec de la suppression du dossier avec sudo."
            )
        }
    }

    public func moveItem(at source: RemotePath, to destination: RemotePath) async throws {
        try await withSFTP { try await $0.rename(at: source.string, to: destination.string) }
    }

    public func setPermissions(_ permissions: POSIXPermissions, at path: RemotePath) async throws {
        var attributes = SFTPFileAttributes()
        attributes.permissions = UInt32(permissions.rawValue)
        try await withSFTP { try await $0.setAttributes(at: path.string, to: attributes) }
    }

    // MARK: Transferts

    public func download(_ path: RemotePath, to localURL: URL, progress: @escaping TransferProgressHandler) async throws {
        let chunkSize = readChunkSize
        let maxInFlight = maxInFlightRequests
        try await withSFTP { sftp in
            let file = try await sftp.openFile(filePath: path.string, flags: .read)
            let output = try LocalFileIO.createFileForWriting(at: localURL)
            defer { try? output.close() }

            do {
                var offset: UInt64 = 0
                if let totalSize = (try? await file.readAttributes())?.size, totalSize > UInt64(chunkSize) {
                    offset = try await Self.pipelinedDownload(
                        from: file,
                        totalSize: totalSize,
                        chunkSize: chunkSize,
                        maxInFlight: maxInFlight,
                        to: output,
                        progress: progress
                    )
                }
                while true {
                    try Task.checkCancellation()
                    let buffer = try await file.read(from: offset, length: chunkSize)
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
    }

    /// Télécharge un fichier avec une fenêtre glissante de `maxInFlight` requêtes `SSH_FXP_READ`
    /// simultanées et écrit les blocs reçus dans l'ordre sur disque.
    private static func pipelinedDownload(
        from file: SFTPFile,
        totalSize: UInt64,
        chunkSize: UInt32,
        maxInFlight: Int,
        to output: FileHandle,
        progress: @escaping TransferProgressHandler
    ) async throws -> UInt64 {
        let step = UInt64(chunkSize)
        let totalChunks = Int((totalSize + step - 1) / step)
        var nextToSchedule = 0
        var nextToWrite = 0
        var writtenBytes: UInt64 = 0
        var pending: [Int: (buffer: ByteBuffer, expected: Int)] = [:]
        var reachedEarlyEOF = false

        func scheduleNext(into group: inout ThrowingTaskGroup<(Int, ByteBuffer, Int), any Error>) throws {
            while nextToSchedule < totalChunks,
                  nextToSchedule - nextToWrite < maxInFlight,
                  !reachedEarlyEOF {
                try Task.checkCancellation()
                let index = nextToSchedule
                nextToSchedule += 1
                let chunkOffset = UInt64(index) * step
                let length = UInt32(min(step, totalSize - chunkOffset))
                group.addTask {
                    let buffer = try await readFullChunk(from: file, at: chunkOffset, length: length)
                    return (index, buffer, Int(length))
                }
            }
        }

        try await withThrowingTaskGroup(of: (Int, ByteBuffer, Int).self) { group in
            try scheduleNext(into: &group)
            while let (index, buffer, expected) = try await group.next() {
                pending[index] = (buffer, expected)
                while let ready = pending.removeValue(forKey: nextToWrite) {
                    if ready.buffer.readableBytes > 0 {
                        try output.write(contentsOf: Data(ready.buffer.readableBytesView))
                        writtenBytes += UInt64(ready.buffer.readableBytes)
                        progress(Int64(writtenBytes))
                    }
                    nextToWrite += 1
                    if ready.buffer.readableBytes < ready.expected {
                        reachedEarlyEOF = true
                        group.cancelAll()
                        pending.removeAll()
                        break
                    }
                }
                if reachedEarlyEOF { break }
                try scheduleNext(into: &group)
            }
        }
        return writtenBytes
    }

    private static func readFullChunk(from file: SFTPFile, at offset: UInt64, length: UInt32) async throws -> ByteBuffer {
        var accumulated = ByteBuffer()
        accumulated.reserveCapacity(Int(length))
        var currentOffset = offset
        var remaining = length
        while remaining > 0 {
            try Task.checkCancellation()
            var part = try await file.read(from: currentOffset, length: remaining)
            guard part.readableBytes > 0 else { break }
            let count = UInt32(part.readableBytes)
            accumulated.writeBuffer(&part)
            currentOffset += UInt64(count)
            remaining -= min(remaining, count)
        }
        return accumulated
    }

    public func upload(_ localURL: URL, to path: RemotePath, progress: @escaping TransferProgressHandler) async throws {
        do {
            try await sftpUpload(localURL, to: path, progress: progress)
        } catch where Self.isPermissionDenied(error) {
            guard let sudoPasswords else { throw error }
            try await uploadWithSudo(localURL, to: path, sudoPasswords: sudoPasswords, progress: progress)
        }
    }

    private func sftpUpload(
        _ localURL: URL,
        to path: RemotePath,
        permissions: UInt32? = nil,
        progress: @escaping TransferProgressHandler
    ) async throws {
        let sliceSize = writeSliceSize
        let maxInFlight = maxInFlightRequests
        try await withSFTP { sftp in
            let input = try LocalFileIO.openForReading(localURL)
            defer { try? input.close() }
            var attributes = SFTPFileAttributes.none
            attributes.permissions = permissions
            let file = try await sftp.openFile(
                filePath: path.string,
                flags: [.write, .create, .truncate],
                attributes: attributes
            )

            do {
                var nextOffset: UInt64 = 0
                var completedBytes: Int64 = 0

                func enqueueNext(into group: inout ThrowingTaskGroup<Int64, any Error>) throws -> Bool {
                    try Task.checkCancellation()
                    guard let data = try input.read(upToCount: sliceSize), !data.isEmpty else {
                        return false
                    }
                    let chunkOffset = nextOffset
                    let count = Int64(data.count)
                    nextOffset += UInt64(data.count)
                    let buffer = ByteBuffer(bytes: data)
                    group.addTask {
                        try await file.write(buffer, at: chunkOffset)
                        return count
                    }
                    return true
                }

                try await withThrowingTaskGroup(of: Int64.self) { group in
                    for _ in 0..<maxInFlight {
                        if try !enqueueNext(into: &group) { break }
                    }
                    while let count = try await group.next() {
                        completedBytes += count
                        progress(completedBytes)
                        _ = try enqueueNext(into: &group)
                    }
                }
                try await file.close()
            } catch {
                try? await file.close()
                throw error
            }
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
        let tempPath = RemotePath("/tmp/.maxftp-sudo-\(UUID().uuidString)")
        // Permissions 0600 dès la création pour qu'aucun autre utilisateur local ne puisse lire le fichier temporaire.
        try await sftpUpload(localURL, to: tempPath, permissions: 0o600, progress: progress)

        let command = Self.sudoUploadCommand(source: tempPath, destination: path)
        do {
            try await runWithSudo(
                command: command,
                path: path,
                sudoPasswords: sudoPasswords,
                failureMessage: "Échec de l'enregistrement avec sudo."
            )
            try? await sftp?.remove(at: tempPath.string)
        } catch {
            try? await sftp?.remove(at: tempPath.string)
            throw error
        }
    }

    private func runWithSudo(
        command: String,
        path: RemotePath,
        sudoPasswords: any SudoPasswordProvider,
        failureMessage: String
    ) async throws {
        guard #available(macOS 15, *) else {
            throw RemoteError.unsupportedOperation("L'élévation sudo nécessite macOS 15.")
        }
        try await connect()
        guard let ssh else { throw RemoteError.notConnected }

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
            } catch is ChannelError {
                throw RemoteError.connectionClosed
            }

            if stdoutText.contains("__MAXFTP_OK__") && !commandFailed {
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
                message: cleanedStderr.isEmpty ? failureMessage : cleanedStderr
            )
        }
        await sudoPasswords.clear(for: configuration.serverKey)
        throw RemoteError.authenticationFailed("Mot de passe sudo incorrect.")
    }

    static func sudoUploadCommand(source: RemotePath, destination: RemotePath) -> String {
        "sudo -k -S -p '' sh -c 'cat \"$1\" > \"$2\" && rm -f -- \"$1\" && echo __MAXFTP_OK__' _ \(ShellCommand.quote(source.string)) \(ShellCommand.quote(destination.string))"
    }

    static func sudoRemoveFileCommand(at path: RemotePath) -> String {
        "sudo -k -S -p '' sh -c 'rm -f -- \"$1\" && echo __MAXFTP_OK__' _ \(ShellCommand.quote(path.string))"
    }

    static func sudoRemoveDirectoryCommand(at path: RemotePath) -> String {
        "sudo -k -S -p '' sh -c 'rmdir -- \"$1\" && echo __MAXFTP_OK__' _ \(ShellCommand.quote(path.string))"
    }

    static func sudoRemoveTreeCommand(at path: RemotePath) -> String {
        "sudo -k -S -p '' sh -c 'rm -rf -- \"$1\" && echo __MAXFTP_OK__' _ \(ShellCommand.quote(path.string))"
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
