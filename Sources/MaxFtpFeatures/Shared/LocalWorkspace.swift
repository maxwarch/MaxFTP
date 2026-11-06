import AppKit
import CryptoKit
import Foundation
import MaxFtpCore

/// Emplacements temporaires locaux (aperçus, édition externe) et panneaux AppKit.
@MainActor
enum LocalWorkspace {
    private static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MaxFtp", isDirectory: true)
    }

    /// Copie locale stable d'un fichier distant : même hôte + chemin + taille + date ⇒ même URL.
    /// Permet de réutiliser un aperçu déjà téléchargé.
    static func cachedCopyURL(for item: RemoteItem, host: String) -> URL {
        let key = "\(host)|\(item.path.string)|\(item.size ?? -1)|\(item.modificationDate?.timeIntervalSince1970 ?? 0)"
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("Previews/\(digest)/\(item.name)")
    }

    /// Dossier neuf pour une session d'édition externe.
    static func editingURL(for item: RemoteItem) -> URL {
        root.appendingPathComponent("Editing/\(UUID().uuidString)/\(item.name)")
    }

    static func chooseFilesToUpload() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Choisir les éléments à envoyer"
        panel.prompt = "Envoyer"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func chooseDownloadDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choisir le dossier de destination"
        panel.prompt = "Télécharger ici"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Choix d'une application. Avec `alwaysFileName`, propose la case
    /// « Toujours ouvrir les fichiers .ext avec cette application » (comme le Finder).
    static func chooseApplication(
        title: String = "Choisir l'éditeur",
        prompt: String = "Éditer",
        alwaysFileName: String? = nil
    ) -> (application: URL, always: Bool)? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        var checkbox: NSButton?
        if let alwaysFileName {
            let key = EditorChoices.extensionKey(forFileNamed: alwaysFileName)
            let label = key.isEmpty
                ? "Toujours ouvrir les fichiers sans extension avec cette application"
                : "Toujours ouvrir les fichiers .\(key) avec cette application"
            let button = NSButton(checkboxWithTitle: label, target: nil, action: nil)
            button.sizeToFit()
            let container = NSView(frame: NSRect(x: 0, y: 0, width: button.frame.width + 40, height: button.frame.height + 20))
            button.setFrameOrigin(NSPoint(x: 20, y: 10))
            container.addSubview(button)
            panel.accessoryView = container
            panel.isAccessoryViewDisclosed = true
            checkbox = button
        }

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url, checkbox?.state == .on)
    }

    static func choosePrivateKey(startingAt path: String?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choisir une clé privée SSH"
        panel.showsHiddenFiles = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).deletingLastPathComponent() }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        return panel.runModal() == .OK ? panel.url : nil
    }
}
