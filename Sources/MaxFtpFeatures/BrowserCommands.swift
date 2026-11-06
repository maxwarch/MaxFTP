import SwiftUI

// Clés écrites à la main plutôt qu'avec la macro `@Entry`, pour compiler aussi
// avec les seuls Command Line Tools (sans Xcode, les plugins de macros SwiftUI manquent).
private struct BrowserModelKey: FocusedValueKey {
    typealias Value = BrowserModel
}

private struct PathBookmarksKey: FocusedValueKey {
    typealias Value = PathBookmarksModel
}

private struct InspectorVisibilityKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    /// Modèle de la fenêtre active, pour les commandes de la barre de menus.
    var browserModel: BrowserModel? {
        get { self[BrowserModelKey.self] }
        set { self[BrowserModelKey.self] = newValue }
    }

    var pathBookmarks: PathBookmarksModel? {
        get { self[PathBookmarksKey.self] }
        set { self[PathBookmarksKey.self] = newValue }
    }

    var inspectorVisibility: Binding<Bool>? {
        get { self[InspectorVisibilityKey.self] }
        set { self[InspectorVisibilityKey.self] = newValue }
    }
}

/// Menu « Serveur » et raccourcis clavier, appliqués à la fenêtre active.
public struct BrowserCommands: Commands {
    @FocusedValue(\.browserModel) private var browser
    @FocusedValue(\.pathBookmarks) private var pathBookmarks
    @FocusedValue(\.inspectorVisibility) private var inspectorVisibility

    public init() {}

    public var body: some Commands {
        CommandMenu("Serveur") {
            Button("Actualiser") { Task { await browser?.refresh() } }
                .keyboardShortcut("r")
                .disabled(browser?.isConnected != true)

            Button("Précédent") { Task { await browser?.goBack() } }
                .keyboardShortcut("[")
                .disabled(browser?.canGoBack != true)

            Button("Suivant") { Task { await browser?.goForward() } }
                .keyboardShortcut("]")
                .disabled(browser?.canGoForward != true)

            Button("Dossier parent") { Task { await browser?.goToParent() } }
                .keyboardShortcut(.upArrow)
                .disabled(browser?.isConnected != true)

            Button("Ajouter / retirer des signets") {
                if let browser, let serverKey = browser.serverKey {
                    pathBookmarks?.toggle(browser.currentPath, isDirectory: true, on: serverKey)
                }
            }
            .keyboardShortcut("d")
            .disabled(browser?.serverKey == nil)

            Divider()

            Button("Nouveau dossier…") { browser?.prompt = .newFolder }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(browser?.isConnected != true)

            Button("Envoyer des fichiers…") { browser?.upload(LocalWorkspace.chooseFilesToUpload()) }
                .keyboardShortcut("u")
                .disabled(browser?.isConnected != true)

            Button("Supprimer…") { browser?.requestDeletion() }
                .keyboardShortcut(.delete)
                .disabled(browser?.selection.isEmpty != false)

            Divider()

            Button("Se déconnecter") { Task { await browser?.disconnect() } }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(browser?.isConnected != true)
        }

        CommandGroup(after: .sidebar) {
            // Même raccourci que le Finder (⇧⌘.) ; préférence partagée avec les Réglages.
            // Libellé tiré du modèle de la fenêtre (observé, donc à jour) ; l'action relit
            // la préférence au moment du clic, voir `AppSettings.toggleShowHiddenFiles`.
            Button(browser?.showHiddenFiles == true ? "Masquer les fichiers cachés" : "Afficher les fichiers cachés") {
                AppSettings.toggleShowHiddenFiles()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])

            Button("Afficher / masquer l'inspecteur") { inspectorVisibility?.wrappedValue.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}
