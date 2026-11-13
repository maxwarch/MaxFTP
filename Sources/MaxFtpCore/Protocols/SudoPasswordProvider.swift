import Foundation

/// Fournit et mémorise en mémoire le mot de passe `sudo` pour la durée d'une session.
///
/// Utilisé par ``SFTPFileSystem`` lorsqu'une écriture échoue pour permission refusée
/// et qu'une élévation via `sudo` sur SSH est possible.
public protocol SudoPasswordProvider: Sendable {
    /// Retourne le mot de passe `sudo` mémorisé pour `serverKey`, ou le demande à l'utilisateur.
    /// Retourne `nil` si l'utilisateur annule.
    func password(for serverKey: String, path: RemotePath, previousAttemptFailed: Bool) async -> String?

    /// Efface le mot de passe mémorisé pour `serverKey` (ex. à la déconnexion ou si rejeté).
    func clear(for serverKey: String) async
}
