import AppKit
import Foundation
import MaxFtpCore

/// Demande le mot de passe `sudo` à l'utilisateur puis le conserve en mémoire pour la session.
///
/// En tant qu'`actor`, sérialise les demandes concurrentes (ex. plusieurs sauvegardes
/// simultanées) pour n'ouvrir qu'une seule fenêtre de saisie.
public actor InteractiveSudoPasswordProvider: SudoPasswordProvider {
    private var cached: [String: String] = [:]
    private let prompt: @Sendable (String, RemotePath, Bool) async -> String?

    public init(
        prompt: @escaping @Sendable (String, RemotePath, Bool) async -> String? = { _, path, failed in
            await MainActor.run { SudoPasswordAlert.present(path: path, previousAttemptFailed: failed) }
        }
    ) {
        self.prompt = prompt
    }

    public func password(for serverKey: String, path: RemotePath, previousAttemptFailed: Bool) async -> String? {
        if previousAttemptFailed {
            cached[serverKey] = nil
        }
        if let existing = cached[serverKey] {
            return existing
        }
        guard let entered = await prompt(serverKey, path, previousAttemptFailed), !entered.isEmpty else {
            return nil
        }
        cached[serverKey] = entered
        return entered
    }

    public func clear(for serverKey: String) async {
        cached[serverKey] = nil
    }
}

/// Alerte AppKit demandant le mot de passe `sudo` pour enregistrer un fichier protégé.
public enum SudoPasswordAlert {
    @MainActor
    public static func present(path: RemotePath, previousAttemptFailed: Bool) -> String? {
        let alert = NSAlert()
        alert.alertStyle = previousAttemptFailed ? .warning : .informational
        alert.messageText = "Authentification sudo requise"
        alert.informativeText = previousAttemptFailed
            ? "Le mot de passe sudo est incorrect. Réessayez pour enregistrer « \(path.name) » :"
            : "L'enregistrement de « \(path.name) » nécessite les droits administrateur. Le mot de passe sera conservé pendant toute la session."

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Mot de passe sudo"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        alert.addButton(withTitle: "Enregistrer")
        alert.addButton(withTitle: "Annuler")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}
