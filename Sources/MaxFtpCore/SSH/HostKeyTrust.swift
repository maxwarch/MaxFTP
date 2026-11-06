import CryptoKit
import Foundation

/// Identifiant d'hôte au format `known_hosts` : `host` sur le port 22, `[host]:port` sinon.
public struct KnownHostIdentifier: Hashable, Sendable, CustomStringConvertible {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host.lowercased()
        self.port = port
    }

    public var description: String { port == 22 ? host : "[\(host)]:\(port)" }
}

/// Clé publique présentée par un serveur SSH lors de la connexion.
public struct HostKeyChallenge: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// Jamais vue : première connexion.
        case unknown
        /// L'hôte est connu avec une AUTRE clé : possible attaque man-in-the-middle.
        case changed
    }

    public let host: KnownHostIdentifier
    /// Clé au format OpenSSH : `ssh-ed25519 AAAAC3Nza…`.
    public let openSSHKey: String
    public var status: Status

    public init(host: KnownHostIdentifier, openSSHKey: String, status: Status = .unknown) {
        self.host = host
        self.openSSHKey = openSSHKey
        self.status = status
    }

    public var keyType: String {
        openSSHKey.split(separator: " ").first.map(String.init) ?? "?"
    }

    /// Empreinte au format OpenSSH : `SHA256:base64-sans-padding`.
    public var fingerprint: String {
        let parts = openSSHKey.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "?" }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }
}

/// Décide si une clé d'hôte SSH est digne de confiance (vérification `known_hosts` + demande à l'utilisateur).
///
/// En deux temps, pour que la question posée à l'utilisateur ne tombe jamais PENDANT la
/// poignée de main SSH (la bibliothèque y applique ses propres délais : une réponse
/// réfléchie ferait échouer la connexion). Voir ADR 0007.
public protocol HostKeyTrustPolicy: Sendable {
    /// Vérification silencieuse, pendant la poignée de main : `nil` si la clé est approuvée,
    /// sinon le statut (inconnue / changée) à soumettre à l'utilisateur.
    func untrustedStatus(of challenge: HostKeyChallenge) -> HostKeyChallenge.Status?

    /// Demande à l'utilisateur, hors connexion, et mémorise la clé si elle est acceptée.
    func confirm(_ challenge: HostKeyChallenge) async -> Bool
}

extension HostKeyTrustPolicy {
    /// Les deux étapes enchaînées.
    public func evaluate(_ challenge: HostKeyChallenge) async -> Bool {
        guard let status = untrustedStatus(of: challenge) else { return true }
        var request = challenge
        request.status = status
        return await confirm(request)
    }
}
