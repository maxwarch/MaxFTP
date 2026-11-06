import Foundation

/// Secret résolu au moment de la connexion. N'est jamais persisté tel quel :
/// les mots de passe vivent dans le Keychain, voir ``SecretStore``.
public enum Credential: Hashable, Sendable {
    case anonymous
    case password(String)
    case privateKey(URL, passphrase: String?)
}

/// Tout ce qu'un adaptateur ``RemoteFileSystem`` doit savoir pour se connecter.
///
/// C'est un value type autonome : la file de transferts s'en sert pour ouvrir
/// ses propres connexions sans dépendre de la fenêtre qui l'a créée.
public struct ConnectionConfiguration: Hashable, Sendable {
    public var connectionProtocol: ConnectionProtocol
    public var host: String
    public var port: Int
    public var username: String
    public var credential: Credential
    public var initialPath: RemotePath?
    public var ftpDataMode: FTPDataConnectionMode
    /// FTPS uniquement : accepte un certificat auto-signé ou expiré.
    public var allowsUntrustedCertificates: Bool

    public init(
        connectionProtocol: ConnectionProtocol,
        host: String,
        port: Int? = nil,
        username: String,
        credential: Credential,
        initialPath: RemotePath? = nil,
        ftpDataMode: FTPDataConnectionMode = .passive,
        allowsUntrustedCertificates: Bool = false
    ) {
        self.connectionProtocol = connectionProtocol
        self.host = host
        self.port = port ?? connectionProtocol.defaultPort
        self.username = username
        self.credential = credential
        self.initialPath = initialPath
        self.ftpDataMode = ftpDataMode
        self.allowsUntrustedCertificates = allowsUntrustedCertificates
    }

    /// `user@host` (ou `host:port` si le port n'est pas celui par défaut).
    public var displayName: String {
        var result = username.isEmpty ? host : "\(username)@\(host)"
        if port != connectionProtocol.defaultPort { result += ":\(port)" }
        return result
    }
}
