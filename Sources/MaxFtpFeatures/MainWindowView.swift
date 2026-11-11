import MaxFtpCore
import SwiftUI

/// Une fenêtre = une session : favoris | explorateur | inspecteur.
public struct MainWindowView: View {
    private let app: AppEnvironment
    @State private var browser: BrowserModel
    @State private var showInspector = true
    @State private var showQuickConnect = false
    @State private var newBookmark: BookmarkDraft?
    @State private var r2Dashboard: R2DashboardModel?

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
            BrowserView(
                model: browser,
                signets: app.pathBookmarks,
                transfers: app.transfers,
                onQuickConnect: { showQuickConnect = true },
                onNewBookmark: { newBookmark = BookmarkDraft(bookmark: ServerBookmark(), secret: "") }
            )
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
        .frame(minWidth: 900, minHeight: 500)
    }

    private func connect(to configuration: ConnectionConfiguration) {
        Task { await browser.connect(to: configuration) }
    }
}
