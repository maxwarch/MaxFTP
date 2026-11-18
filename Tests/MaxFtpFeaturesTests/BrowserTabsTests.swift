import Foundation
import MaxFtpCore
@testable import MaxFtpFeatures
import MaxFtpTestSupport
import Testing

@MainActor
@Suite("Onglets")
struct BrowserTabsTests {
    private func makeTabs() -> BrowserTabsModel {
        let server = InMemoryFileSystem(files: ["/home/test/index.html": "<html>"])
        let factory = InMemoryFileSystemFactory(fileSystem: server)
        let transfers = TransferQueue(factory: factory, maxConcurrent: { 1 })
        return BrowserTabsModel {
            BrowserModel(factory: factory, transfers: transfers)
        }
    }

    private func makeBookmark(name: String, host: String) -> (ServerBookmark, ConnectionConfiguration) {
        let bookmark = ServerBookmark(name: name, connectionProtocol: .sftp, host: host, username: "test")
        let config = ConnectionConfiguration(connectionProtocol: .sftp, host: host, port: 22, username: "test", credential: .password("secret"))
        return (bookmark, config)
    }

    @Test func opensBookmarksInTabsAndReusesExistingSession() async {
        let tabs = makeTabs()
        #expect(tabs.tabs.count == 1)
        #expect(tabs.activeTab.title == "Nouvel onglet")

        let (b1, c1) = makeBookmark(name: "Prod", host: "prod.example.com")
        let (b2, c2) = makeBookmark(name: "Staging", host: "staging.example.com")

        // Premier favori : réutilise l'onglet vide initial.
        await tabs.openBookmark(b1, configuration: c1)
        #expect(tabs.tabs.count == 1)
        #expect(tabs.activeTab.title == "Prod")
        #expect(tabs.activeBrowser.isConnected)
        let prodTabID = tabs.selectedTabID

        // Deuxième favori : ouvre un nouvel onglet et bascule dessus.
        await tabs.openBookmark(b2, configuration: c2)
        #expect(tabs.tabs.count == 2)
        #expect(tabs.activeTab.title == "Staging")
        #expect(tabs.selectedTabID != prodTabID)
        let stagingTabID = tabs.selectedTabID

        // Réouvrir le premier favori : rebascule sur son onglet sans créer de doublon.
        await tabs.openBookmark(b1, configuration: c1)
        #expect(tabs.tabs.count == 2)
        #expect(tabs.selectedTabID == prodTabID)

        // Navigation entre onglets.
        tabs.selectNextTab()
        #expect(tabs.selectedTabID == stagingTabID)
        tabs.selectPreviousTab()
        #expect(tabs.selectedTabID == prodTabID)
    }

    @Test func closesTabsAndResetsLastRemainingTab() async {
        let tabs = makeTabs()
        let (b1, c1) = makeBookmark(name: "Prod", host: "prod.example.com")
        let (b2, c2) = makeBookmark(name: "Staging", host: "staging.example.com")

        await tabs.openBookmark(b1, configuration: c1)
        await tabs.openBookmark(b2, configuration: c2)
        #expect(tabs.tabs.count == 2)

        let secondID = tabs.selectedTabID
        await tabs.closeTab(secondID)
        #expect(tabs.tabs.count == 1)
        #expect(tabs.activeTab.title == "Prod")
        #expect(tabs.activeBrowser.isConnected)

        // Fermer le dernier onglet le déconnecte et le remet à zéro.
        await tabs.closeTab(tabs.selectedTabID)
        #expect(tabs.tabs.count == 1)
        #expect(tabs.activeTab.title == "Nouvel onglet")
        #expect(!tabs.activeBrowser.isConnected)
    }

    @Test func opensDifferentSignetsOnSameServerInSeparateTabs() async {
        let tabs = makeTabs()
        let (b1, c1) = makeBookmark(name: "contabo", host: "13.140.187.147")
        let s1 = PathBookmark(name: "langfuse", path: RemotePath("/home/test"), isDirectory: true)
        let s2 = PathBookmark(name: "www", path: RemotePath("/home/test"), isDirectory: true)

        await tabs.openBookmark(b1, configuration: c1)
        #expect(tabs.tabs.count == 1)
        let serverTabID = tabs.selectedTabID

        await tabs.openSignet(s1, on: c1, bookmarkName: b1.name)
        #expect(tabs.tabs.count == 2)
        #expect(tabs.activeTab.title == "langfuse")
        let s1TabID = tabs.selectedTabID

        await tabs.openSignet(s2, on: c1, bookmarkName: b1.name)
        #expect(tabs.tabs.count == 3)
        #expect(tabs.activeTab.title == "www")
        #expect(tabs.selectedTabID != s1TabID)
        #expect(tabs.selectedTabID != serverTabID)

        // Re-cliquer sur le même signet rebascule sur son onglet.
        await tabs.openSignet(s1, on: c1, bookmarkName: b1.name)
        #expect(tabs.tabs.count == 3)
        #expect(tabs.selectedTabID == s1TabID)
    }
}
