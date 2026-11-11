import Foundation

/// Serveur favori, tel qu'il est persisté (sans aucun secret).
public struct ServerBookmark: Identifiable, Hashable, Sendable {
    public enum AuthenticationKind: String, Codable, CaseIterable, Identifiable, Sendable {
        case password
        case privateKey

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .password: "Mot de passe"
            case .privateKey: "Clé privée SSH"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var connectionProtocol: ConnectionProtocol
    public var host: String
    public var port: Int
    public var username: String
    public var authenticationKind: AuthenticationKind
    public var privateKeyPath: String?
    public var initialPath: String?
    public var ftpDataMode: FTPDataConnectionMode
    public var allowsUntrustedCertificates: Bool
    /// S3 uniquement : région de signature (`auto` pour Cloudflare R2).
    public var s3Region: String

    public init(
        id: UUID = UUID(),
        name: String = "",
        connectionProtocol: ConnectionProtocol = .sftp,
        host: String = "",
        port: Int? = nil,
        username: String = "",
        authenticationKind: AuthenticationKind = .password,
        privateKeyPath: String? = nil,
        initialPath: String? = nil,
        ftpDataMode: FTPDataConnectionMode = .passive,
        allowsUntrustedCertificates: Bool = false,
        s3Region: String = ConnectionConfiguration.defaultS3Region
    ) {
        self.id = id
        self.name = name
        self.connectionProtocol = connectionProtocol
        self.host = host
        self.port = port ?? connectionProtocol.defaultPort
        self.username = username
        self.authenticationKind = authenticationKind
        self.privateKeyPath = privateKeyPath
        self.initialPath = initialPath
        self.ftpDataMode = ftpDataMode
        self.allowsUntrustedCertificates = allowsUntrustedCertificates
        self.s3Region = s3Region
    }

    /// Nom affiché dans la barre latérale.
    public var displayName: String { name.isEmpty ? host : name }

    /// Clé du mot de passe (ou de la passphrase) dans le Keychain.
    public var secretAccount: String { id.uuidString }

    /// Construit la configuration de connexion à partir du secret récupéré dans le Keychain.
    public func configuration(secret: String?) -> ConnectionConfiguration {
        let credential: Credential
        switch authenticationKind {
        case .privateKey where connectionProtocol.supportsKeyAuthentication:
            let path = (privateKeyPath ?? "~/.ssh/id_ed25519") as NSString
            credential = .privateKey(URL(fileURLWithPath: path.expandingTildeInPath), passphrase: secret)
        case .password, .privateKey:
            credential = username.isEmpty && (secret ?? "").isEmpty ? .anonymous : .password(secret ?? "")
        }
        return ConnectionConfiguration(
            connectionProtocol: connectionProtocol,
            host: host,
            port: port,
            username: username,
            credential: credential,
            initialPath: initialPath.flatMap { $0.isEmpty ? nil : RemotePath($0) },
            ftpDataMode: ftpDataMode,
            allowsUntrustedCertificates: allowsUntrustedCertificates,
            s3Region: s3Region
        )
    }
}

// MARK: - Codable tolérant aux évolutions de schéma
//
// Chaque champ ajouté après la v1 DOIT être décodé avec `decodeIfPresent` et une
// valeur par défaut, sinon les favoris existants des utilisateurs deviennent illisibles.

extension ServerBookmark: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, connectionProtocol, host, port, username, authenticationKind
        case privateKeyPath, initialPath, ftpDataMode, allowsUntrustedCertificates, s3Region
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let proto = try c.decode(ConnectionProtocol.self, forKey: .connectionProtocol)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
            connectionProtocol: proto,
            host: try c.decode(String.self, forKey: .host),
            port: try c.decodeIfPresent(Int.self, forKey: .port),
            username: try c.decodeIfPresent(String.self, forKey: .username) ?? "",
            authenticationKind: try c.decodeIfPresent(AuthenticationKind.self, forKey: .authenticationKind) ?? .password,
            privateKeyPath: try c.decodeIfPresent(String.self, forKey: .privateKeyPath),
            initialPath: try c.decodeIfPresent(String.self, forKey: .initialPath),
            ftpDataMode: try c.decodeIfPresent(FTPDataConnectionMode.self, forKey: .ftpDataMode) ?? .passive,
            allowsUntrustedCertificates: try c.decodeIfPresent(Bool.self, forKey: .allowsUntrustedCertificates) ?? false,
            s3Region: try c.decodeIfPresent(String.self, forKey: .s3Region) ?? ConnectionConfiguration.defaultS3Region
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(connectionProtocol, forKey: .connectionProtocol)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(username, forKey: .username)
        try c.encode(authenticationKind, forKey: .authenticationKind)
        try c.encodeIfPresent(privateKeyPath, forKey: .privateKeyPath)
        try c.encodeIfPresent(initialPath, forKey: .initialPath)
        try c.encode(ftpDataMode, forKey: .ftpDataMode)
        try c.encode(allowsUntrustedCertificates, forKey: .allowsUntrustedCertificates)
        try c.encode(s3Region, forKey: .s3Region)
    }
}

// MARK: - Depuis une connexion existante

extension ServerBookmark {
    /// Favori reprenant tous les paramètres d'une connexion (ex. connexion rapide),
    /// et le secret à ranger dans le Keychain (mot de passe ou passphrase de la clé).
    public static func from(_ configuration: ConnectionConfiguration, name: String) -> (bookmark: ServerBookmark, secret: String?) {
        var bookmark = ServerBookmark(
            name: name,
            connectionProtocol: configuration.connectionProtocol,
            host: configuration.host,
            port: configuration.port,
            username: configuration.username,
            initialPath: configuration.initialPath?.string,
            ftpDataMode: configuration.ftpDataMode,
            allowsUntrustedCertificates: configuration.allowsUntrustedCertificates,
            s3Region: configuration.s3Region
        )
        switch configuration.credential {
        case .anonymous:
            return (bookmark, nil)
        case .password(let password):
            return (bookmark, password.isEmpty ? nil : password)
        case .privateKey(let url, let passphrase):
            bookmark.authenticationKind = .privateKey
            bookmark.privateKeyPath = (url.path as NSString).abbreviatingWithTildeInPath
            return (bookmark, passphrase)
        }
    }
}
