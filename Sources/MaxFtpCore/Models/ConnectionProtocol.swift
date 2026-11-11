import Foundation

/// Protocoles supportés. Ajouter un cas ici fait échouer la compilation partout où
/// un `switch` exhaustif doit être complété (factory, UI…) : c'est voulu.
public enum ConnectionProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case sftp
    case ftp
    case ftpsExplicit
    case ftpsImplicit
    /// Stockage objet compatible S3 (Cloudflare R2, AWS S3, MinIO…). Voir ADR 0008.
    case s3

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sftp: "SFTP (SSH)"
        case .ftp: "FTP"
        case .ftpsExplicit: "FTPS (TLS explicite)"
        case .ftpsImplicit: "FTPS (TLS implicite)"
        case .s3: "S3 / Cloudflare R2"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .sftp: 22
        case .ftp, .ftpsExplicit: 21
        case .ftpsImplicit: 990
        case .s3: 443
        }
    }

    /// Schéma d'URL utilisé par la connexion rapide (`sftp://user@host`).
    public var urlScheme: String {
        switch self {
        case .sftp: "sftp"
        case .ftp: "ftp"
        case .ftpsExplicit: "ftpes"
        case .ftpsImplicit: "ftps"
        case .s3: "s3"
        }
    }

    public init?(urlScheme: String) {
        guard let match = Self.allCases.first(where: { $0.urlScheme == urlScheme.lowercased() }) else {
            if urlScheme.lowercased() == "ssh" { self = .sftp; return }
            return nil
        }
        self = match
    }

    public var supportsKeyAuthentication: Bool { self == .sftp }
    public var usesTLS: Bool { self == .ftpsExplicit || self == .ftpsImplicit }
    public var isFTPFamily: Bool { self == .ftp || usesTLS }
    /// Stockage objet : buckets et clés, pas de vrais dossiers ni de permissions POSIX.
    public var isObjectStorage: Bool { self == .s3 }
    public var supportsPermissions: Bool { !isObjectStorage }
    /// Seul SSH offre un shell ; FTP n'a pas d'équivalent.
    public var supportsShell: Bool { self == .sftp }
}

/// Mode d'ouverture du canal de données FTP.
public enum FTPDataConnectionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case passive
    case active

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .passive: "Passif (recommandé)"
        case .active: "Actif"
        }
    }
}
