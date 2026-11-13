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
    private(set) var canEdit = false
    private(set) var isTruncated = false
    private(set) var originalText = ""
    var draftText = ""
    var isEditing = false
    private(set) var isSaving = false
    var saveError: String?

    var hasUnsavedChanges: Bool { isEditing && draftText != originalText }

    private var loadedPath: RemotePath?
    private var isMarkdownFile = false

    /// Au-delà, un fichier texte est tronqué à l'affichage.
    private let maxTextCharacters = 200_000

    /// Appelé par `.task(id:)` : annulé automatiquement si la sélection change.
    func load(_ item: RemoteItem?, using browser: BrowserModel, sizeLimit: Int64 = AppSettings.previewSizeLimit) async {
        // Ne pas interrompre une édition en cours si le rafraîchissement automatique met à jour la liste.
        if let item, item.path == loadedPath, isEditing { return }

        if item?.path != loadedPath {
            resetEditingState()
        }
        loadedPath = item?.path

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
            let type = FileIcons.contentType(for: item)
            if let loaded = Self.textPayload(for: url, type: type, maxCharacters: maxTextCharacters) {
                content = loaded.content
                isMarkdownFile = loaded.isMarkdown
                isTruncated = loaded.isTruncated
                canEdit = !loaded.isTruncated
                originalText = loaded.isTruncated ? "" : loaded.rawText
            } else {
                content = Self.content(for: url, type: type, maxCharacters: maxTextCharacters)
                canEdit = false
                isTruncated = false
                originalText = ""
            }
        } catch is CancellationError {
            // La sélection a changé ; le nouvel appel s'occupe de l'affichage.
        } catch {
            content = .failed(error.localizedDescription)
        }
    }

    func beginEditing() {
        guard canEdit else { return }
        draftText = originalText
        saveError = nil
        isEditing = true
    }

    func cancelEditing() {
        isEditing = false
        draftText = originalText
        saveError = nil
    }

    func save(item: RemoteItem, using browser: BrowserModel) async {
        guard isEditing, !isSaving else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            try await browser.saveText(draftText, to: item)
            originalText = draftText
            content = isMarkdownFile ? .markdown(MarkdownRenderer.render(draftText)) : .text(draftText)
            isEditing = false
        } catch {
            saveError = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func resetEditingState() {
        isEditing = false
        canEdit = false
        isTruncated = false
        isMarkdownFile = false
        originalText = ""
        draftText = ""
        saveError = nil
    }

    static func content(for url: URL, type: UTType, maxCharacters: Int) -> Content {
        if type.conforms(to: .image), let image = NSImage(contentsOf: url) {
            return .image(image)
        }
        if let loaded = textPayload(for: url, type: type, maxCharacters: maxCharacters) {
            return loaded.content
        }
        return .quickLook(url)
    }

    private static func textPayload(
        for url: URL,
        type: UTType,
        maxCharacters: Int
    ) -> (content: Content, rawText: String, isMarkdown: Bool, isTruncated: Bool)? {
        let isKnownText = type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) || type == .data
        guard isKnownText || type.isDynamic,
              let data = try? Data(contentsOf: url),
              !data.contains(0),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let truncated = text.count > maxCharacters
        let shown = truncated ? String(text.prefix(maxCharacters)) + "\n…" : text
        let markdown = isMarkdown(url: url, type: type)
        let content: Content = markdown ? .markdown(MarkdownRenderer.render(shown)) : .text(shown)
        return (content, text, markdown, truncated)
    }

    nonisolated static func isMarkdown(url: URL, type: UTType) -> Bool {
        if let markdown = UTType("net.daringfireball.markdown"), type.conforms(to: markdown) { return true }
        return ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
    }
}
