import Foundation
import MaxFtpCore
import MaxFtpFTP
import Testing

/// Tests contre un VRAI serveur FTP, désactivés par défaut.
///
/// Lancer avec : `MAXFTP_FTP_TEST_PORT=2121 swift test --filter FTPIntegration`
/// (voir `Scripts/test-ftp-server.py`). Variables optionnelles :
/// `MAXFTP_FTP_TEST_HOST` (127.0.0.1), `MAXFTP_FTP_TEST_USER` / `_PASSWORD` (user / pass),
/// `MAXFTP_FTPS_TEST_PORT` pour tester aussi le TLS explicite.
private let environment = ProcessInfo.processInfo.environment

@Suite("FTPIntegration", .serialized, .enabled(if: environment["MAXFTP_FTP_TEST_PORT"] != nil))
struct FTPIntegrationTests {
    static func configuration(_ proto: ConnectionProtocol, port: String?, mode: FTPDataConnectionMode) -> ConnectionConfiguration? {
        guard let port = port.flatMap(Int.init) else { return nil }
        return ConnectionConfiguration(
            connectionProtocol: proto,
            host: environment["MAXFTP_FTP_TEST_HOST"] ?? "127.0.0.1",
            port: port,
            username: environment["MAXFTP_FTP_TEST_USER"] ?? "user",
            credential: .password(environment["MAXFTP_FTP_TEST_PASSWORD"] ?? "pass"),
            ftpDataMode: mode,
            allowsUntrustedCertificates: true
        )
    }

    static var configurations: [ConnectionConfiguration] {
        [
            configuration(.ftp, port: environment["MAXFTP_FTP_TEST_PORT"], mode: .passive),
            configuration(.ftp, port: environment["MAXFTP_FTP_TEST_PORT"], mode: .active),
            configuration(.ftpsExplicit, port: environment["MAXFTP_FTPS_TEST_PORT"], mode: .passive),
        ].compactMap { $0 }
    }

    @Test(arguments: configurations)
    func fullRoundTrip(configuration: ConnectionConfiguration) async throws {
        let fs = FTPFileSystem(configuration: configuration)
        try await fs.connect()
        let home = try await fs.homeDirectory()
        let directory = home.appending("maxftp-\(UUID().uuidString.prefix(8))")

        try await fs.createDirectory(at: directory)

        let payload = Data((0..<300_000).map { UInt8($0 % 251) })
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try payload.write(to: local)
        try await fs.upload(local, to: directory.appending("données é.bin")) { _ in }

        let listing = try await fs.contentsOfDirectory(at: directory)
        #expect(listing.map(\.name) == ["données é.bin"])
        #expect(listing.first?.size == Int64(payload.count))

        try await fs.moveItem(at: directory.appending("données é.bin"), to: directory.appending("renamed.bin"))
        try await fs.setPermissions(POSIXPermissions(rawValue: 0o600), at: directory.appending("renamed.bin"))

        let downloaded = local.appendingPathExtension("back")
        try await fs.download(directory.appending("renamed.bin"), to: downloaded) { _ in }
        #expect(try Data(contentsOf: downloaded) == payload)

        try await fs.removeItem(RemoteItem(path: directory, kind: .directory))
        #expect(try await !fs.contentsOfDirectory(at: home).contains { $0.path == directory })
        await fs.disconnect()
    }

    @Test func wrongPasswordIsReported() async throws {
        var configuration = try #require(Self.configurations.first)
        configuration.credential = .password("definitely-wrong")
        let fs = FTPFileSystem(configuration: configuration)
        await #expect(throws: RemoteError.self) { try await fs.connect() }
    }
}

extension ConnectionConfiguration: CustomTestStringConvertible {
    public var testDescription: String { "\(connectionProtocol.displayName) \(ftpDataMode.rawValue)" }
}
