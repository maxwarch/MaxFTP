import Foundation
import MaxFtpCore
import Observation

/// Un onglet de navigation dans la fenêtre principale, portant sa propre session ``BrowserModel``.
@MainActor
@Observable
public final class BrowserTab: Identifiable {
    public let id: UUID
    public let browser: BrowserModel
    public var bookmarkName: String?
    public var signetID: PathBookmark.ID?
    public var signetName: String?

    public init(
        id: UUID = UUID(),
        browser: BrowserModel,
        bookmarkName: String? = nil,
        signetID: PathBookmark.ID? = nil,
        signetName: String? = nil
    ) {
        self.id = id
        self.browser = browser
        self.bookmarkName = bookmarkName
        self.signetID = signetID
        self.signetName = signetName
    }

    /// Libellé affiché dans la barre d'onglets.
    public var title: String {
        if let signetName, !signetName.isEmpty, browser.serverKey != nil {
            return signetName
        }
        if let bookmarkName, !bookmarkName.isEmpty, browser.serverKey != nil {
            return bookmarkName
        }
        if browser.connectionState == .disconnected && browser.serverKey == nil {
            return "Nouvel onglet"
        }
        return browser.title
    }

    var isUnused: Bool {
        browser.connectionState == .disconnected && browser.serverKey == nil
    }
}

/// Gère les onglets d'une fenêtre : ouverture de favoris/signets en onglets, bascule et fermeture.
@MainActor
@Observable
public final class BrowserTabsModel {
    public private(set) var tabs: [BrowserTab]
    public var selectedTabID: UUID
    private let makeBrowser: () -> BrowserModel

    public init(makeBrowser: @escaping () -> BrowserModel) {
        self.makeBrowser = makeBrowser
        let initial = BrowserTab(browser: makeBrowser())
        self.tabs = [initial]
        self.selectedTabID = initial.id
    }

    public var activeTab: BrowserTab {
        tabs.first(where: { $0.id == selectedTabID }) ?? tabs[0]
    }

    public var activeBrowser: BrowserModel {
        activeTab.browser
    }

    public func tab(forServerKey serverKey: String) -> BrowserTab? {
        tabs.first { $0.browser.isSession(on: serverKey) }
    }

    public func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
    }

    public func selectPreviousTab() {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        let previous = (index - 1 + tabs.count) % tabs.count
        selectedTabID = tabs[previous].id
    }

    public func selectNextTab() {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        let next = (index + 1) % tabs.count
        selectedTabID = tabs[next].id
    }

    @discardableResult
    public func newTab(
        bookmarkName: String? = nil,
        signetID: PathBookmark.ID? = nil,
        signetName: String? = nil
    ) -> BrowserTab {
        let tab = BrowserTab(
            browser: makeBrowser(),
            bookmarkName: bookmarkName,
            signetID: signetID,
            signetName: signetName
        )
        tabs.append(tab)
        selectedTabID = tab.id
        return tab
    }

    /// Ouvre un favori : réutilise son onglet s'il est déjà ouvert, sinon l'onglet vide courant, sinon un nouvel onglet.
    public func openBookmark(_ bookmark: ServerBookmark, configuration: ConnectionConfiguration) async {
        if let existing = tabs.first(where: { $0.browser.isSession(on: configuration.serverKey) && $0.signetID == nil }) {
            existing.bookmarkName = bookmark.name
            selectedTabID = existing.id
            await existing.browser.connectOrReuse(configuration)
            return
        }
        let target: BrowserTab
        if activeTab.isUnused {
            target = activeTab
            target.bookmarkName = bookmark.name
            target.signetID = nil
            target.signetName = nil
        } else {
            target = newTab(bookmarkName: bookmark.name)
        }
        await target.browser.connectOrReuse(configuration)
    }

    /// Ouvre un signet dans un onglet dédié (ou bascule dessus s'il est déjà ouvert).
    public func openSignet(_ signet: PathBookmark, on configuration: ConnectionConfiguration, bookmarkName: String? = nil) async {
        if let existing = tabs.first(where: { $0.signetID == signet.id && $0.browser.isSession(on: configuration.serverKey) }) {
            selectedTabID = existing.id
            return
        }
        let target: BrowserTab
        if activeTab.isUnused {
            target = activeTab
            target.bookmarkName = bookmarkName
            target.signetID = signet.id
            target.signetName = signet.name
        } else {
            target = newTab(bookmarkName: bookmarkName, signetID: signet.id, signetName: signet.name)
        }
        await target.browser.open(signet, on: configuration)
    }

    /// Connexion rapide dans l'onglet actif.
    public func connectActiveTab(to configuration: ConnectionConfiguration) async {
        if activeTab.browser.serverKey != configuration.serverKey {
            activeTab.bookmarkName = nil
            activeTab.signetID = nil
            activeTab.signetName = nil
        }
        await activeTab.browser.connect(to: configuration)
    }

    public func closeTab(_ id: UUID) async {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs.count == 1 {
            tabs[0].bookmarkName = nil
            tabs[0].signetID = nil
            tabs[0].signetName = nil
            await tabs[0].browser.disconnect()
            return
        }
        let removed = tabs.remove(at: index)
        if selectedTabID == id {
            let nextIndex = min(index, tabs.count - 1)
            selectedTabID = tabs[nextIndex].id
        }
        await removed.browser.disconnect()
    }

    public func disconnectAll() async {
        for tab in tabs {
            await tab.browser.disconnect()
        }
    }
}
