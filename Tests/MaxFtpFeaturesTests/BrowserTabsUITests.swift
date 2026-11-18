import AppKit
import MaxFtpCore
@testable import MaxFtpFeatures
import MaxFtpTestSupport
import SwiftUI
import Testing

@MainActor
@Suite("Tests UI Onglets")
struct BrowserTabsUITests {
    @Test func tabBarButtonsAreNotBlockedByOverlay() async throws {
        let server = InMemoryFileSystem(files: ["/home/test/index.html": "<html>"])
        let factory = InMemoryFileSystemFactory(fileSystem: server)
        let transfers = TransferQueue(factory: factory, maxConcurrent: { 1 })
        let tabs = BrowserTabsModel {
            BrowserModel(factory: factory, transfers: transfers)
        }
        let b1 = ServerBookmark(name: "Prod", connectionProtocol: .sftp, host: "prod.example.com", username: "test")
        let c1 = ConnectionConfiguration(connectionProtocol: .sftp, host: "prod.example.com", port: 22, username: "test", credential: .password("s"))
        let b2 = ServerBookmark(name: "Staging", connectionProtocol: .sftp, host: "staging.example.com", username: "test")
        let c2 = ConnectionConfiguration(connectionProtocol: .sftp, host: "staging.example.com", port: 22, username: "test", credential: .password("s"))

        await tabs.openBookmark(b1, configuration: c1)
        await tabs.openBookmark(b2, configuration: c2)
        #expect(tabs.tabs.count == 2)

        let view = BrowserTabBar(tabs: tabs)
            .frame(width: 700, height: 32)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 32),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        // Récupère tous les NSButton natifs rendus dans la barre d'onglets (2 onglets + 2 boutons × + 1 bouton + = 5).
        func collectButtons(_ v: NSView) -> [NSButton] {
            var result: [NSButton] = []
            if let btn = v as? NSButton { result.append(btn) }
            for sub in v.subviews { result += collectButtons(sub) }
            return result
        }
        let buttons = collectButtons(hosting)
        #expect(buttons.count == 5)

        // Vérifie que hitTest au centre de chaque bouton atteint bien le bouton lui-même (ou sa sous-vue).
        for button in buttons {
            let centerInHosting = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: hosting)
            let hit = hosting.hitTest(centerInHosting)
            #expect(hit != nil)
            #expect(hit === button || hit?.isDescendant(of: button) == true)
        }
    }
}
