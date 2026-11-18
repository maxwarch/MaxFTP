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

    @Test func mainWindowTabBarButtonsAreClickable() async throws {
        let server = InMemoryFileSystem(files: ["/home/test/index.html": "<html>"])
        let factory = InMemoryFileSystemFactory(fileSystem: server)
        let deps = AppDependencies(
            bookmarkRepository: InMemoryBookmarkRepository(),
            pathBookmarkRepository: InMemoryPathBookmarkRepository(),
            secretStore: InMemorySecretStore(),
            fileSystemFactory: factory
        )
        let app = AppEnvironment(dependencies: deps)
        let rootView = MainWindowView(app: app)
        let hosting = NSHostingView(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "test")
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(50))
            hosting.layoutSubtreeIfNeeded()
        }

        func findButtons(_ v: NSView) -> [(NSButton, NSRect)] {
            var result: [(NSButton, NSRect)] = []
            if let btn = v as? NSButton {
                let frame = btn.convert(btn.bounds, to: nil) // coordonnées fenêtre
                result.append((btn, frame))
            }
            for sub in v.subviews { result += findButtons(sub) }
            return result
        }

        let buttons = findButtons(hosting)
        // Dans le tree : le bouton `+` est à x=729, y ≈ 520..550 (coordonnées AppKit bas->haut).
        // Trouvons tous les boutons situés dans la colonne détail (x >= 220) et dans la bande haute (top 100pt de la fenêtre).
        let topBarButtons = buttons.filter { _, frame in
            frame.minX >= 220 && frame.maxY >= 500
        }
        #expect(topBarButtons.count == 2, "Expected 2 buttons in tab bar initially (tab + plus), got \(topBarButtons.map(\.1))")
        for (btn, frameInWindow) in topBarButtons {
            let centerInWindow = NSPoint(x: frameInWindow.midX, y: frameInWindow.midY)
            let hit = window.contentView?.superview?.hitTest(centerInWindow)
            let ok = hit === btn || hit?.isDescendant(of: btn) == true
            #expect(ok, "Bouton bloqué à \(frameInWindow) : hitTest = \(String(describing: hit))")
        }

        // Cliquer le bouton `+` (le plus à droite dans la barre d'onglets) et vérifier le basculement/fermeture.
        if let (plus, _) = topBarButtons.max(by: { $0.1.minX < $1.1.minX }) {
            plus.performClick(nil)
            for _ in 0..<6 {
                try await Task.sleep(for: .milliseconds(50))
                hosting.layoutSubtreeIfNeeded()
            }
        }
        let afterPlus = findButtons(hosting).filter { _, frame in
            frame.minX >= 220 && frame.maxY >= 500
        }.sorted { $0.1.minX < $1.1.minX }
        #expect(afterPlus.count == 5, "Expected 5 buttons (2 tabs, 2 close, 1 plus), got \(afterPlus.map(\.1))")
        for (btn, frameInWindow) in afterPlus {
            let centerInWindow = NSPoint(x: frameInWindow.midX, y: frameInWindow.midY)
            let hit = window.contentView?.superview?.hitTest(centerInWindow)
            let ok = hit === btn || hit?.isDescendant(of: btn) == true
            #expect(ok, "Bouton après + bloqué à \(frameInWindow) : hitTest = \(String(describing: hit))")
        }

        // Bascule entre onglets (tab1 est à l'index 0, tab2 à l'index 2) puis ferme le 2e onglet (index 3).
        if afterPlus.count == 5 {
            // 2e onglet est actif après `+`, cliquer sur le 1er onglet (index 0) doit basculer.
            let initialCloseButton = afterPlus[3].0
            afterPlus[0].0.performClick(nil)
            for _ in 0..<4 {
                try await Task.sleep(for: .milliseconds(30))
                hosting.layoutSubtreeIfNeeded()
            }
            // Fermer le 2e onglet via son bouton × (index 3).
            initialCloseButton.performClick(nil)
            for _ in 0..<6 {
                try await Task.sleep(for: .milliseconds(50))
                hosting.layoutSubtreeIfNeeded()
            }
            let afterClose = findButtons(hosting).filter { _, frame in
                frame.minX >= 220 && frame.maxY >= 500
            }
            #expect(afterClose.count == 2)
        }
    }
}
