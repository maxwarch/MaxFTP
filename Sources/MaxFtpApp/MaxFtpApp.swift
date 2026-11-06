import AppKit
import MaxFtpFeatures
import SwiftUI

@main
struct MaxFtpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppComposition.makeEnvironment()

    var body: some Scene {
        WindowGroup("MaxFtp", id: "browser") {
            MainWindowView(app: environment)
        }
        .commands {
            SidebarCommands()
            InspectorCommands()
            BrowserCommands()
        }

        // SwiftUI l'ajoute seul au menu Fenêtre ; le raccourci se déclare sur la scène.
        Window("Transferts", id: TransfersWindow.id) {
            TransfersWindow(queue: environment.transfers)
        }
        .defaultSize(width: 440, height: 360)
        .keyboardShortcut("t", modifiers: [.command, .option])

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Nécessaire quand l'exécutable est lancé hors bundle `.app` (`swift run`).
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
