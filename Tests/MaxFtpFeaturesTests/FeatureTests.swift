import Foundation
import MaxFtpCore
@testable import MaxFtpFeatures
import MaxFtpTestSupport
import Testing

@MainActor
@Suite("BrowserModel")
struct BrowserModelTests {
    let server = InMemoryFileSystem(files: [
        "/home/test/index.html": "<html>",
        "/home/test/.env": "SECRET=1",
        "/home/test/assets/app.js": "console.log(1)",
    ])

    func makeModel() -> BrowserModel {
        let factory = InMemoryFileSystemFactory(fileSystem: server)
        return BrowserModel(factory: factory, transfers: TransferQueue(factory: factory, maxConcurrent: { 1 }))
    }

    @Test func connectsAndListsHomeDirectory() async {
        let model = makeModel()
        await model.connect(to: .test)

        #expect(model.isConnected)
        #expect(model.currentPath == "/home/test")
        // Fichiers cachés masqués, dossiers en premier.
        #expect(model.visibleItems.map(\.name) == ["assets", "index.html"])

        model.showHiddenFiles = true
        #expect(model.visibleItems.map(\.name) == ["assets", ".env", "index.html"])
    }

    @Test func reportsConnectionErrors() async {
        await server.failConnections(with: .authenticationFailed(nil))
        let model = makeModel()
        await model.connect(to: .test)

        #expect(model.connectionState == .disconnected)
        #expect(model.errorMessage == RemoteError.authenticationFailed(nil).errorDescription)
    }

    @Test func fileOperations() async throws {
        let model = makeModel()
        await model.connect(to: .test)

        await model.createFolder(named: "logs")
        #expect(model.selection == ["/home/test/logs"])

        let index = try #require(model.items.first { $0.name == "index.html" })
        await model.rename(index, to: "home.html")
        #expect(await server.contents(of: "/home/test/home.html") == "<html>")

        model.requestDeletion(of: ["/home/test/assets"])
        await model.confirmDeletion()
        #expect(!model.items.contains { $0.name == "assets" })
        #expect(model.errorMessage == nil)
    }

    @Test func backgroundRefreshShowsExternalChangesAndKeepsSelection() async throws {
        let model = makeModel()
        await model.connect(to: .test)
        model.selection = ["/home/test/index.html"]

        // Création « dans le terminal » : directement sur le serveur, hors du modèle.
        try await server.createDirectory(at: "/home/test/nouveau")
        await model.refreshInBackground()
        #expect(model.visibleItems.map(\.name) == ["assets", "nouveau", "index.html"])
        #expect(model.selection == ["/home/test/index.html"])
        #expect(!model.isLoading && model.errorMessage == nil)

        try await server.removeFile(at: "/home/test/index.html")
        await model.refreshInBackground()
        #expect(model.selection.isEmpty)
    }

    @Test func backgroundRefreshStaysSilentOnErrors() async throws {
        let model = makeModel()
        await model.connect(to: .test)
        await model.navigate(to: "/home/test/assets")
        try await server.removeFile(at: "/home/test/assets/app.js")
        try await server.removeDirectory(at: "/home/test/assets")
        await model.refreshInBackground()
        #expect(model.errorMessage == nil)
    }

    @Test func terminalOnlyOverSSH() async {
        let model = makeModel()
        #expect(!model.canOpenTerminal)
        await model.connect(to: .test)  // SFTP
        model.openTerminal(at: "/home/test/assets")
        #expect(model.terminal?.directory == "/home/test/assets")
        model.toggleTerminal()
        #expect(model.terminal == nil)
        model.toggleTerminal()
        #expect(model.terminal?.directory == "/home/test")

        await model.disconnect()
        #expect(model.terminal == nil)

        var ftp = ConnectionConfiguration.test
        ftp.connectionProtocol = .ftp
        await model.connect(to: ftp)
        model.openTerminal()
        #expect(!model.canOpenTerminal && model.terminal == nil)
    }

    @Test func autoRefreshNeverPollsObjectStorage() {
        #expect(AppSettings.autoRefreshInterval(for: .sftp, seconds: 5) == .seconds(5))
        #expect(AppSettings.autoRefreshInterval(for: .ftp, seconds: 0) == nil)
        #expect(AppSettings.autoRefreshInterval(for: .s3, seconds: 5) == nil)
    }

    @Test func rejectsInvalidNames() async {
        let model = makeModel()
        await model.connect(to: .test)
        await model.createFolder(named: "../evil")
        #expect(model.errorMessage != nil)
    }

    @Test func openNavigatesIntoDirectories() async {
        let model = makeModel()
        await model.connect(to: .test)
        await model.open(["/home/test/assets"])
        #expect(model.currentPath == "/home/test/assets")
        await model.goToParent()
        #expect(model.currentPath == "/home/test")
    }

    @Test func backAndForwardThroughHistory() async {
        let model = makeModel()
        await model.connect(to: .test)
        #expect(!model.canGoBack)  // le dossier d'arrivée n'est pas une étape

        await model.navigate(to: "/home/test/assets")
        await model.goToParent()
        await model.navigate(to: "/home")
        #expect(model.canGoBack && !model.canGoForward)

        await model.goBack()
        #expect(model.currentPath == "/home/test")
        await model.goBack()
        #expect(model.currentPath == "/home/test/assets")
        #expect(model.canGoForward)

        await model.goForward()
        #expect(model.currentPath == "/home/test")

        // Une nouvelle navigation efface l'avant, une actualisation ne compte pas.
        await model.navigate(to: "/home/test/assets")
        await model.refresh()
        #expect(!model.canGoForward)
        await model.goBack()
        #expect(model.currentPath == "/home/test")
    }

    @Test func deletionSurvivesDialogDismissal() async {
        let model = makeModel()
        await model.connect(to: .test)
        model.requestDeletion(of: ["/home/test/index.html"])

        // Ordre réel côté SwiftUI : on capture, le dialogue se ferme (vide la liste), puis la tâche s'exécute.
        let targets = model.pendingDeletion
        model.pendingDeletion = []
        await model.delete(targets)

        #expect(!model.items.contains { $0.name == "index.html" })
        #expect(model.errorMessage == nil)
    }

    @Test func goingUpSelectsTheFolderWeCameFrom() async {
        let model = makeModel()
        await model.connect(to: .test)
        await model.navigate(to: "/home/test/assets")

        await model.goBack()
        #expect(model.currentPath == "/home/test")
        #expect(model.selection == ["/home/test/assets"])

        await model.goForward()  // on redescend : rien à re-sélectionner
        #expect(model.selection.isEmpty)

        await model.navigate(to: "/home")  // remonter de deux niveaux
        #expect(model.selection == ["/home/test"])
    }

    @Test func enclosingFoldersGoFromParentToRoot() async {
        let model = makeModel()
        await model.connect(to: .test)
        await model.navigate(to: "/home/test/assets")
        #expect(model.enclosingFolders == ["/home/test", "/home", "/"])

        await model.navigate(to: "/")
        #expect(model.enclosingFolders.isEmpty)
    }

    @Test func failedNavigationLeavesHistoryUntouched() async {
        let model = makeModel()
        await model.connect(to: .test)
        await model.navigate(to: "/home/test/assets")
        await model.navigate(to: "/nexiste/pas")

        #expect(model.errorMessage != nil)
        #expect(model.currentPath == "/home/test/assets")
        #expect(model.history.backStack == ["/home/test"])
    }

    @Test func revealsBookmarkedFileInItsFolder() async {
        let model = makeModel()
        await model.connect(to: .test)
        await model.navigate(to: "/home")

        await model.reveal(PathBookmark(path: "/home/test/assets/app.js", isDirectory: false))
        #expect(model.currentPath == "/home/test/assets")
        #expect(model.selection == ["/home/test/assets/app.js"])

        await model.reveal(PathBookmark(path: "/home/test/assets/disparu.js", isDirectory: false))
        #expect(model.errorMessage?.contains("n'existe plus") == true)
    }

    @Test func openingASignetConnectsStraightToIt() async {
        let model = makeModel()
        await model.open(PathBookmark(path: "/home/test/assets/app.js", isDirectory: false), on: .test)

        #expect(model.isConnected)
        #expect(model.currentPath == "/home/test/assets")
        #expect(model.selection == ["/home/test/assets/app.js"])
        #expect(!model.canGoBack)

        // Déjà connecté au même serveur : simple navigation, avec historique.
        await model.open(PathBookmark(path: "/home/test", isDirectory: true), on: .test)
        #expect(model.currentPath == "/home/test")
        #expect(model.canGoBack)
    }

    @Test func activatingTheConnectedFavoriteReusesTheSession() async {
        let model = makeModel()
        await model.connectOrReuse(.test)
        await model.navigate(to: "/home/test/assets")
        #expect(model.isSession(on: ConnectionConfiguration.test.serverKey))

        await model.connectOrReuse(.test)
        #expect(await server.connectCount == 1)  // pas de nouvelle connexion
        #expect(model.currentPath == "/home/test")  // retour au dossier de départ
        #expect(model.canGoBack)  // historique conservé

        var other = ConnectionConfiguration.test
        other.host = "autre.local"
        #expect(!model.isSession(on: other.serverKey))
    }

    @Test func previewsAFolderWithoutLeavingTheCurrentOne() async throws {
        let model = makeModel()
        await model.connect(to: .test)
        let listing = try await model.contents(of: "/home/test/assets")
        #expect(listing.map(\.name) == ["app.js"])
        #expect(model.currentPath == "/home/test")

        // Clic sur une entrée de l'aperçu : on entre dans le dossier, l'entrée est sélectionnée.
        await model.reveal(listing[0].path)
        #expect(model.currentPath == "/home/test/assets")
        #expect(model.selection == ["/home/test/assets/app.js"])
        #expect(model.canGoBack)
    }

    @Test func unresponsiveServerTimesOutWithAClearMessage() async {
        await server.hangConnections(for: .seconds(3))
        let factory = InMemoryFileSystemFactory(fileSystem: server)
        let model = BrowserModel(
            factory: factory,
            transfers: TransferQueue(factory: factory, maxConcurrent: { 1 }),
            connectionTimeout: .milliseconds(150)
        )
        let start = ContinuousClock.now
        await model.connect(to: .test)

        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(model.connectionState == .disconnected)
        #expect(model.errorMessage?.contains("ne répond pas") == true)
    }

    @Test func cancellingAPendingConnection() async throws {
        await server.hangConnections(for: .milliseconds(400))
        let model = makeModel()
        let attempt = Task { await model.connect(to: .test) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.connectionState == .connecting)

        await model.cancelConnection()
        #expect(model.connectionState == .disconnected)
        #expect(model.title == "MaxFtp")

        await attempt.value  // la tentative abandonnée aboutit plus tard : ignorée
        #expect(model.connectionState == .disconnected)
        #expect(model.errorMessage == nil)
    }

    @Test func reconnectingStartsAFreshHistory() async {
        let model = makeModel()
        await model.connect(to: .test)
        await model.navigate(to: "/home/test/assets")
        await model.connect(to: .test)
        #expect(!model.canGoBack)
    }
}

@MainActor
@Suite("Signets (modèle)")
struct PathBookmarksModelTests {
    let key = ConnectionConfiguration.test.serverKey

    @Test func toggleAddsThenRemovesAndPersists() {
        let repository = InMemoryPathBookmarkRepository()
        let model = PathBookmarksModel(repository: repository)

        model.toggle("/var/www", isDirectory: true, on: key)
        model.add("/var/www", isDirectory: true, on: key)  // doublon ignoré
        #expect(model.bookmarks(for: key).map(\.path) == ["/var/www"])
        #expect(repository.bookmarks[key]?.count == 1)
        #expect(model.bookmarks(for: "ftp://autre@h:21").isEmpty)

        model.toggle("/var/www", isDirectory: true, on: key)
        #expect(model.bookmarks(for: key).isEmpty)
        #expect(repository.bookmarks.isEmpty)
    }

    @Test func reloadsFromRepository() {
        let repository = InMemoryPathBookmarkRepository([key: [PathBookmark(path: "/etc/hosts", isDirectory: false)]])
        let model = PathBookmarksModel(repository: repository)
        #expect(model.bookmark(for: "/etc/hosts", on: key)?.isDirectory == false)
    }
}

@Suite("Navigation à la souris")
struct MouseNavigationTests {
    @Test func sideButtonsMapToBackAndForward() {
        #expect(NavigationDirection(mouseButton: 3) == .back)
        #expect(NavigationDirection(mouseButton: 4) == .forward)
        #expect(NavigationDirection(mouseButton: 2) == nil)
    }

    @Test func swipeDirection() {
        #expect(NavigationDirection(swipeDeltaX: 1) == .back)
        #expect(NavigationDirection(swipeDeltaX: -1) == .forward)
        #expect(NavigationDirection(swipeDeltaX: 0) == nil)
    }
}

@MainActor
@Suite("TransferQueue")
struct TransferQueueTests {
    @Test func overallProgressCoversUnfinishedSizedTransfers() {
        func item(total: Int64, done: Int64, state: TransferItem.State) -> TransferItem {
            let item = TransferItem(job: .replace("/f", with: URL(fileURLWithPath: "/tmp/f")), configuration: .test, onCompletion: nil)
            item.totalBytes = total
            item.transferredBytes = done
            item.state = state
            return item
        }
        #expect(TransferQueue.overallProgress(of: []) == nil)
        #expect(TransferQueue.overallProgress(of: [item(total: 0, done: 0, state: .preparing)]) == nil)

        let items = [
            item(total: 100, done: 50, state: .running),
            item(total: 300, done: 0, state: .waiting),
            item(total: 1_000, done: 1_000, state: .completed),  // terminé : ignoré
        ]
        #expect(TransferQueue.overallProgress(of: items) == 0.125)
    }

    @Test func uploadsAndNotifiesCompletion() async throws {
        let server = InMemoryFileSystem(files: ["/upload/.keep": ""])
        let queue = TransferQueue(factory: InMemoryFileSystemFactory(fileSystem: server), maxConcurrent: { 2 })
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("contenu".utf8).write(to: local)

        var completed = false
        let item = queue.enqueue(.upload(local, into: "/upload"), configuration: .test) { completed = true }
        try await waitUntilFinished(item)

        #expect(item.state == .completed)
        #expect(item.transferredBytes == 7)
        #expect(completed)
        #expect(await server.contents(of: RemotePath("/upload").appending(local.lastPathComponent)) == "contenu")

        queue.clearFinished()
        #expect(queue.items.isEmpty)
    }

    @Test func failedTransferKeepsMessage() async throws {
        let server = InMemoryFileSystem()
        let queue = TransferQueue(factory: InMemoryFileSystemFactory(fileSystem: server))
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("x".utf8).write(to: local)

        let item = queue.enqueue(.upload(local, into: "/does/not/exist"), configuration: .test)
        try await waitUntilFinished(item)

        guard case .failed = item.state else {
            Issue.record("état inattendu : \(item.state)")
            return
        }
    }

    @Test func speedIsSmoothed() {
        let item = TransferItem(job: .replace("/a", with: URL(fileURLWithPath: "/tmp/a")), configuration: .test, onCompletion: nil)
        let start = Date()
        item.record(bytes: 0, at: start)
        item.record(bytes: 1_000, at: start.addingTimeInterval(1))
        #expect(item.bytesPerSecond == 1_000)
        item.record(bytes: 500, at: start.addingTimeInterval(2))  // mise à jour en retard ignorée
        #expect(item.transferredBytes == 1_000)
    }

    private func waitUntilFinished(_ item: TransferItem) async throws {
        for _ in 0..<500 where !item.state.isFinished {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(item.state.isFinished)
    }
}

@Suite("Connexion rapide")
struct QuickConnectResolverTests {
    let resolver = QuickConnectResolver(
        sshConfig: SSHConfig(contents: """
        Host prod
            HostName 10.0.0.5
            User deploy
            IdentityFile /keys/prod
        """),
        defaultIdentityFiles: [URL(fileURLWithPath: "/home/.ssh/id_ed25519")],
        localUsername: "max"
    )

    @Test func resolvesSSHConfigAlias() throws {
        let configuration = try #require(resolver.configuration(for: "prod", password: "", fileExists: { _ in true }))
        #expect(configuration.host == "10.0.0.5")
        #expect(configuration.username == "deploy")
        #expect(configuration.credential == .privateKey(URL(fileURLWithPath: "/keys/prod"), passphrase: nil))
    }

    @Test func fallsBackToDefaultKeyThenPassword() throws {
        let withDefaultKey = try #require(resolver.configuration(for: "host", password: "", fileExists: { $0.path.hasSuffix("id_ed25519") }))
        #expect(withDefaultKey.username == "max")
        #expect(withDefaultKey.credential == .privateKey(URL(fileURLWithPath: "/home/.ssh/id_ed25519"), passphrase: nil))

        let withPassword = try #require(resolver.configuration(for: "host", password: "pw", fileExists: { _ in true }))
        #expect(withPassword.credential == .password("pw"))
    }

    @Test func ftpWithoutUserIsAnonymous() throws {
        let configuration = try #require(resolver.configuration(for: "ftp://mirror.example.org/pub", password: ""))
        #expect(configuration.credential == .anonymous)
        #expect(configuration.initialPath == "/pub")
        #expect(configuration.port == 21)
    }
}

@Suite("Clés d'hôte SSH")
struct HostKeyTrustTests {
    let host = KnownHostIdentifier(host: "example.com", port: 22)

    @Test func knownKeyIsAcceptedSilently() async throws {
        let store = InMemoryHostKeyStore()
        try store.trust("ssh-ed25519 AAAA", for: host)
        let policy = InteractiveHostKeyTrustPolicy(store: store, knownHostsURL: URL(fileURLWithPath: "/nonexistent")) { _ in
            Issue.record("ne doit pas demander")
            return false
        }
        #expect(await policy.evaluate(HostKeyChallenge(host: host, openSSHKey: "ssh-ed25519 AAAA")))
    }

    @Test func unknownKeyIsAskedThenRemembered() async throws {
        let store = InMemoryHostKeyStore()
        let policy = InteractiveHostKeyTrustPolicy(store: store, knownHostsURL: URL(fileURLWithPath: "/nonexistent")) { challenge in
            challenge.status == .unknown
        }
        #expect(await policy.evaluate(HostKeyChallenge(host: host, openSSHKey: "ssh-ed25519 AAAA comment")))
        #expect(try store.trustedKeys(for: host) == ["ssh-ed25519 AAAA"])
    }

    @Test func silentCheckNeverPromptsNorStores() throws {
        let store = InMemoryHostKeyStore()
        let policy = InteractiveHostKeyTrustPolicy(store: store, knownHostsURL: URL(fileURLWithPath: "/nonexistent")) { _ in
            Issue.record("la vérification pendant la poignée de main ne doit jamais demander")
            return true
        }
        let challenge = HostKeyChallenge(host: host, openSSHKey: "ssh-ed25519 AAAA")
        #expect(policy.untrustedStatus(of: challenge) == .unknown)
        #expect(try store.trustedKeys(for: host).isEmpty)

        try store.trust("ssh-ed25519 AAAA", for: host)
        #expect(policy.untrustedStatus(of: challenge) == nil)
    }

    @Test func changedKeyIsFlagged() async throws {
        let store = InMemoryHostKeyStore()
        try store.trust("ssh-ed25519 OLD", for: host)
        let policy = InteractiveHostKeyTrustPolicy(store: store, knownHostsURL: URL(fileURLWithPath: "/nonexistent")) { challenge in
            #expect(challenge.status == .changed)
            return false
        }
        #expect(await policy.evaluate(HostKeyChallenge(host: host, openSSHKey: "ssh-ed25519 NEW")) == false)
    }
}

@Suite("Aperçu Markdown")
struct MarkdownRendererTests {
    func plain(_ markdown: String) -> String {
        String(MarkdownRenderer.render(markdown).characters)
    }

    @Test func headingsAndParagraphsAreSeparated() {
        #expect(plain("# Titre\n\nUn **gras** et `code`.") == "Titre\n\nUn gras et code.")
    }

    @Test func listsGetBulletsAndNumbers() {
        #expect(plain("- un\n- deux\n  - imbriqué") == "•  un\n•  deux\n    ◦  imbriqué")
        #expect(plain("1. a\n2. b") == "1. a\n2. b")
    }

    @Test func codeBlocksQuotesAndTables() {
        #expect(plain("```\ncd ~/x\nls\n```\n\nfin") == "cd ~/x\nls\n\nfin")
        #expect(plain("> cité") == "▎ cité")
        #expect(plain("| A | B |\n|---|---|\n| 1 | 2 |") == "A   │   B\n1   │   2")
    }

    @Test func detectsMarkdownFiles() {
        #expect(PreviewModel.isMarkdown(url: URL(fileURLWithPath: "/tmp/README.MD"), type: .plainText))
        #expect(!PreviewModel.isMarkdown(url: URL(fileURLWithPath: "/tmp/notes.txt"), type: .plainText))
    }
}

@Suite("Aperçu de dossier")
struct DirectorySummaryTests {
    let items = [
        RemoteItem(path: "/d/zeta.txt", kind: .file, size: 100),
        RemoteItem(path: "/d/Alpha.txt", kind: .file, size: 50),
        RemoteItem(path: "/d/src", kind: .directory),
        RemoteItem(path: "/d/.env", kind: .file, size: 10),
        RemoteItem(path: "/d/lien", kind: .symbolicLink, symbolicLinkTarget: "/var"),
    ]

    @Test func foldersFirstThenFilesHiddenExcluded() {
        let summary = DirectorySummary(items: items, showHidden: false)
        #expect(summary.entries.map(\.name) == ["lien", "src", "Alpha.txt", "zeta.txt"])
        #expect(summary.folderCount == 2)
        #expect(summary.fileCount == 2)
        #expect(summary.hiddenCount == 1)
        #expect(summary.totalFileBytes == 150)
        #expect(summary.countsDescription == "2 dossiers · 2 fichiers")
    }

    @Test func showsHiddenWhenAskedAndTruncates() {
        let summary = DirectorySummary(items: items, showHidden: true, limit: 3)
        #expect(summary.hiddenCount == 0)
        #expect(summary.totalFileBytes == 160)
        #expect(summary.entries.count == 3)
        #expect(summary.remainingCount == 2)
    }

    @Test func emptyFolder() {
        let summary = DirectorySummary(items: [RemoteItem(path: "/d/.keep", kind: .file)], showHidden: false)
        #expect(summary.isEmpty)
        #expect(summary.countsDescription == "Vide")
        #expect(DirectorySummary(items: [RemoteItem(path: "/d/a", kind: .file)], showHidden: false).countsDescription == "1 fichier")
    }
}

@Suite("Choix de l'éditeur")
struct EditorChoicesTests {
    let vscode = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
    let typora = URL(fileURLWithPath: "/Applications/Typora.app")
    let installed: (URL) -> Bool = { _ in true }

    @Test func extensionWinsOverDefaultEditor() {
        var choices = EditorChoices(defaultEditor: vscode)
        choices.alwaysOpen(filesNamedLike: "README.MD", with: typora)

        #expect(choices.byExtension == ["md": typora])
        #expect(choices.application(forFileNamed: "notes.md", exists: installed) == typora)
        #expect(choices.application(forFileNamed: "app.js", exists: installed) == vscode)
        #expect(EditorChoices().application(forFileNamed: "app.js", exists: installed) == nil)
    }

    @Test func uninstalledApplicationsAreSkipped() {
        let choices = EditorChoices(defaultEditor: vscode, byExtension: ["md": typora])
        #expect(choices.application(forFileNamed: "a.md", exists: { $0 == vscode }) == vscode)
        #expect(choices.application(forFileNamed: "a.md", exists: { _ in false }) == nil)
    }

    @Test func filesWithoutExtensionHaveTheirOwnKey() {
        var choices = EditorChoices()
        choices.alwaysOpen(filesNamedLike: "Makefile", with: vscode)
        #expect(choices.byExtension[""] == vscode)
        #expect(choices.application(forFileNamed: "Dockerfile", exists: installed) == vscode)
        #expect(choices.application(forFileNamed: "a.txt", exists: installed) == nil)
    }

    @Test func roundTripsThroughData() {
        let choices = EditorChoices(defaultEditor: vscode, byExtension: ["md": typora])
        #expect(EditorChoices(data: choices.data) == choices)
        #expect(EditorChoices(data: Data("corrompu".utf8)) == EditorChoices())
    }

    @MainActor
    @Test func browserUsesTheConfiguredEditor() {
        let factory = InMemoryFileSystemFactory(fileSystem: InMemoryFileSystem(files: [:]))
        let model = BrowserModel(
            factory: factory,
            transfers: TransferQueue(factory: factory, maxConcurrent: { 1 }),
            editorChoices: { EditorChoices(byExtension: ["sh": URL(fileURLWithPath: "/bin")]) }
        )
        #expect(model.preferredEditor(for: RemoteItem(path: "/a/run.sh", kind: .file)) == URL(fileURLWithPath: "/bin"))
        #expect(model.preferredEditor(for: RemoteItem(path: "/a/notes.txt", kind: .file)) == nil)
    }
}

@MainActor
@Suite("Favoris (modèle)")
struct BookmarksModelTests {
    @Test func savesAQuickConnectionWithItsSecret() throws {
        let repository = InMemoryBookmarkRepository()
        let secrets = InMemorySecretStore()
        let model = BookmarksModel(repository: repository, secretStore: secrets)
        #expect(model.bookmark(forServerKey: ConnectionConfiguration.test.serverKey) == nil)

        let bookmark = model.addFavorite(from: .test, name: "  Serveur de test ")

        #expect(bookmark.name == "Serveur de test")
        #expect(repository.bookmarks == [bookmark])
        #expect(try secrets.secret(for: bookmark.secretAccount) == "secret")
        #expect(model.bookmark(forServerKey: ConnectionConfiguration.test.serverKey) == bookmark)
        #expect(model.configuration(for: bookmark) == .test)
    }
}

@Suite("Préférences")
struct AppSettingsTests {
    @Test func hiddenFilesToggleReadsTheCurrentValueEachTime() throws {
        let defaults = try #require(UserDefaults(suiteName: "maxftp-tests-\(UUID().uuidString)"))
        #expect(!defaults.bool(forKey: AppSettings.showHiddenFilesKey))

        AppSettings.toggleShowHiddenFiles(in: defaults)
        #expect(defaults.bool(forKey: AppSettings.showHiddenFilesKey))
        AppSettings.toggleShowHiddenFiles(in: defaults)  // le cas qui ne marchait pas : le retour
        #expect(!defaults.bool(forKey: AppSettings.showHiddenFilesKey))
        AppSettings.toggleShowHiddenFiles(in: defaults)
        #expect(defaults.bool(forKey: AppSettings.showHiddenFilesKey))
    }
}

@MainActor
@Suite("Tableau de bord R2 (modèle)")
struct R2DashboardModelTests {
    let accountID = "0123456789abcdef0123456789abcdef"
    let usage = R2Usage(
        period: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 1),
        storageSamples: [],
        requestsByAction: ["PutObject": 900_000]
    )

    @Test func asksForTokenThenLoads() async throws {
        let provider = StubR2UsageProvider(.success(usage))
        let secrets = InMemorySecretStore()
        let model = R2DashboardModel(accountID: accountID, provider: provider, secretStore: secrets)

        await model.refresh()
        #expect(model.state == .needsToken)
        #expect(provider.receivedTokens.isEmpty)

        await model.saveToken("  jeton \n")
        #expect(provider.receivedTokens == ["jeton"])
        #expect(try secrets.secret(for: R2Account.apiTokenSecretAccount(accountID: accountID)) == "jeton")
        guard case .loaded(let bill) = model.state else { Issue.record("attendu : chargé"); return }
        #expect(bill.requests(.classA) == 900_000)
        #expect(QuotaLevel(ratio: bill.classARatio) == .nearLimit)

        model.forgetToken()
        #expect(model.state == .needsToken)
        #expect(!model.hasToken)
    }

    @Test func showsProviderErrors() async {
        let provider = StubR2UsageProvider(.failure(RemoteError.authenticationFailed("jeton refusé")))
        let secrets = InMemorySecretStore([R2Account.apiTokenSecretAccount(accountID: accountID): "x"])
        let model = R2DashboardModel(accountID: accountID, provider: provider, secretStore: secrets)
        await model.refresh()
        #expect(model.state == .failed(RemoteError.authenticationFailed("jeton refusé").localizedDescription))
    }

    @Test func quotaLevels() {
        #expect(QuotaLevel(ratio: 0.5) == .comfortable)
        #expect(QuotaLevel(ratio: 0.8) == .nearLimit)
        #expect(QuotaLevel(ratio: 1.0) == .exceeded)
    }

    @Test func dashboardOnlyForR2Endpoints() {
        let app = AppEnvironment(dependencies: AppDependencies(
            bookmarkRepository: InMemoryBookmarkRepository(),
            pathBookmarkRepository: InMemoryPathBookmarkRepository(),
            secretStore: InMemorySecretStore(),
            fileSystemFactory: InMemoryFileSystemFactory(fileSystem: InMemoryFileSystem(configuration: .test)),
            r2UsageProvider: StubR2UsageProvider(.success(usage))
        ))
        let r2 = ConnectionConfiguration(connectionProtocol: .s3, host: "\(accountID).r2.cloudflarestorage.com", username: "k", credential: .password("s"))
        let aws = ConnectionConfiguration(connectionProtocol: .s3, host: "s3.amazonaws.com", username: "k", credential: .password("s"))
        #expect(app.makeR2DashboardModel(for: r2)?.accountID == accountID)
        #expect(app.makeR2DashboardModel(for: aws) == nil)
    }
}
