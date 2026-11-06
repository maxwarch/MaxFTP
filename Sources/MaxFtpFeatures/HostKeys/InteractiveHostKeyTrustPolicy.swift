import AppKit
import Foundation
import MaxFtpCore

/// Politique de confiance des clés d'hôte SSH, façon OpenSSH :
/// 1. clé déjà approuvée dans l'app ou présente dans `~/.ssh/known_hosts` → acceptée ;
/// 2. sinon, l'utilisateur est consulté (avertissement renforcé si la clé a CHANGÉ) ;
/// 3. une clé acceptée est mémorisée dans le ``HostKeyStore`` de l'app.
public struct InteractiveHostKeyTrustPolicy: HostKeyTrustPolicy {
    private let store: any HostKeyStore
    private let knownHostsURL: URL
    private let prompt: @Sendable (HostKeyChallenge) async -> Bool

    public init(
        store: any HostKeyStore,
        knownHostsURL: URL,
        prompt: @escaping @Sendable (HostKeyChallenge) async -> Bool = { challenge in
            await MainActor.run { HostKeyAlert.present(challenge) }
        }
    ) {
        self.store = store
        self.knownHostsURL = knownHostsURL
        self.prompt = prompt
    }

    public func untrustedStatus(of challenge: HostKeyChallenge) -> HostKeyChallenge.Status? {
        let presented = Self.normalized(challenge.openSSHKey)
        let known = ((try? store.trustedKeys(for: challenge.host)) ?? [])
            + KnownHostsFile.load(from: knownHostsURL).keys(for: challenge.host)
        let knownKeys = known.map(Self.normalized)

        if knownKeys.contains(presented) { return nil }
        let sameTypeKnown = knownKeys.contains { $0.split(separator: " ").first == presented.split(separator: " ").first }
        return sameTypeKnown ? .changed : .unknown
    }

    public func confirm(_ challenge: HostKeyChallenge) async -> Bool {
        guard await prompt(challenge) else { return false }
        try? store.trust(Self.normalized(challenge.openSSHKey), for: challenge.host)
        return true
    }

    /// `type base64` sans commentaire final.
    static func normalized(_ key: String) -> String {
        key.split(separator: " ").prefix(2).joined(separator: " ")
    }
}

/// Alerte AppKit demandant à l'utilisateur de valider une clé d'hôte.
public enum HostKeyAlert {
    @MainActor
    public static func present(_ challenge: HostKeyChallenge) -> Bool {
        let alert = NSAlert()
        switch challenge.status {
        case .unknown:
            alert.alertStyle = .informational
            alert.messageText = "Première connexion à \(challenge.host)"
            alert.informativeText = """
            L'authenticité de cet hôte ne peut pas être vérifiée.
            Empreinte de la clé \(challenge.keyType) :
            \(challenge.fingerprint)

            Faire confiance à cet hôte et poursuivre ?
            """
            alert.addButton(withTitle: "Faire confiance")
            alert.addButton(withTitle: "Annuler")
        case .changed:
            alert.alertStyle = .critical
            alert.messageText = "La clé de \(challenge.host) a changé !"
            alert.informativeText = """
            Quelqu'un intercepte peut-être la connexion (attaque de l'homme du milieu), ou l'administrateur a remplacé la clé du serveur.
            Nouvelle empreinte \(challenge.keyType) :
            \(challenge.fingerprint)

            Ne continuez que si vous êtes certain de ce changement.
            """
            alert.addButton(withTitle: "Annuler")
            alert.addButton(withTitle: "Remplacer la clé et continuer")
        }
        // Sans application au premier plan, macOS diffère l'affichage de l'alerte :
        // la connexion attendrait une réponse à une question invisible.
        NSApplication.shared.activate()
        let response = alert.runModal()
        return challenge.status == .unknown
            ? response == .alertFirstButtonReturn
            : response == .alertSecondButtonReturn
    }
}
