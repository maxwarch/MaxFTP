import Foundation
import MaxFtpCore

/// Correspondance entre un ``RemotePath`` et l'espace de noms S3.
///
/// Le premier composant du chemin est le bucket, le reste forme la clé :
/// `/` = liste des buckets, `/photos` = bucket, `/photos/2024/a.jpg` = objet.
/// Un « dossier » n'existe pas en S3 : c'est un préfixe de clé terminé par `/`.
enum S3Location: Equatable, Sendable {
    case root
    case bucket(String)
    case object(bucket: String, key: String)

    init(_ path: RemotePath) {
        guard let bucket = path.components.first else {
            self = .root
            return
        }
        let key = path.components.dropFirst().joined(separator: "/")
        self = key.isEmpty ? .bucket(bucket) : .object(bucket: bucket, key: key)
    }

    var bucket: String? {
        switch self {
        case .root: nil
        case .bucket(let name), .object(let name, _): name
        }
    }

    /// Préfixe à lister pour voir le contenu de ce « dossier » (`""` à la racine d'un bucket).
    var directoryPrefix: String {
        switch self {
        case .root, .bucket: ""
        case .object(_, let key): key + "/"
        }
    }
}
