import MaxFtpCore
import SwiftUI

/// Bouton étoile de la barre d'outils : clic = (dé)marquer le dossier courant,
/// flèche = liste des signets du serveur.
struct SignetsToolbarMenu: View {
    let browser: BrowserModel
    let signets: PathBookmarksModel

    var body: some View {
        if let serverKey = browser.serverKey {
            let isMarked = signets.bookmark(for: browser.currentPath, on: serverKey) != nil
            Menu {
                SignetsMenuContent(browser: browser, signets: signets, serverKey: serverKey)
            } label: {
                Label("Signets", systemImage: isMarked ? "star.fill" : "star")
            } primaryAction: {
                signets.toggle(browser.currentPath, isDirectory: true, on: serverKey)
            }
            .help(isMarked ? "Retirer ce dossier des signets (⌘D)" : "Ajouter ce dossier aux signets (⌘D)")
        } else {
            Button {} label: { Label("Signets", systemImage: "star") }
                .disabled(true)
        }
    }
}

private struct SignetsMenuContent: View {
    let browser: BrowserModel
    let signets: PathBookmarksModel
    let serverKey: String

    var body: some View {
        let current = browser.currentPath
        if let existing = signets.bookmark(for: current, on: serverKey) {
            Button("Retirer « \(current.name) » des signets") { signets.remove(existing, on: serverKey) }
        } else {
            Button("Ajouter « \(current.name) » aux signets") { signets.add(current, isDirectory: true, on: serverKey) }
        }
        if let item = browser.singleSelectedItem, signets.bookmark(for: item.path, on: serverKey) == nil {
            Button("Ajouter « \(item.name) » aux signets") {
                signets.add(item.path, isDirectory: item.canBeOpenedAsDirectory, on: serverKey)
            }
        }
        Divider()
        let list = signets.bookmarks(for: serverKey)
        if list.isEmpty {
            Text("Aucun signet pour ce serveur")
        }
        ForEach(list) { signet in
            Button {
                Task { await browser.reveal(signet) }
            } label: {
                Label(signet.name, systemImage: signet.isDirectory ? "folder" : "doc")
            }
        }
    }
}
