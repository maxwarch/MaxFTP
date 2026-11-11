import Foundation

/// Erreurs normalisées remontées par tous les adaptateurs.
///
/// Les adaptateurs traduisent leurs erreurs internes (NIO, Citadel, codes FTP)
/// vers ce type pour que l'UI n'ait qu'un seul vocabulaire à afficher.
public enum RemoteError: LocalizedError, Equatable, Sendable {
    case notConnected
    case connectionClosed
    case connectionFailed(String)
    case authenticationFailed(String?)
    case hostKeyRejected(host: String)
    case unsupportedPrivateKey(String)
    case invalidPath(String)
    case protocolViolation(String)
    case serverError(code: Int, message: String)
    case localFileError(String)
    case unsupportedOperation(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            "Aucune connexion active."
        case .connectionClosed:
            "La connexion a été fermée par le serveur."
        case .connectionFailed(let reason):
            "Connexion impossible : \(reason)"
        case .authenticationFailed(let reason):
            "Échec de l'authentification" + (reason.map { " : \($0)" } ?? ".")
        case .hostKeyRejected(let host):
            "La clé d'hôte de \(host) a été refusée."
        case .unsupportedPrivateKey(let reason):
            "Clé privée non prise en charge : \(reason)"
        case .invalidPath(let path):
            "Chemin invalide : \(path)"
        case .protocolViolation(let detail):
            "Réponse inattendue du serveur : \(detail)"
        case .serverError(let code, let message):
            "Erreur serveur \(code) : \(message)"
        case .localFileError(let detail):
            "Erreur de fichier local : \(detail)"
        case .unsupportedOperation(let detail):
            "Opération non prise en charge : \(detail)"
        }
    }
}
