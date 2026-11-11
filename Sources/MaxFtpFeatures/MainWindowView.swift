import MaxFtpCore
import AppKit
import SwiftUI

/// Une fenêtre = une session : favoris | explorateur | inspecteur.
public struct MainWindowView: View {
    private let app: AppEnvironment
    @State private var browser: BrowserModel
    @State private var showInspector = true
    @State private var showQuickConnect = false
    @State private var newBookmark: BookmarkDraft?
    @State private var r2Dashboard: R2DashboardModel?
    @AppStorage(AppSettings.autoRefreshSecondsKey) private var autoRefreshSeconds = AppSettings.defaultAutoRefreshSeconds

    public init(app: AppEnvironment) {
        self.app = app
        _browser = State(initialValue: app.makeBrowserModel())
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(bookmarks: app.bookmarks, browser: browser, signets: app.pathBookmarks) { bookmark in
                let configuration = app.bookmarks.configuration(for: bookmark)
                Task { await browser.connectOrReuse(configuration) }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            // Le partage vertical n'existe que terminal ouvert : sans lui, un `VSplitView`
            // à un seul enfant ne donne pas toute la hauteur à l'explorateur.
            if let request = browser.terminal, let builder = app.dependencies.terminalPanel,
               let configuration = browser.configuration {
                VSplitView {
                    browserView
                        .frame(minHeight: 200, maxHeight: .infinity)
                    TerminalContainer(browser: browser, request: request, configuration: configuration, builder: builder)
                        .id(request.id)
                        .frame(minHeight: 120, idealHeight: 260, maxHeight: .infinity)
                }
            } else {
                browserView
            }
        }
        .inspector(isPresented: $showInspector) {
            InspectorView(browser: browser)
                .inspectorColumnWidth(min: 240, ideal: 300, max: 480)
        }
        .navigationTitle(browser.title)
        .navigationSubtitle(browser.isConnected ? browser.currentPath.string : "")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    Task { await browser.goBack() }
                } label: {
                    Label("Précédent", systemImage: "chevron.left")
                }
                .disabled(!browser.canGoBack)
                .help("Précédent (⌘[)")

                Button {
                    Task { await browser.goForward() }
                } label: {
                    Label("Suivant", systemImage: "chevron.right")
                }
                .disabled(!browser.canGoForward)
                .help("Suivant (⌘])")

                // Clic : liste des dossiers englobants, parent en tête (⌘↑ y va directement).
                Menu {
                    ForEach(browser.enclosingFolders, id: \.self) { folder in
                        Button {
                            Task { await browser.navigate(to: folder) }
                        } label: {
                            Label(
                                folder.isRoot ? "/" : folder.name,
                                systemImage: folder.isRoot ? "externaldrive.connected.to.line.below" : "folder"
                            )
                        }
                    }
                } label: {
                    Label("Dossiers parents", systemImage: "chevron.up")
                }
                .menuIndicator(.hidden)
                .disabled(!browser.isConnected || browser.currentPath.isRoot)
                .help("Aller à un dossier parent (⌘↑ : dossier parent direct)")
            }
            // Connecté, la barre se replie en bouton : sans élément `.principal`,
            // le titre (user@hôte et chemin) peut occuper toute la largeur libre.
            if browser.connectionState == .disconnected {
                ToolbarItem(placement: .principal) {
                    QuickConnectBar(resolver: { app.quickConnectResolver }) { configuration in
                        connect(to: configuration)
                    }
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if browser.connectionState != .disconnected {
                    QuickConnectButton(resolver: { app.quickConnectResolver }) { configuration in
                        connect(to: configuration)
                    }
                }

                SignetsToolbarMenu(browser: browser, signets: app.pathBookmarks)

                Button {
                    Task { await browser.refresh() }
                } label: {
                    Label("Actualiser", systemImage: "arrow.clockwise")
                }
                .disabled(!browser.isConnected)
                .help("Actualiser (⌘R)")

                if browser.isConnected, app.makeR2DashboardModel(for: browser.configuration) != nil {
                    Button {
                        r2Dashboard = app.makeR2DashboardModel(for: browser.configuration)
                    } label: {
                        Label("Tableau de bord R2", systemImage: "chart.bar.xaxis")
                    }
                    .help("Stockage, requêtes et budget du compte Cloudflare R2")
                }

                Button {
                    browser.toggleTerminal()
                } label: {
                    Label("Terminal", systemImage: "terminal")
                }
                .disabled(!browser.canOpenTerminal || app.dependencies.terminalPanel == nil)
                .keyboardShortcut("`", modifiers: .control)
                .help(browser.isConnected && !browser.canOpenTerminal
                    ? "Terminal indisponible : seul SFTP (SSH) donne accès à un shell."
                    : "Terminal SSH dans le dossier courant (⌃`)")

                TransfersToolbarButton(queue: app.transfers)

                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspecteur", systemImage: "sidebar.trailing")
                }
                .help("Afficher / masquer l'inspecteur (⌥⌘I)")
            }
        }
        .sheet(isPresented: $showQuickConnect) {
            QuickConnectSheet(resolver: { app.quickConnectResolver }) { configuration in
                showQuickConnect = false
                connect(to: configuration)
            }
        }
        .sheet(item: $r2Dashboard) { model in
            R2DashboardView(model: model)
        }
        .sheet(item: $newBookmark) { draft in
            BookmarkEditorView(draft: draft) { bookmark, secret in
                app.bookmarks.save(bookmark, secret: secret)
            }
        }
        .focusedSceneValue(\.browserModel, browser)
        .focusedSceneValue(\.pathBookmarks, app.pathBookmarks)
        .onMouseNavigation { direction in
            Task {
                switch direction {
                case .back: await browser.goBack()
                case .forward: await browser.goForward()
                }
            }
        }
        .focusedSceneValue(\.inspectorVisibility, $showInspector)
        .alert(
            "Favoris",
            isPresented: Binding(
                get: { app.bookmarks.errorMessage != nil },
                set: { if !$0 { app.bookmarks.errorMessage = nil } }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(app.bookmarks.errorMessage ?? "")
        }
        .alert(
            "Signets",
            isPresented: Binding(
                get: { app.pathBookmarks.errorMessage != nil },
                set: { if !$0 { app.pathBookmarks.errorMessage = nil } }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(app.pathBookmarks.errorMessage ?? "")
        }
        .onDisappear {
            Task { await browser.disconnect() }
        }
        .task(id: autoRefreshKey) { await autoRefresh() }
        .frame(minWidth: 900, minHeight: 500)
    }

    /// Relancée à chaque changement de serveur ou de réglage.
    private var autoRefreshKey: String { "\(browser.serverKey ?? "")|\(autoRefreshSeconds)" }

    /// Relit le dossier courant à intervalle régulier, seulement quand l'app est au premier plan.
    private func autoRefresh() async {
        guard let proto = browser.configuration?.connectionProtocol, browser.isConnected,
              let interval = AppSettings.autoRefreshInterval(for: proto, seconds: autoRefreshSeconds) else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            if NSApplication.shared.isActive { await browser.refreshInBackground() }
        }
    }

    private var browserView: some View {
        BrowserView(
            model: browser,
            signets: app.pathBookmarks,
            transfers: app.transfers,
            onQuickConnect: { showQuickConnect = true },
            onNewBookmark: { newBookmark = BookmarkDraft(bookmark: ServerBookmark(), secret: "") }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connect(to configuration: ConnectionConfiguration) {
        Task { await browser.connect(to: configuration) }
    }
}

/// Bandeau du terminal intégré (titre, Terminal.app, fermeture) + l'émulateur.
private struct TerminalContainer: View {
    let browser: BrowserModel
    let request: TerminalRequest
    let configuration: ConnectionConfiguration
    let builder: TerminalPanelBuilder

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("\(configuration.displayName) : \(request.directory.string)", systemImage: "terminal")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Ouvrir dans Terminal") { LocalWorkspace.openInTerminal(configuration, at: request.directory) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                Button {
                    browser.terminal = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Fermer le terminal")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.bar)
            Divider()
            builder.make(configuration, request.directory) { [browser] in
                Task { await browser.refreshInBackground() }
            }
        }
    }
}
