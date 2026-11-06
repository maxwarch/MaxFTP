import AppKit
import Foundation
import MaxFtpCore
import Observation
import UniformTypeIdentifiers

/// Charge l'aperçu du fichier sélectionné (téléchargement en tâche de fond, mis en cache).
@MainActor
@Observable
final class PreviewModel {
    enum Content {
        case none
        /// Contenu brut du dossier ; le filtrage des fichiers cachés se fait à l'affichage.
        case directory([RemoteItem])
        case loading
        case image(NSImage)
        case text(String)
        case markdown(AttributedString)
        case quickLook(URL)
        case tooLarge
        case failed(String)
    }

    private(set) var content: Content = .none

    /// Au-delà, un fichier texte est tronqué à l'affichage.
    private let maxTextCharacters = 200_000

    /// Appelé par `.task(id:)` : annulé automatiquement si la sélection change.
    func load(_ item: RemoteItem?, using browser: BrowserModel, sizeLimit: Int64 = AppSettings.previewSizeLimit) async {
        guard let item else { content = .none; return }
        guard item.isDirectory || (item.size ?? 0) <= sizeLimit else { content = .tooLarge; return }

        content = .loading
        do {
            // Petit délai : évite de télécharger chaque fichier quand on parcourt la liste au clavier.
            try await Task.sleep(for: .milliseconds(250))
            if item.isDirectory {
                let items = try await browser.contents(of: item.path)
                try Task.checkCancellation()
                content = .directory(items)
                return
            }
            let url = try await browser.localCopy(of: item)
            try Task.checkCancellation()
            content = Self.content(for: url, type: FileIcons.contentType(for: item), maxCharacters: maxTextCharacters)
        } catch is CancellationError {
            // La sélection a changé ; le nouvel appel s'occupe de l'affichage.
        } catch {
            content = .failed(error.localizedDescription)
        }
    }

    static func content(for url: URL, type: UTType, maxCharacters: Int) -> Content {
        if type.conforms(to: .image), let image = NSImage(contentsOf: url) {
            return .image(image)
        }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) || type == .data,
           let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            let shown = text.count > maxCharacters ? String(text.prefix(maxCharacters)) + "\n…" : text
            return isMarkdown(url: url, type: type) ? .markdown(MarkdownRenderer.render(shown)) : .text(shown)
        }
        return .quickLook(url)
    }

    nonisolated static func isMarkdown(url: URL, type: UTType) -> Bool {
        if let markdown = UTType("net.daringfireball.markdown"), type.conforms(to: markdown) { return true }
        return ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
    }
}
