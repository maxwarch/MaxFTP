import MaxFtpCore
import Quartz
import SwiftUI

/// Panneau latéral droit : métadonnées + aperçu du fichier ou du dossier sélectionné ;
/// sans sélection, résumé du dossier courant.
struct InspectorView: View {
    let browser: BrowserModel
    @State private var preview = PreviewModel()

    var body: some View {
        Group {
            if let item = browser.singleSelectedItem {
                VStack(alignment: .leading, spacing: 0) {
                    MetadataSection(item: item)
                        .padding()
                    Divider()
                    PreviewSection(content: preview.content, browser: browser)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id(item.id)  // nouvel élément : on repart d'un aperçu vierge
                }
            } else if browser.isConnected && browser.selection.isEmpty {
                CurrentFolderOverview(browser: browser)
            } else {
                ContentUnavailableView(
                    browser.selection.isEmpty ? "Aucune sélection" : "\(browser.selection.count) éléments",
                    systemImage: "doc.text.magnifyingglass"
                )
            }
        }
        .task(id: browser.singleSelectedItem) {
            await preview.load(browser.singleSelectedItem, using: browser)
        }
    }
}

private struct MetadataSection: View {
    let item: RemoteItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: FileIcons.icon(for: item))
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Text(FileIcons.contentType(for: item).localizedDescription ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                row("Taille", Formatting.size(of: item))
                row("Modifié", Formatting.date(item.modificationDate))
                row("Permissions", Formatting.permissions(item.permissions))
                if let owner = item.owner {
                    row("Propriétaire", [owner, item.group].compactMap { $0 }.joined(separator: ":"))
                }
                if let target = item.symbolicLinkTarget {
                    row("Cible", target)
                }
                row("Chemin", item.path.string)
            }
            .font(.callout)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).lineLimit(3)
        }
    }
}

private struct PreviewSection: View {
    let content: PreviewModel.Content
    let browser: BrowserModel

    var body: some View {
        switch content {
        case .none:
            Color.clear
        case .directory(let items):
            FolderPreview(items: items, browser: browser)
        case .loading:
            ProgressView("Chargement de l'aperçu…")
        case .tooLarge:
            ContentUnavailableView("Fichier trop volumineux", systemImage: "eye.slash", description: Text("Appuyez sur Espace pour un aperçu complet."))
        case .failed(let message):
            ContentUnavailableView("Aperçu indisponible", systemImage: "exclamationmark.triangle", description: Text(message))
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding()
        case .text(let text):
            // Le contenu occupe au moins tout le panneau : un texte court reste collé
            // en haut à gauche au lieu d'être centré par la ScrollView à deux axes.
            GeometryReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
                }
            }
        case .markdown(let text):
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
        case .quickLook(let url):
            QuickLookView(url: url)
        }
    }
}

/// Sans sélection : résumé du dossier courant. Pas de liste, elle ferait doublon
/// avec l'explorateur juste à côté.
private struct CurrentFolderOverview: View {
    let browser: BrowserModel

    var body: some View {
        let summary = DirectorySummary(items: browser.items, showHidden: browser.showHiddenFiles)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading) {
                    Text(browser.currentPath.isRoot ? "/" : browser.currentPath.name)
                        .font(.headline)
                        .lineLimit(2)
                    Text("Dossier courant")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                row("Contenu", summary.countsDescription)
                if summary.fileCount > 0 {
                    row("Fichiers", Formatting.byteCount(summary.totalFileBytes))
                }
                if summary.hiddenCount > 0 {
                    row("Cachés", "\(summary.hiddenCount)")
                }
                row("Chemin", browser.currentPath.string)
            }
            .font(.callout)

            Text("Sélectionnez un élément pour afficher ses détails et son aperçu.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).lineLimit(3)
        }
    }
}

/// Aperçu d'un dossier sélectionné : clic sur un sous-dossier = on y entre ;
/// clic sur un fichier = son aperçu s'affiche dessous, sans changer de dossier.
private struct FolderPreview: View {
    let items: [RemoteItem]
    let browser: BrowserModel
    @State private var selectedFile: RemoteItem?
    @State private var filePreview = PreviewModel()

    /// Hauteur maximale de la liste quand un aperçu de fichier occupe le bas du panneau.
    private let compactListHeight: CGFloat = 220

    var body: some View {
        VStack(spacing: 0) {
            DirectoryContentsView(
                summary: DirectorySummary(items: items, showHidden: browser.showHiddenFiles),
                selectedID: selectedFile?.id,
                maxListHeight: selectedFile == nil ? nil : compactListHeight
            ) { child in
                if child.canBeOpenedAsDirectory {
                    Task { await browser.navigate(to: child.path) }
                } else {
                    selectedFile = selectedFile == child ? nil : child  // re-clic : referme l'aperçu
                }
            }
            if let file = selectedFile {
                Divider()
                HStack(spacing: 6) {
                    Image(nsImage: FileIcons.icon(for: file))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(file.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(Formatting.size(of: file))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button {
                        selectedFile = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Fermer l'aperçu")
                    .accessibilityLabel("Fermer l'aperçu")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                PreviewSection(content: filePreview.content, browser: browser)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: selectedFile) {
            await filePreview.load(selectedFile, using: browser)
        }
    }
}

/// Résumé + liste compacte du contenu d'un dossier.
private struct DirectoryContentsView: View {
    let summary: DirectorySummary
    var selectedID: RemoteItem.ID?
    /// `nil` : la liste occupe toute la hauteur disponible ; sinon elle défile dans cette hauteur.
    var maxListHeight: CGFloat?
    let onSelect: (RemoteItem) -> Void

    private let rowHeight: CGFloat = 22

    var body: some View {
        if summary.isEmpty {
            ContentUnavailableView(
                "Dossier vide",
                systemImage: "folder",
                description: summary.hiddenCount > 0 ? Text(hiddenDescription) : nil
            )
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(summary.countsDescription)
                    Spacer()
                    if summary.fileCount > 0 {
                        Text(Formatting.byteCount(summary.totalFileBytes))
                            .monospacedDigit()
                            .help("Taille des fichiers de ce niveau (sous-dossiers non comptés)")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(summary.entries) { child in
                            EntryRow(item: child, isSelected: child.id == selectedID) { onSelect(child) }
                                .frame(height: rowHeight)
                        }
                        if summary.remainingCount > 0 {
                            footnote("et \(summary.remainingCount) autre(s)…")
                        }
                        if summary.hiddenCount > 0 {
                            footnote(hiddenDescription)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .frame(height: listHeight)
            }
        }
    }

    /// Hauteur de la liste repliée : juste son contenu s'il est court, sinon `maxListHeight` (défilement).
    private var listHeight: CGFloat? {
        guard let maxListHeight else { return nil }
        let footnotes = (summary.remainingCount > 0 ? 1 : 0) + (summary.hiddenCount > 0 ? 1 : 0)
        let content = CGFloat(summary.entries.count) * rowHeight + CGFloat(footnotes) * 20 + 8
        return min(maxListHeight, content)
    }

    private var hiddenDescription: String {
        summary.hiddenCount == 1 ? "1 élément caché" : "\(summary.hiddenCount) éléments cachés"
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.top, 6)
    }
}

private struct EntryRow: View {
    let item: RemoteItem
    var isSelected = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(nsImage: FileIcons.icon(for: item))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? .white : item.isHidden ? .secondary : .primary)
                Spacer(minLength: 8)
                if item.canBeOpenedAsDirectory {
                    // Chevron : un clic sur un dossier y entre.
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(isHovered ? 1 : 0)
                } else {
                    Text(Formatting.size(of: item))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                }
            }
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity)
            .background(background, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(item.canBeOpenedAsDirectory ? "Ouvrir « \(item.name) »" : "Aperçu de « \(item.name) »")
    }

    private var background: Color {
        if isSelected { return .accentColor }
        return isHovered ? Color.primary.opacity(0.06) : .clear
    }
}

/// `QLPreviewView` (QuickLook natif : PDF, audio, vidéo, documents…) dans SwiftUI.
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact) ?? QLPreviewView()
        view.autostarts = true
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? URL) != url {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
