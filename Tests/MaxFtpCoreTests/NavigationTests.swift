import Foundation
@testable import MaxFtpCore
import Testing

@Suite("Historique de navigation")
struct NavigationHistoryTests {
    @Test func backAndForwardLikeABrowser() {
        var history = NavigationHistory()
        #expect(!history.canGoBack && !history.canGoForward)

        history.visit(from: "/a", to: "/a/b")
        history.visit(from: "/a/b", to: "/a/b/c")
        #expect(history.backTarget == "/a/b")

        history.didGoBack(from: "/a/b/c")
        #expect(history.backTarget == "/a")
        #expect(history.forwardTarget == "/a/b/c")

        history.didGoForward(from: "/a/b")
        #expect(history.backTarget == "/a/b")
        #expect(!history.canGoForward)
    }

    @Test func newVisitClearsForwardStack() {
        var history = NavigationHistory()
        history.visit(from: "/a", to: "/b")
        history.didGoBack(from: "/b")
        history.visit(from: "/a", to: "/c")
        #expect(!history.canGoForward)
        #expect(history.backStack == ["/a"])
    }

    @Test func reloadingSameFolderAddsNothing() {
        var history = NavigationHistory()
        history.visit(from: "/a", to: "/a")
        #expect(!history.canGoBack)
    }

    @Test func emptyStacksIgnoreMoves() {
        var history = NavigationHistory()
        history.didGoBack(from: "/a")
        history.didGoForward(from: "/a")
        #expect(history == NavigationHistory())
    }

    @Test func keepsOnlyTheMostRecentEntries() {
        var history = NavigationHistory(limit: 2)
        history.visit(from: "/1", to: "/2")
        history.visit(from: "/2", to: "/3")
        history.visit(from: "/3", to: "/4")
        #expect(history.backStack == ["/2", "/3"])
    }
}

@Suite("Signets")
struct PathBookmarkTests {
    @Test func defaultNameIsLastComponent() {
        #expect(PathBookmark(path: "/var/www/site", isDirectory: true).name == "site")
    }

    @Test func serverKeyIdentifiesProtocolUserHostAndPort() {
        var configuration = ConnectionConfiguration(
            connectionProtocol: .sftp, host: "Example.COM", port: 2222, username: "deploy", credential: .anonymous
        )
        #expect(configuration.serverKey == "sftp://deploy@example.com:2222")

        // Le secret et le dossier initial ne changent pas l'identité du serveur.
        configuration.credential = .password("x")
        configuration.initialPath = "/tmp"
        #expect(configuration.serverKey == "sftp://deploy@example.com:2222")
    }

    @Test func favoriteSharesServerKeyWithItsConnection() {
        let favorite = ServerBookmark(name: "Prod", connectionProtocol: .sftp, host: "example.com", port: 2222, username: "deploy", initialPath: "/var")
        #expect(favorite.serverKey == "sftp://deploy@example.com:2222")
        #expect(favorite.serverKey == favorite.configuration(secret: "x").serverKey)
    }
}

@Suite("Délai d'attente")
struct TimeoutTests {
    @Test func returnsTheResultInTime() async throws {
        #expect(try await withTimeout(.seconds(5)) { 42 } == 42)
    }

    @Test func doesNotWaitForAnOperationThatIgnoresCancellation() async {
        let start = ContinuousClock.now
        await #expect(throws: TimeoutError.self) {
            try await withTimeout(.milliseconds(100)) {
                let deadline = ContinuousClock.now + .seconds(3)
                while ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
                return 0
            }
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func timeDoesNotRunWhilePaused() async throws {
        let prompts = UserPromptTracker()
        // L'opération dure 300 ms, dont 250 ms de « question à l'utilisateur » ; délai : 150 ms.
        let result = try await withTimeout(.milliseconds(150), pausedWhile: { prompts.isPrompting }) {
            await prompts.during { try? await Task.sleep(for: .milliseconds(250)) }
            try await Task.sleep(for: .milliseconds(50))
            return "ok"
        }
        #expect(result == "ok")
        #expect(!prompts.isPrompting)
    }

    @Test func forwardsErrors() async {
        await #expect(throws: TimeoutError.self) {
            try await withTimeout(.seconds(5)) { () async throws -> Int in throw TimeoutError() }
        }
    }
}

@Suite("Favori depuis une connexion")
struct BookmarkFromConnectionTests {
    @Test func copiesEverySettingAndKeepsTheServerKey() {
        let configuration = ConnectionConfiguration(
            connectionProtocol: .ftpsExplicit, host: "ftp.exemple.fr", port: 2121, username: "web",
            credential: .password("s3cret"), initialPath: "/var/www",
            ftpDataMode: .active, allowsUntrustedCertificates: true
        )
        let (bookmark, secret) = ServerBookmark.from(configuration, name: "Prod")

        #expect(bookmark.name == "Prod")
        #expect(bookmark.initialPath == "/var/www")
        #expect(bookmark.ftpDataMode == .active)
        #expect(bookmark.allowsUntrustedCertificates)
        #expect(secret == "s3cret")
        // Même serveur : les signets de la session suivent le nouveau favori.
        #expect(bookmark.serverKey == configuration.serverKey)
        #expect(bookmark.configuration(secret: secret) == configuration)
    }

    @Test func privateKeyAndAnonymous() {
        let key = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/id_ed25519")
        let ssh = ConnectionConfiguration(connectionProtocol: .sftp, host: "h", username: "u", credential: .privateKey(key, passphrase: "pp"))
        let (bookmark, secret) = ServerBookmark.from(ssh, name: "h")
        #expect(bookmark.authenticationKind == .privateKey)
        #expect(bookmark.privateKeyPath == "~/.ssh/id_ed25519")
        #expect(secret == "pp")
        #expect(bookmark.configuration(secret: secret) == ssh)

        let anonymous = ConnectionConfiguration(connectionProtocol: .ftp, host: "h", username: "", credential: .anonymous)
        #expect(ServerBookmark.from(anonymous, name: "h").secret == nil)
    }
}
