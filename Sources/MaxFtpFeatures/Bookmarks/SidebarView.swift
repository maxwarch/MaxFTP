import MaxFtpCore
import SwiftUI

/// Colonne de gauche : serveurs favoris, chacun dépliable sur ses signets.
/// Double-clic sur un favori = connexion ; simple clic sur un signet = s'y rendre
/// (en se connectant au serveur si besoin).
struct SidebarView: View {
    let bookmarks: BookmarksModel
    let browser: BrowserModel
    let signets: PathBookmarksModel
    let onConnect: (ServerBookmark) -> Void

    /// Id d'un favori ou d'un signet (tous deux des UUID).
    @State private var selection: UUID?
    @State private var expanded: Set<ServerBookmark.ID> = []
    @State private var editorDraft: BookmarkDraft?
    @State private var isNamingSession = false

    /// Session en cours sans favori correspondant (connexion rapide).
    private var unsavedSession: ConnectionConfiguration? {
        guard let serverKey = browser.serverKey, bookmarks.bookmark(forServerKey: serverKey) == nil else { return nil }
        return browser.configuration
    }

    var body: some View {
        List(selection: $selection) {
            // Session sans favori (connexion rapide) : ses signets restent accessibles.
            if let serverKey = browser.serverKey, unsavedSession != nil {
                Section("Signets de la session") {
                    signetRows(serverKey: serverKey)
                    if signets.bookmarks(for: serverKey).isEmpty {
                        Text("Cliquez sur ☆ pour garder un dossier ou un fichier sous la main.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Favoris") {
                if let session = unsavedSession {
                    UnsavedSessionRow(configuration: session) { isNamingSession = true }
                }
                // Pas de `DisclosureGroup` : sa ligne d'en-tête ne participe pas à la sélection
                // de la `List`, ce qui casse le double-clic (connexion) sur le favori.
                ForEach(bookmarks.bookmarks) { bookmark in
                    let hasSignets = !signets.bookmarks(for: bookmark.serverKey).isEmpty
                    BookmarkRow(
                        bookmark: bookmark,
                        status: status(of: bookmark),
                        isExpanded: hasSignets ? expansion(of: bookmark) : nil
                    )
                    .tag(bookmark.id)
                    if hasSignets && expanded.contains(bookmark.id) {
                        signetRows(serverKey: bookmark.serverKey)
                            .padding(.leading, 18)
                    }
                }
                .onMove { bookmarks.move(fromOffsets: $0, toOffset: $1) }
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let (signet, serverKey) = signet(ids.first) {
                Button("Ouvrir") { open(signet, serverKey: serverKey) }
                Divider()
                Button("Retirer des signets", role: .destructive) { signets.remove(signet, on: serverKey) }
            } else if let bookmark = bookmark(ids.first) {
                if browser.isSession(on: bookmark.serverKey) {
                    Button("Aller au dossier de départ") { onConnect(bookmark) }
                    Button("Se déconnecter") { Task { await browser.disconnect() } }
                } else {
                    Button("Se connecter") { onConnect(bookmark) }
                }
                Divider()
                Button("Modifier…") { edit(bookmark) }
                Button("Dupliquer") { bookmarks.duplicate(bookmark) }
                Divider()
                Button("Supprimer", role: .destructive) { bookmarks.delete(bookmark) }
            } else {
                Button("Nouveau favori…") { editorDraft = BookmarkDraft(bookmark: ServerBookmark(), secret: "") }
            }
        } primaryAction: { ids in
            if let bookmark = bookmark(ids.first) { onConnect(bookmark) }
        }
        .onChange(of: selection) {
            // Un signet s'ouvre au simple clic, comme dans un navigateur, puis se désélectionne.
            guard let (signet, serverKey) = signet(selection) else { return }
            selection = nil
            open(signet, serverKey: serverKey)
        }
        .onChange(of: browser.serverKey, initial: true) {
            // Le favori connecté se déplie pour montrer ses signets.
            if let connected = bookmarks.bookmarks.first(where: { $0.serverKey == browser.serverKey }) {
                expanded.insert(connected.id)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 4) {
                Button {
                    editorDraft = BookmarkDraft(bookmark: ServerBookmark(), secret: "")
                } label: {
                    Image(systemName: "plus")
                }
                .help("Nouveau favori")
                Button {
                    if let bookmark = bookmark(selection) { edit(bookmark) }
                } label: {
                    Image(systemName: "pencil")
                }
                .disabled(bookmark(selection) == nil)
                .help("Modifier le favori")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .sheet(isPresented: $isNamingSession) {
            if let session = unsavedSession {
                NameInputSheet(title: "Ajouter \(session.displayName) aux favoris", initialName: session.host, actionTitle: "Enregistrer") { name in
                    let bookmark = bookmarks.addFavorite(from: session, name: name)
                    expanded.insert(bookmark.id)
                }
            }
        }
        .sheet(item: $editorDraft) { draft in
            BookmarkEditorView(draft: draft) { bookmark, secret in
                bookmarks.save(bookmark, secret: secret)
            }
        }
        .overlay {
            if bookmarks.bookmarks.isEmpty && browser.serverKey == nil {
                ContentUnavailableView {
                    Label("Aucun favori", systemImage: "star")
                } description: {
                    Text("Ajoutez un serveur avec le bouton +.")
                }
            }
        }
    }

    private func signetRows(serverKey: String) -> some View {
        ForEach(signets.bookmarks(for: serverKey)) { signet in
            SignetRow(signet: signet).tag(signet.id)
        }
        .onMove { signets.move(fromOffsets: $0, toOffset: $1, on: serverKey) }
    }

    private func status(of bookmark: ServerBookmark) -> BookmarkRow.Status? {
        guard browser.isSession(on: bookmark.serverKey) else { return nil }
        return browser.isConnected ? .connected : .connecting
    }

    private func expansion(of bookmark: ServerBookmark) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(bookmark.id) },
            set: { isExpanded in
                if isExpanded { expanded.insert(bookmark.id) } else { expanded.remove(bookmark.id) }
            }
        )
    }

    private func bookmark(_ id: UUID?) -> ServerBookmark? {
        bookmarks.bookmarks.first { $0.id == id }
    }

    /// Signet portant cet id, avec la clé du serveur auquel il appartient.
    private func signet(_ id: UUID?) -> (PathBookmark, String)? {
        guard let id else { return nil }
        for (serverKey, list) in signets.bookmarksByServer {
            if let signet = list.first(where: { $0.id == id }) { return (signet, serverKey) }
        }
        return nil
    }

    /// Même serveur : on s'y rend. Sinon on se connecte via le favori correspondant.
    private func open(_ signet: PathBookmark, serverKey: String) {
        if browser.serverKey == serverKey {
            Task { await browser.reveal(signet) }
        } else if let bookmark = bookmarks.bookmarks.first(where: { $0.serverKey == serverKey }) {
            let configuration = bookmarks.configuration(for: bookmark)
            Task { await browser.open(signet, on: configuration) }
        }
    }

    private func edit(_ bookmark: ServerBookmark) {
        editorDraft = BookmarkDraft(bookmark: bookmark, secret: bookmarks.secret(for: bookmark) ?? "")
    }
}

/// Connexion rapide en cours, pas encore enregistrée : ligne provisoire en tête des favoris.
private struct UnsavedSessionRow: View {
    let configuration: ConnectionConfiguration
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 14, height: 1)  // aligné sur les favoris (place de la flèche)
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(configuration.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Connexion rapide · non enregistrée")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "bolt.horizontal")
            }
            Spacer(minLength: 0)
            Circle()
                .fill(.green)
                .frame(width: 7, height: 7)
                .help("Connecté")
            Button("Enregistrer…", action: onSave)
                .controlSize(.small)
                .help("Ajouter cette connexion aux favoris")
        }
        .contextMenu {
            Button("Ajouter aux favoris…", action: onSave)
        }
    }
}

private struct BookmarkRow: View {
    enum Status { case connecting, connected }

    let bookmark: ServerBookmark
    let status: Status?
    /// `nil` : pas de signets, donc pas de flèche.
    let isExpanded: Binding<Bool>?

    var body: some View {
        HStack(spacing: 2) {
            if let isExpanded {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.wrappedValue.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                        .frame(width: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded.wrappedValue ? "Masquer les signets" : "Afficher les signets")
                .accessibilityLabel(isExpanded.wrappedValue ? "Masquer les signets" : "Afficher les signets")
            } else {
                Color.clear.frame(width: 14, height: 1)
            }
            label
        }
    }

    private var label: some View {
        Label {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(bookmark.displayName)
                    Text("\(bookmark.connectionProtocol.displayName) · \(bookmark.host)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                switch status {
                case .connected:
                    Circle()
                        .fill(.green)
                        .frame(width: 7, height: 7)
                        .help("Connecté")
                case .connecting:
                    ProgressView().controlSize(.mini)
                case nil:
                    EmptyView()
                }
            }
        } icon: {
            Image(systemName: bookmark.connectionProtocol == .sftp ? "lock.shield" : "server.rack")
        }
    }
}

private struct SignetRow: View {
    let signet: PathBookmark

    var body: some View {
        Label(signet.name, systemImage: signet.isDirectory ? "folder" : "doc")
            .help(signet.path.string)
    }
}

/// Copie de travail éditée dans la feuille ; n'est enregistrée qu'à la validation.
struct BookmarkDraft: Identifiable {
    var bookmark: ServerBookmark
    var secret: String
    var id: UUID { bookmark.id }
}
