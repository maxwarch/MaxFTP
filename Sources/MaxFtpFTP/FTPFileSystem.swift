import Foundation
import MaxFtpCore
import NIOCore
import os

/// Adaptateur FTP / FTPS (TLS explicite ou implicite) basé sur SwiftNIO.
///
/// FTP n'autorise qu'UNE commande à la fois sur le canal de contrôle. L'actor ne
/// suffit pas à le garantir (réentrance à chaque `await`), d'où ``exclusive(_:)``
/// qui sérialise explicitement chaque opération publique.
///
/// Organisation du code :
/// - ce fichier : conformité à ``RemoteFileSystem`` (le « quoi ») ;
/// - `FTPFileSystem+Session.swift` : connexion, commandes, canal de données (le « comment »).
public actor FTPFileSystem: RemoteFileSystem {
    public nonisolated let configuration: ConnectionConfiguration

    let logger = Logger(subsystem: "com.maxftp.app", category: "FTP")
    var control: NIOByteStream?
    var lineBuffer = FTPLineBuffer()
    var features: Set<String> = []
    var tls: TLSSettings?
    var extendedPassiveUnsupported = false

    // Verrou asynchrone (voir `exclusive`).
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(configuration: ConnectionConfiguration) {
        self.configuration = configuration
    }

    // MARK: Connexion

    public func connect() async throws {
        try await exclusive { try await ensureConnected() }
    }

    public func disconnect() async {
        await exclusive { await closeSession(sendQuit: true) }
    }

    // MARK: Navigation

    public func homeDirectory() async throws -> RemotePath {
        try await exclusive {
            try await ensureConnected()
            let reply = try await command("PWD", expecting: 257)
            return RemotePath(FTPResponseParsing.quotedPath(from: reply.message) ?? "/")
        }
    }

    public func contentsOfDirectory(at path: RemotePath) async throws -> [RemoteItem] {
        try await exclusive {
            try await ensureConnected()
            let usesMLSD = features.contains("MLST") || features.contains("MLSD")
            let listing = try await receiveData(usesMLSD ? "MLSD \(path.string)" : "LIST -a \(path.string)")
            let text = String(decoding: listing, as: UTF8.self)
            return usesMLSD
                ? FTPListParser.parseMLSD(text, in: path)
                : FTPListParser.parseLIST(text, in: path)
        }
    }

    // MARK: Opérations sur fichiers

    public func createDirectory(at path: RemotePath) async throws {
        try await simpleCommand("MKD \(path.string)", expecting: 257, 250)
    }

    public func removeFile(at path: RemotePath) async throws {
        try await simpleCommand("DELE \(path.string)", expecting: 250)
    }

    public func removeDirectory(at path: RemotePath) async throws {
        try await simpleCommand("RMD \(path.string)", expecting: 250)
    }

    public func moveItem(at source: RemotePath, to destination: RemotePath) async throws {
        try await exclusive {
            try await ensureConnected()
            try await command("RNFR \(source.string)", expecting: 350)
            try await command("RNTO \(destination.string)", expecting: 250)
        }
    }

    public func setPermissions(_ permissions: POSIXPermissions, at path: RemotePath) async throws {
        try await simpleCommand("SITE CHMOD \(permissions.octalString) \(path.string)", expecting: 200, 250)
    }

    // MARK: Transferts

    public func download(_ path: RemotePath, to localURL: URL, progress: @escaping TransferProgressHandler) async throws {
        try await exclusive {
            try await ensureConnected()
            let output = try LocalFileIO.createFileForWriting(at: localURL)
            defer { try? output.close() }

            try await withDataConnection("RETR \(path.string)") { data in
                var received: Int64 = 0
                while let chunk = try await data.next() {
                    try Task.checkCancellation()
                    try output.write(contentsOf: Data(chunk.readableBytesView))
                    received += Int64(chunk.readableBytes)
                    progress(received)
                }
            }
        }
    }

    public func upload(_ localURL: URL, to path: RemotePath, progress: @escaping TransferProgressHandler) async throws {
        try await exclusive {
            try await ensureConnected()
            let input = try LocalFileIO.openForReading(localURL)
            defer { try? input.close() }

            try await withDataConnection("STOR \(path.string)") { data in
                var sent: Int64 = 0
                while let chunk = try input.read(upToCount: LocalFileIO.chunkSize), !chunk.isEmpty {
                    try Task.checkCancellation()
                    try await data.write(chunk)
                    sent += Int64(chunk.count)
                    progress(sent)
                }
                // La fermeture du canal de données signale la fin du fichier au serveur.
                await data.close()
            }
        }
    }

    // MARK: Sérialisation des opérations

    /// Exécute `body` sans qu'aucune autre opération publique ne s'intercale.
    /// Ne JAMAIS appeler une méthode publique depuis `body` (interblocage).
    func exclusive<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
        while isBusy {
            await withCheckedContinuation { waiters.append($0) }
        }
        isBusy = true
        defer {
            isBusy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return try await body()
    }

    private func simpleCommand(_ line: String, expecting codes: Int...) async throws {
        try await exclusive {
            try await ensureConnected()
            try await command(line, expecting: Set(codes))
        }
    }
}
