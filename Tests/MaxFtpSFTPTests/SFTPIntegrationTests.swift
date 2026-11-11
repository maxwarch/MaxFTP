import Foundation
import MaxFtpCore
import MaxFtpSFTP
import Testing

/// Tests contre un VRAI serveur SSH, désactivés par défaut.
///
/// Lancer avec (voir `Scripts/test-sshd.sh`) :
/// `MAXFTP_SFTP_TEST_PORT=2222 MAXFTP_SFTP_TEST_KEY=/chemin/client_key swift test --filter SFTPIntegration`
/// Optionnel : `MAXFTP_SFTP_TEST_HOST`, `MAXFTP_SFTP_TEST_USER` (utilisateur courant par défaut),
/// `MAXFTP_SFTP_TEST_ENCRYPTED_KEY` + `MAXFTP_SFTP_TEST_PASSPHRASE`.
private let environment = ProcessInfo.processInfo.environment

@Suite("SFTPIntegration", .serialized, .enabled(if: environment["MAXFTP_SFTP_TEST_PORT"] != nil))
struct SFTPIntegrationTests {
    /// Ne connaît aucune clé au départ ; enregistre les questions posées et répond `answer`
    /// (une clé acceptée est ensuite reconnue, comme avec le vrai magasin de clés).
    final class RecordingTrustPolicy: HostKeyTrustPolicy, @unchecked Sendable {
        private let lock = NSLock()
        private var challenges: [HostKeyChallenge] = []
        private var trusted: Set<String> = []
        let answer: Bool

        init(answer: Bool) { self.answer = answer }

        var seen: [HostKeyChallenge] { lock.withLock { challenges } }

        func untrustedStatus(of challenge: HostKeyChallenge) -> HostKeyChallenge.Status? {
            lock.withLock { trusted.contains(challenge.openSSHKey) ? nil : .unknown }
        }

        func confirm(_ challenge: HostKeyChallenge) async -> Bool {
            lock.withLock {
                challenges.append(challenge)
                if answer { trusted.insert(challenge.openSSHKey) }
            }
            return answer
        }
    }

    func configuration(key: String? = environment["MAXFTP_SFTP_TEST_KEY"], passphrase: String? = nil) throws -> ConnectionConfiguration {
        let key = try #require(key, "MAXFTP_SFTP_TEST_KEY manquant")
        return ConnectionConfiguration(
            connectionProtocol: .sftp,
            host: environment["MAXFTP_SFTP_TEST_HOST"] ?? "127.0.0.1",
            port: Int(environment["MAXFTP_SFTP_TEST_PORT"] ?? "22"),
            username: environment["MAXFTP_SFTP_TEST_USER"] ?? NSUserName(),
            credential: .privateKey(URL(fileURLWithPath: key), passphrase: passphrase)
        )
    }

    @Test func fullRoundTrip() async throws {
        let trust = RecordingTrustPolicy(answer: true)
        let fs = SFTPFileSystem(configuration: try configuration(), hostKeyTrust: trust)
        try await fs.connect()
        #expect(trust.seen.first?.keyType == "ssh-ed25519")
        #expect(trust.seen.first?.fingerprint.hasPrefix("SHA256:") == true)

        let base = RemotePath(FileManager.default.temporaryDirectory.path).appending("maxftp-sftp-\(UUID().uuidString.prefix(8))")
        try await fs.createDirectory(at: base)

        let payload = Data((0..<500_000).map { UInt8($0 % 253) })
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try payload.write(to: local)
        try await fs.upload(local, to: base.appending("données é.bin")) { _ in }

        let listing = try await fs.contentsOfDirectory(at: base)
        #expect(listing.map(\.name) == ["données é.bin"])
        #expect(listing.first?.size == Int64(payload.count))
        #expect(listing.first?.kind == .file)

        try await fs.moveItem(at: base.appending("données é.bin"), to: base.appending("renamed.bin"))
        try await fs.setPermissions(POSIXPermissions(rawValue: 0o600), at: base.appending("renamed.bin"))
        #expect(try await fs.contentsOfDirectory(at: base).first?.permissions?.octalString == "0600")

        let downloaded = local.appendingPathExtension("back")
        let progress = ProgressBox()
        try await fs.download(base.appending("renamed.bin"), to: downloaded) { progress.value = $0 }
        #expect(try Data(contentsOf: downloaded) == payload)
        #expect(progress.value == Int64(payload.count))

        try await fs.removeItem(RemoteItem(path: base, kind: .directory))
        #expect(try await !fs.contentsOfDirectory(at: base.parent).contains { $0.path == base })
        await fs.disconnect()
    }

    @Test func encryptedKeyNeedsPassphrase() async throws {
        let key = try #require(environment["MAXFTP_SFTP_TEST_ENCRYPTED_KEY"])
        let passphrase = try #require(environment["MAXFTP_SFTP_TEST_PASSPHRASE"])
        let trust = RecordingTrustPolicy(answer: true)

        let withoutPassphrase = SFTPFileSystem(configuration: try configuration(key: key), hostKeyTrust: trust)
        await #expect(throws: RemoteError.self) { try await withoutPassphrase.connect() }

        let withPassphrase = SFTPFileSystem(configuration: try configuration(key: key, passphrase: passphrase), hostKeyTrust: trust)
        try await withPassphrase.connect()
        #expect(try await withPassphrase.homeDirectory().isRoot == false)
        await withPassphrase.disconnect()
    }

    @Test func rejectedHostKeyAbortsConnection() async throws {
        let fs = SFTPFileSystem(configuration: try configuration(), hostKeyTrust: RecordingTrustPolicy(answer: false))
        await #expect(throws: RemoteError.hostKeyRejected(host: environment["MAXFTP_SFTP_TEST_HOST"] ?? "127.0.0.1")) {
            try await fs.connect()
        }
    }

    /// Shell interactif : ouverture dans un dossier, commande, sortie, puis `exit`.
    @Test func interactiveShell() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("maxftp-shell-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let shell = SSHShell(configuration: try configuration(), hostKeyTrust: RecordingTrustPolicy(answer: true))

        let output = try await shell.start(columns: 80, rows: 24)
        await shell.send(Data(ShellCommand.changeDirectory(to: RemotePath(directory.path)).utf8))
        await shell.send(Data("mkdir créé-par-shell && echo FIN-$((40+2))\r".utf8))
        await shell.send(Data("exit\r".utf8))

        var text = ""
        for try await chunk in output { text += String(decoding: chunk, as: UTF8.self) }
        #expect(text.contains("FIN-42"))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("créé-par-shell").path))
        await shell.close()
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int64 = 0
    var value: Int64 {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
