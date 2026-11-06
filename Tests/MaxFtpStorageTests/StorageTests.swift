import Foundation
import MaxFtpCore
@testable import MaxFtpStorage
import Testing

@Suite("Stockage fichier")
struct StorageTests {
    func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name)
    }

    @Test func bookmarksRoundTrip() throws {
        let repository = JSONBookmarkRepository(fileURL: temporaryFile("bookmarks.json"))
        #expect(try repository.loadBookmarks().isEmpty)

        let bookmarks = [
            ServerBookmark(name: "Prod", connectionProtocol: .sftp, host: "prod.example.com", username: "deploy"),
            ServerBookmark(connectionProtocol: .ftpsExplicit, host: "ftp.example.com", ftpDataMode: .active),
        ]
        try repository.saveBookmarks(bookmarks)
        #expect(try repository.loadBookmarks() == bookmarks)
    }

    @Test func bookmarksFileContainsNoSecret() throws {
        let url = temporaryFile("bookmarks.json")
        try JSONBookmarkRepository(fileURL: url).saveBookmarks([ServerBookmark(host: "h", username: "u")])
        let document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(document["schemaVersion"] as? Int == 1)
        let bookmark = try #require((document["bookmarks"] as? [[String: Any]])?.first)
        #expect(Set(bookmark.keys).isDisjoint(with: ["password", "secret", "passphrase"]))
    }

    @Test func hostKeyStoreReplacesKeyOfSameType() throws {
        let store = JSONHostKeyStore(fileURL: temporaryFile("known_hosts.json"))
        let host = KnownHostIdentifier(host: "example.com", port: 2222)

        try store.trust("ssh-ed25519 AAAA1", for: host)
        try store.trust("ssh-rsa BBBB", for: host)
        try store.trust("ssh-ed25519 AAAA2", for: host)

        #expect(try store.trustedKeys(for: host) == ["ssh-rsa BBBB", "ssh-ed25519 AAAA2"])
        #expect(try store.trustedKeys(for: KnownHostIdentifier(host: "example.com", port: 22)).isEmpty)
    }
}

@Suite("Stockage des signets")
struct PathBookmarkStorageTests {
    @Test func roundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("path-bookmarks.json")
        let repository = JSONPathBookmarkRepository(fileURL: url)
        #expect(try repository.loadPathBookmarks().isEmpty)

        let signets = ["sftp://u@h:22": [
            PathBookmark(path: "/var/www", isDirectory: true),
            PathBookmark(name: "Config", path: "/etc/nginx/nginx.conf", isDirectory: false),
        ]]
        try repository.savePathBookmarks(signets)
        #expect(try repository.loadPathBookmarks() == signets)
    }
}
