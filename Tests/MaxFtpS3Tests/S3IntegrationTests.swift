import Foundation
import MaxFtpCore
import MaxFtpS3
import Testing

/// Tests contre un VRAI bucket (Cloudflare R2, AWS S3, MinIO…), désactivés par défaut.
///
/// Lancer avec :
/// `MAXFTP_S3_TEST_ENDPOINT=<compte>.r2.cloudflarestorage.com MAXFTP_S3_TEST_BUCKET=… \
///  MAXFTP_S3_TEST_ACCESS_KEY=… MAXFTP_S3_TEST_SECRET_KEY=… swift test --filter S3Integration`
/// Options : `MAXFTP_S3_TEST_REGION` (auto), `MAXFTP_S3_TEST_PORT` (443).
/// Le test travaille dans un préfixe `maxftp-…` qu'il supprime à la fin.
private let environment = ProcessInfo.processInfo.environment

@Suite("S3Integration", .serialized, .enabled(if: environment["MAXFTP_S3_TEST_ENDPOINT"] != nil))
struct S3IntegrationTests {
    static var configuration: ConnectionConfiguration {
        ConnectionConfiguration(
            connectionProtocol: .s3,
            host: environment["MAXFTP_S3_TEST_ENDPOINT"] ?? "",
            port: environment["MAXFTP_S3_TEST_PORT"].flatMap(Int.init),
            username: environment["MAXFTP_S3_TEST_ACCESS_KEY"] ?? "",
            credential: .password(environment["MAXFTP_S3_TEST_SECRET_KEY"] ?? ""),
            initialPath: RemotePath("/" + (environment["MAXFTP_S3_TEST_BUCKET"] ?? "")),
            s3Region: environment["MAXFTP_S3_TEST_REGION"] ?? "auto"
        )
    }

    @Test func fullRoundTrip() async throws {
        let fs = S3FileSystem(configuration: Self.configuration)
        try await fs.connect()
        let bucket = try #require(Self.configuration.initialPath)
        let directory = bucket.appending("maxftp-\(UUID().uuidString.prefix(8))")

        try await fs.createDirectory(at: directory)
        #expect(try await fs.contentsOfDirectory(at: bucket).contains { $0.path == directory && $0.isDirectory })

        let payload = Data((0..<300_000).map { UInt8($0 % 251) })
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try payload.write(to: local)
        try await fs.upload(local, to: directory.appending("sous/données é+&.bin")) { _ in }

        #expect(try await fs.contentsOfDirectory(at: directory).map(\.name).sorted() == ["sous"])
        let listing = try await fs.contentsOfDirectory(at: directory.appending("sous"))
        #expect(listing.map(\.name) == ["données é+&.bin"])
        #expect(listing.first?.size == Int64(payload.count))

        // Renommage d'un dossier = copie de chaque objet puis suppression.
        try await fs.moveItem(at: directory.appending("sous"), to: directory.appending("renommé"))
        let downloaded = local.appendingPathExtension("back")
        try await fs.download(directory.appending("renommé/données é+&.bin"), to: downloaded) { _ in }
        #expect(try Data(contentsOf: downloaded) == payload)

        try await fs.removeItem(RemoteItem(path: directory, kind: .directory))
        #expect(try await !fs.contentsOfDirectory(at: bucket).contains { $0.path == directory })
    }

    @Test func wrongSecretIsReported() async throws {
        var configuration = Self.configuration
        configuration.credential = .password("definitely-wrong")
        let fs = S3FileSystem(configuration: configuration)
        await #expect(throws: RemoteError.self) { try await fs.connect() }
    }
}
