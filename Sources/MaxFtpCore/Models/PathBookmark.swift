import Foundation

/// Signet : raccourci vers un dossier ou un fichier précis d'un serveur.
public struct PathBookmark: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var path: RemotePath
    public var isDirectory: Bool

    public init(id: UUID = UUID(), name: String? = nil, path: RemotePath, isDirectory: Bool) {
        self.id = id
        self.name = name ?? path.name
        self.path = path
        self.isDirectory = isDirectory
    }
}

extension ConnectionConfiguration {
    /// Identité du serveur à laquelle sont rattachés les signets :
    /// `protocole://utilisateur@hôte:port`, hôte en minuscules.
    ///
    /// Indépendante du favori, pour que la connexion rapide partage les mêmes signets.
    public var serverKey: String {
        "\(connectionProtocol.urlScheme)://\(username)@\(host.lowercased()):\(port)"
    }
}

extension ServerBookmark {
    /// Clé des signets du serveur visé par ce favori (le secret n'y entre pas).
    public var serverKey: String { configuration(secret: nil).serverKey }
}
