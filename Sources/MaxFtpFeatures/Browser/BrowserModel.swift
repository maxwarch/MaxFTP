import AppKit
import Foundation
import MaxFtpCore
import Observation

/// Feuilles / dialogues que l'explorateur peut afficher.
public enum BrowserPrompt: Identifiable, Equatable {
    case newFolder
    case rename(RemoteItem)
    case permissions(RemoteItem)

    public var id: String {
        switch self {
        case .newFolder: "newFolder"
        case .rename(let item): "rename-\(item.path)"
        case .permissions(let item): "permissions-\(item.path)"
        }
    }
}

/// État et actions d'UNE fenêtre connectée à UN serveur (modèle de vue MVVM).
///
/// Les vues ne parlent jamais au réseau directement : elles appellent les
/// méthodes de ce modèle, qui orchestre ``RemoteFileSystem`` et ``TransferQueue``.
@MainActor
@Observable
public final class BrowserModel {
    public enum ConnectionState: Equatable {
        case disconnected, connecting, connected
    }

    // MARK: État observé par les vues

    public private(set) var connectionState: ConnectionState = .disconnected
    public private(set) var configuration: ConnectionConfiguration?
    public private(set) var currentPath: RemotePath = .root
    public private(set) var items: [RemoteItem] = []
    public private(set) var isLoading = false
    public private(set) var history = NavigationHistory()

    public var selection: Set<RemoteItem.ID> = []
    public var sortOrder: [KeyPathComparator<RemoteItem>] = [KeyPathComparator(\.name, comparator: .localizedStandard)]
    public var showHiddenFiles = false
    public var prompt: BrowserPrompt?
    public var pendingDeletion: [RemoteItem] = []
    public var errorMessage: String?
    public var quickLookURL: URL?

    // MARK: Dépendances

    public private(set) var fileSystem: (any RemoteFileSystem)?
    private let factory: any RemoteFileSystemFactory
    private let transfers: TransferQueue
    private let editing: ExternalEditingService
    private let editorChoices: () -> EditorChoices
    private let connectionTimeout: Duration
    private let userPrompts: UserPromptTracker
    private var connectionGeneration = 0

    public init(
        factory: any RemoteFileSystemFactory,
        transfers: TransferQueue,
        editorChoices: @escaping () -> EditorChoices = { AppSettings.editorChoices },
        connectionTimeout: Duration = .seconds(30),
        userPrompts: UserPromptTracker = UserPromptTracker()
    ) {
        self.userPrompts = userPrompts
        self.factory = factory
        self.transfers = transfers
        self.editing = ExternalEditingService(transfers: transfers)
        self.editorChoices = editorChoices
        self.connectionTimeout = connectionTimeout
    }

    /// Application d'édition retenue pour ce fichier (`nil` = application du système).
    public func preferredEditor(for item: RemoteItem) -> URL? {
        editorChoices().application(forFileNamed: item.name)
    }

    // MARK: Valeurs dérivées

    public var isConnected: Bool { connectionState == .connected }

    /// Serveur de la session en cours ; « MaxFtp » une fois déconnecté.
    public var title: String {
        guard connectionState != .disconnected, let configuration else { return "MaxFtp" }
        return configuration.displayName
    }

    /// Clé des signets du serveur connecté.
    public var serverKey: String? { isConnected ? configuration?.serverKey : nil }

    /// Dossiers englobant le dossier courant, du parent direct jusqu'à la racine.
    public var enclosingFolders: [RemotePath] { currentPath.ancestors.dropLast().reversed() }

    public var canGoBack: Bool { isConnected && history.canGoBack }
    public var canGoForward: Bool { isConnected && history.canGoForward }

    /// Éléments filtrés et triés, dossiers en premier (comme le Finder).
    public var visibleItems: [RemoteItem] {
        let filtered = showHiddenFiles ? items : items.filter { !$0.isHidden }
        let sorted = filtered.sorted(using: sortOrder)
        return sorted.filter(\.isDirectory) + sorted.filter { !$0.isDirectory }
    }

    public var selectedItems: [RemoteItem] {
        items.filter { selection.contains($0.id) }
    }

    public var singleSelectedItem: RemoteItem? {
        selection.count == 1 ? selectedItems.first : nil
    }

    // MARK: Connexion

    public func connect(to configuration: ConnectionConfiguration) async {
        await disconnect()
        connectionGeneration += 1
        let generation = connectionGeneration

        let fileSystem = factory.makeFileSystem(for: configuration)
        self.fileSystem = fileSystem
        self.configuration = configuration
        connectionState = .connecting
        history.reset()

        do {
            // Délai global : certains serveurs SSH (GitLab…) acceptent la session mais
            // ne répondent jamais à l'ouverture de SFTP ; sans ce garde-fou, on attendrait à vie.
            let prompts = userPrompts
            let startPath = try await withTimeout(connectionTimeout, pausedWhile: { prompts.isPrompting }) {
                try await fileSystem.connect()
                if let initial = configuration.initialPath { return initial }
                return try await fileSystem.homeDirectory()
            }
            guard generation == connectionGeneration else { return }  // annulée, ou une autre connexion a pris le relais
            connectionState = .connected
            await load(startPath)  // premier dossier : pas d'entrée dans l'historique
        } catch {
            guard generation == connectionGeneration else { return }
            if error is TimeoutError {
                report(RemoteError.connectionFailed(
                    "\(configuration.host) ne répond pas (délai de \(connectionTimeout.components.seconds) s dépassé). "
                        + "Vérifiez qu'il accepte bien \(configuration.connectionProtocol.displayName) : "
                        + "un serveur Git, par exemple, n'autorise pas la navigation de fichiers."
                ))
            } else {
                report(error)
            }
            await disconnect()
        }
    }

    /// Bouton « Annuler » pendant la connexion : la tentative en cours est abandonnée
    /// et son résultat ignoré s'il arrive plus tard.
    public func cancelConnection() async {
        guard connectionState == .connecting else { return }
        connectionGeneration += 1
        await disconnect()
    }

    /// Serveur visé par la session de la fenêtre (y compris pendant la connexion).
    public func isSession(on serverKey: String) -> Bool {
        connectionState != .disconnected && configuration?.serverKey == serverKey
    }

    /// Favori activé : réutilise la session si la fenêtre est déjà sur ce serveur
    /// (retour au dossier de départ, historique conservé), sinon se connecte.
    public func connectOrReuse(_ configuration: ConnectionConfiguration) async {
        guard isConnected, let fileSystem, self.configuration?.serverKey == configuration.serverKey else {
            await connect(to: configuration)
            return
        }
        let start: RemotePath
        if let initial = configuration.initialPath {
            start = initial
        } else {
            do {
                start = try await fileSystem.homeDirectory()
            } catch {
                report(error)
                return
            }
        }
        await navigate(to: start)
    }

    public func disconnect() async {
        editing.stopAll()
        let previous = fileSystem
        fileSystem = nil
        connectionState = .disconnected
        items = []
        selection = []
        await previous?.disconnect()
    }

    // MARK: Navigation

    /// Nouvelle navigation : alimente l'historique « Précédent ».
    public func navigate(to path: RemotePath) async {
        let origin = currentPath
        if await load(path) {
            history.visit(from: origin, to: path)
            selectEntry(leadingTo: origin)
        }
    }

    public func goBack() async {
        guard isConnected, let target = history.backTarget else { return }
        let origin = currentPath
        if await load(target) {
            history.didGoBack(from: origin)
            selectEntry(leadingTo: origin)
        }
    }

    public func goForward() async {
        guard isConnected, let target = history.forwardTarget else { return }
        let origin = currentPath
        if await load(target) {
            history.didGoForward(from: origin)
            selectEntry(leadingTo: origin)
        }
    }

    /// En remontant (Précédent, dossier parent, fil d'Ariane), sélectionne le dossier
    /// d'où l'on vient, comme le Finder : on garde ses repères.
    private func selectEntry(leadingTo origin: RemotePath) {
        guard let entry = origin.child(under: currentPath), items.contains(where: { $0.id == entry }) else { return }
        selection = [entry]
    }

    public func refresh() async {
        let previousSelection = selection
        await load(currentPath)
        selection = previousSelection.filter { id in items.contains { $0.id == id } }
    }

    /// Ouvre un signet : le dossier lui-même, ou le dossier parent avec le fichier sélectionné.
    public func reveal(_ bookmark: PathBookmark) async {
        guard bookmark.isDirectory else {
            await reveal(bookmark.path)
            return
        }
        await navigate(to: bookmark.path)
    }

    /// Ouvre le dossier qui contient `path` et y sélectionne l'élément.
    public func reveal(_ path: RemotePath) async {
        if currentPath != path.parent {
            await navigate(to: path.parent)
        }
        selectRevealedFile(path)
    }

    /// Contenu d'un dossier sans changer de dossier courant (aperçu de l'inspecteur).
    public func contents(of path: RemotePath) async throws -> [RemoteItem] {
        guard let fileSystem else { throw RemoteError.notConnected }
        return try await fileSystem.contentsOfDirectory(at: path)
    }

    /// Ouvre un signet d'un favori : se connecte d'abord au serveur si la fenêtre
    /// n'y est pas déjà, en arrivant directement sur le dossier du signet.
    public func open(_ bookmark: PathBookmark, on configuration: ConnectionConfiguration) async {
        if isConnected, self.configuration?.serverKey == configuration.serverKey {
            await reveal(bookmark)
            return
        }
        var target = configuration
        target.initialPath = bookmark.isDirectory ? bookmark.path : bookmark.path.parent
        await connect(to: target)
        guard isConnected, !bookmark.isDirectory else { return }
        selectRevealedFile(bookmark.path)
    }

    private func selectRevealedFile(_ path: RemotePath) {
        guard currentPath == path.parent else { return }  // dossier inaccessible : erreur déjà signalée
        if items.contains(where: { $0.id == path }) {
            selection = [path]
        } else {
            errorMessage = "« \(path.string) » n'existe plus sur le serveur."
        }
    }

    /// Liste `path` et en fait le dossier courant. Renvoie `false` en cas d'échec.
    @discardableResult
    private func load(_ path: RemotePath) async -> Bool {
        guard let fileSystem else { return false }
        isLoading = true
        defer { isLoading = false }
        do {
            let listing = try await fileSystem.contentsOfDirectory(at: path)
            items = listing
            currentPath = path
            selection = []
            return true
        } catch {
            report(error)
            return false
        }
    }

    public func goToParent() async {
        guard !currentPath.isRoot else { return }
        await navigate(to: currentPath.parent)
    }

    /// Action principale (double-clic / Entrée) : ouvre un dossier, édite un fichier.
    public func open(_ ids: Set<RemoteItem.ID>) async {
        let targets = items.filter { ids.contains($0.id) }
        if targets.count == 1, let item = targets.first, item.canBeOpenedAsDirectory {
            await navigate(to: item.path)
        } else {
            for item in targets where !item.isDirectory {
                await edit(item, with: nil)
            }
        }
    }

    // MARK: Opérations sur fichiers

    public func createFolder(named name: String) async {
        await perform { fs in
            let path = try self.childPath(named: name)
            try await fs.createDirectory(at: path)
            await self.refresh()
            self.selection = [path]
        }
    }

    public func rename(_ item: RemoteItem, to name: String) async {
        await perform { fs in
            let destination = try self.childPath(named: name, in: item.path.parent)
            guard destination != item.path else { return }
            try await fs.moveItem(at: item.path, to: destination)
            await self.refresh()
            self.selection = [destination]
        }
    }

    public func requestDeletion(of ids: Set<RemoteItem.ID>? = nil) {
        pendingDeletion = items.filter { (ids ?? selection).contains($0.id) }
    }

    public func confirmDeletion() async {
        let targets = pendingDeletion
        pendingDeletion = []
        await delete(targets)
    }

    /// Supprime les éléments donnés (récursif pour les dossiers).
    ///
    /// La vue de confirmation passe la liste capturée au moment du clic : la fermeture
    /// du dialogue vide `pendingDeletion` avant que la tâche asynchrone ne s'exécute.
    public func delete(_ targets: [RemoteItem]) async {
        guard !targets.isEmpty else { return }
        await perform { fs in
            for item in targets {
                try await fs.removeItem(item)
            }
            await self.refresh()
        }
    }

    public func setPermissions(_ permissions: POSIXPermissions, for item: RemoteItem) async {
        await perform { fs in
            try await fs.setPermissions(permissions, at: item.path)
            await self.refresh()
        }
    }

    // MARK: Transferts

    /// Glisser-déposer depuis le Finder ou bouton « Envoyer ».
    public func upload(_ urls: [URL], into directory: RemotePath? = nil) {
        guard let configuration else { return }
        let destination = directory ?? currentPath
        for url in urls where url.isFileURL {
            transfers.enqueue(.upload(url, into: destination), configuration: configuration) { [weak self] in
                guard let self, self.currentPath == destination else { return }
                Task { await self.refresh() }
            }
        }
    }

    public func download(_ items: [RemoteItem], to directory: URL) {
        guard let configuration else { return }
        for item in items {
            transfers.enqueue(.download(item, into: directory), configuration: configuration)
        }
    }

    // MARK: Aperçu & édition externe

    /// Barre d'espace : bascule l'aperçu QuickLook plein panneau.
    public func toggleQuickLook() async {
        if quickLookURL != nil {
            quickLookURL = nil
            return
        }
        guard let item = singleSelectedItem, !item.isDirectory else { return }
        quickLookURL = try? await localCopy(of: item)
    }

    /// Ouvre le fichier dans un éditeur externe et ré-uploade chaque sauvegarde.
    /// - Parameter application: `nil` = éditeur des Réglages (extension, puis défaut), sinon celui du système.
    public func edit(_ item: RemoteItem, with application: URL?) async {
        guard let configuration else { return }
        let application = application ?? preferredEditor(for: item)
        await perform { fs in
            let localURL = LocalWorkspace.editingURL(for: item)
            try await fs.download(item.path, to: localURL) { _ in }
            try await self.editing.beginEditing(localURL, remotePath: item.path, configuration: configuration, application: application) { [weak self] in
                guard let self, self.currentPath == item.path.parent else { return }
                Task { await self.refresh() }
            }
        }
    }

    /// Copie locale mise en cache (aperçus, QuickLook).
    public func localCopy(of item: RemoteItem) async throws -> URL {
        guard let fileSystem, let configuration else { throw RemoteError.notConnected }
        let url = LocalWorkspace.cachedCopyURL(for: item, host: configuration.host)
        if !FileManager.default.fileExists(atPath: url.path) {
            let partial = url.appendingPathExtension("partial")
            try await fileSystem.download(item.path, to: partial) { _ in }
            try FileManager.default.moveItem(at: partial, to: url)
        }
        return url
    }

    public func copyPathToPasteboard(_ item: RemoteItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.path.string, forType: .string)
    }

    // MARK: Utilitaires

    private func childPath(named name: String, in directory: RemotePath? = nil) throws -> RemotePath {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            throw RemoteError.invalidPath(name)
        }
        return (directory ?? currentPath).appending(trimmed)
    }

    /// Exécute une opération réseau en centralisant chargement et erreurs.
    private func perform(_ operation: (any RemoteFileSystem) async throws -> Void) async {
        guard let fileSystem else {
            report(RemoteError.notConnected)
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            try await operation(fileSystem)
        } catch {
            report(error)
        }
    }

    private func report(_ error: any Error) {
        guard !(error is CancellationError) else { return }
        errorMessage = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
