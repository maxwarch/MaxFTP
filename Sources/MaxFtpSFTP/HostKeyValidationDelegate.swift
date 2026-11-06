import Foundation
import MaxFtpCore
import NIOCore
import NIOSSH

/// Validation de la clé d'hôte PENDANT la poignée de main : silencieuse et immédiate.
///
/// Une clé inconnue ou changée n'est pas soumise ici à l'utilisateur (la bibliothèque
/// SSH chronomètre la poignée de main) : elle est notée, la connexion échoue avec
/// ``Untrusted``, et ``SFTPFileSystem`` pose la question puis se reconnecte.
struct HostKeyValidationDelegate: NIOSSHClientServerAuthenticationDelegate, Sendable {
    struct Untrusted: Error {
        let challenge: HostKeyChallenge
    }

    /// Clé refusée, conservée hors de l'erreur : Citadel peut envelopper ou remplacer
    /// l'erreur de la promesse, la boîte garantit qu'on retrouve la clé à confirmer.
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: HostKeyChallenge?
        var challenge: HostKeyChallenge? { lock.withLock { stored } }
        func record(_ challenge: HostKeyChallenge) { lock.withLock { stored = challenge } }
    }

    let host: KnownHostIdentifier
    let policy: any HostKeyTrustPolicy
    let untrusted: Box

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        var challenge = HostKeyChallenge(host: host, openSSHKey: String(openSSHPublicKey: hostKey))
        if let status = policy.untrustedStatus(of: challenge) {
            challenge.status = status
            untrusted.record(challenge)
            validationCompletePromise.fail(Untrusted(challenge: challenge))
        } else {
            validationCompletePromise.succeed(())
        }
    }
}
