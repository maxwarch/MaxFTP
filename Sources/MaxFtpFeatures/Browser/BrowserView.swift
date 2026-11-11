import MaxFtpCore
import QuickLook
import SwiftUI

/// Zone centrale : liste des fichiers distants + fil d'Ariane.
struct BrowserView: View {
    @Bindable var model: BrowserModel
    let signets: PathBookmarksModel
    let transfers: TransferQueue
    var onQuickConnect: () -> Void = {}
    var onNewBookmark: () -> Void = {}
    @AppStorage(AppSettings.showHiddenFilesKey) private var showHiddenFiles = false

    var body: some View {
        Group {
            switch model.connectionState {
            case .disconnected:
                ContentUnavailableView {
                    Label("Non connecté", systemImage: "network.slash")
                } description: {
                    Text("Double-cliquez sur un favori dans la barre latérale, ou :")
                } actions: {
                    Button(action: onQuickConnect) {
                        Label("Connexion rapide…", systemImage: "bolt.horizontal")
                    }
                    .buttonStyle(.borderedProminent)
                    Button(action: onNewBookmark) {
                        Label("Nouveau favori…", systemImage: "star")
                    }
                }
                .controlSize(.large)
            case .connecting:
                VStack(spacing: 16) {
                    ProgressView("Connexion à \(model.configuration?.host ?? "")…")
                    Button("Annuler") { Task { await model.cancelConnection() } }
                        .keyboardShortcut(.cancelAction)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .connected:
                VStack(spacing: 0) {
                    FileTableView(model: model, signets: signets)
                    Divider()
                    PathBar(model: model, transfers: transfers)
                }
            }
        }
        .onChange(of: showHiddenFiles, initial: true) { model.showHiddenFiles = showHiddenFiles }
        .browserPrompts(model: model)
    }
}

/// `Table` native : tri par colonne, sélection multiple, menu contextuel, drop Finder.
struct FileTableView: View {
    @Bindable var model: BrowserModel
    let signets: PathBookmarksModel
    @State private var isDropTargeted = false

    var body: some View {
        Table(model.visibleItems, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Nom", value: \.name, comparator: .localizedStandard) { item in
                Label {
                    Text(item.name)
                        .foregroundStyle(item.isHidden ? .secondary : .primary)
                } icon: {
                    Image(nsImage: FileIcons.icon(for: item))
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                .help(item.symbolicLinkTarget.map { "→ \($0)" } ?? item.name)
            }
            .width(min: 180, ideal: 320)

            TableColumn("Taille", value: \.sortableSize) { item in
                Text(Formatting.size(of: item))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)

            TableColumn("Modifié le", value: \.sortableDate) { item in
                Text(Formatting.date(item.modificationDate))
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 160)

            TableColumn("Permissions", value: \.sortablePermissions) { item in
                Text(Formatting.permissions(item.permissions))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150)
        }
        .contextMenu(forSelectionType: RemoteItem.ID.self) { ids in
            BrowserContextMenu(model: model, signets: signets, ids: ids)
        } primaryAction: { ids in
            Task { await model.open(ids) }
        }
        .onKeyPress(.space) {
            Task { await model.toggleQuickLook() }
            return .handled
        }
        .onDeleteCommand { model.requestDeletion() }
        .quickLookPreview($model.quickLookURL)
        .dropDestination(for: URL.self) { urls, _ in
            model.upload(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if model.isLoading && model.items.isEmpty {
                ProgressView()
            } else if !model.isLoading && model.visibleItems.isEmpty {
                ContentUnavailableView("Dossier vide", systemImage: "folder", description: Text("Glissez des fichiers ici pour les envoyer."))
            }
        }
    }
}

/// Menu contextuel : actions sur la sélection, ou sur le dossier courant si rien n'est sélectionné.
struct BrowserContextMenu: View {
    let model: BrowserModel
    let signets: PathBookmarksModel
    let ids: Set<RemoteItem.ID>

    private var targets: [RemoteItem] { model.items.filter { ids.contains($0.id) } }

    var body: some View {
        if targets.isEmpty {
            Button("Nouveau dossier…") { model.prompt = .newFolder }
            Button("Envoyer des fichiers…") { model.upload(LocalWorkspace.chooseFilesToUpload()) }
            Divider()
            signetToggle(model.currentPath, isDirectory: true)
            terminalItems(model.currentPath)
            Button("Actualiser") { Task { await model.refresh() } }
        } else {
            let single = targets.count == 1 ? targets.first : nil

            if let single, single.canBeOpenedAsDirectory {
                Button("Ouvrir") { Task { await model.navigate(to: single.path) } }
                terminalItems(single.path)
            }
            Button("Télécharger…") {
                if let directory = LocalWorkspace.chooseDownloadDirectory() {
                    model.download(targets, to: directory)
                }
            }
            if let single, !single.isDirectory {
                Button(editTitle(for: single)) { Task { await model.edit(single, with: nil) } }
                Button("Éditer avec…") {
                    if let choice = LocalWorkspace.chooseApplication(alwaysFileName: single.name) {
                        if choice.always {
                            AppSettings.editorChoices.alwaysOpen(filesNamedLike: single.name, with: choice.application)
                        }
                        Task { await model.edit(single, with: choice.application) }
                    }
                }
            }
            Divider()
            if let single {
                Button("Renommer…") { model.prompt = .rename(single) }
                if model.configuration?.connectionProtocol.supportsPermissions ?? true {
                    Button("Permissions (CHMOD)…") { model.prompt = .permissions(single) }
                }
                Button("Copier le chemin") { model.copyPathToPasteboard(single) }
                signetToggle(single.path, isDirectory: single.canBeOpenedAsDirectory)
                Divider()
            }
            Button("Supprimer…", role: .destructive) { model.requestDeletion(of: ids) }
        }
    }

    /// Terminal intégré ou Terminal.app, ouvert dans `directory` (SSH uniquement).
    @ViewBuilder
    private func terminalItems(_ directory: RemotePath) -> some View {
        if model.canOpenTerminal, let configuration = model.configuration {
            Button("Ouvrir un terminal ici") { model.openTerminal(at: directory) }
            Button("Ouvrir dans Terminal") { LocalWorkspace.openInTerminal(configuration, at: directory) }
        }
    }

    /// « Éditer dans Visual Studio Code » quand un éditeur est choisi dans les Réglages.
    private func editTitle(for item: RemoteItem) -> String {
        guard let app = model.preferredEditor(for: item) else { return "Éditer" }
        let name = (FileManager.default.displayName(atPath: app.path) as NSString).deletingPathExtension
        return "Éditer dans \(name)"
    }

    @ViewBuilder
    private func signetToggle(_ path: RemotePath, isDirectory: Bool) -> some View {
        if let serverKey = model.serverKey {
            if signets.bookmark(for: path, on: serverKey) != nil {
                Button("Retirer des signets") { signets.toggle(path, isDirectory: isDirectory, on: serverKey) }
            } else {
                Button("Ajouter aux signets") { signets.toggle(path, isDirectory: isDirectory, on: serverKey) }
            }
        }
    }
}

/// Fil d'Ariane cliquable + état de la sélection.
struct PathBar: View {
    let model: BrowserModel
    let transfers: TransferQueue
    @AppStorage(AppSettings.showHiddenFilesKey) private var showHiddenFiles = false

    var body: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(model.currentPath.ancestors, id: \.self) { path in
                        if !path.isRoot {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            Task { await model.navigate(to: path) }
                        } label: {
                            Label(path.isRoot ? "/" : path.name, systemImage: path.isRoot ? "externaldrive.connected.to.line.below" : "folder")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.borderless)
                        .dropDestination(for: URL.self) { urls, _ in
                            model.upload(urls, into: path)
                            return true
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            Spacer()
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
            TransferStatusView(queue: transfers)
            // Même préférence que ⇧⌘. et les Réglages.
            Toggle("Fichiers cachés", isOn: $showHiddenFiles)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .foregroundStyle(.secondary)
                .help("Afficher ou masquer les fichiers cachés (⇧⌘.)")
            Text(summary)
                .foregroundStyle(.secondary)
                .padding(.trailing, 8)
        }
        .font(.callout)
        .frame(height: 26)
    }

    private var summary: String {
        let count = model.visibleItems.count
        let selected = model.selection.count
        return selected > 0 ? "\(selected) sur \(count) sélectionné(s)" : "\(count) élément(s)"
    }
}
