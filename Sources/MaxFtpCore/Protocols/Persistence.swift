import Foundation

/// Stockage sécurisé des secrets (mots de passe, passphrases).
/// Implémentation de production : Keychain macOS (`MaxFtpStorage.KeychainSecretStore`).
public protocol SecretStore: Sendable {
    func secret(for account: String) throws -> String?
    func setSecret(_ secret: String, for account: String) throws
    func removeSecret(for account: String) throws
}

/// Persistance des favoris (Repository pattern).
/// Implémentation de production : fichier JSON dans Application Support.
public protocol BookmarkRepository: Sendable {
    func loadBookmarks() throws -> [ServerBookmark]
    func saveBookmarks(_ bookmarks: [ServerBookmark]) throws
}

/// Clés d'hôte SSH approuvées par l'utilisateur dans l'application.
public protocol HostKeyStore: Sendable {
    /// Clés OpenSSH (`ssh-ed25519 AAAA…`) déjà approuvées pour cet hôte.
    func trustedKeys(for host: KnownHostIdentifier) throws -> [String]
    func trust(_ openSSHKey: String, for host: KnownHostIdentifier) throws
}

/// Persistance des signets, indexés par ``ConnectionConfiguration/serverKey``.
/// Implémentation de production : fichier JSON dans Application Support.
public protocol PathBookmarkRepository: Sendable {
    func loadPathBookmarks() throws -> [String: [PathBookmark]]
    func savePathBookmarks(_ bookmarks: [String: [PathBookmark]]) throws
}
