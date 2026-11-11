@preconcurrency import Citadel
import Foundation
import MaxFtpCore
import NIOCore

/// Ouverture d'une connexion SSH authentifiée, partagée par SFTP et le terminal.
///
/// Une clé d'hôte inconnue ou changée est soumise à l'utilisateur HORS poignée de
/// main (il peut prendre son temps), puis on se reconnecte avec la clé approuvée (ADR 0007).
enum SSHConnector {
    static func connect(_ configuration: ConnectionConfiguration, hostKeyTrust: any HostKeyTrustPolicy) async throws -> SSHClient {
        let untrusted = HostKeyValidationDelegate.Box()
        do {
            return try await open(configuration, hostKeyTrust: hostKeyTrust, recordingUntrustedKeyIn: untrusted)
        } catch {
            guard let challenge = untrusted.challenge else {
                throw translate(error, host: configuration.host)
            }
            guard await hostKeyTrust.confirm(challenge) else {
                throw RemoteError.hostKeyRejected(host: configuration.host)
            }
        }
        do {
            return try await open(configuration, hostKeyTrust: hostKeyTrust, recordingUntrustedKeyIn: HostKeyValidationDelegate.Box())
        } catch {
            throw translate(error, host: configuration.host)
        }
    }

    private static func open(
        _ configuration: ConnectionConfiguration,
        hostKeyTrust: any HostKeyTrustPolicy,
        recordingUntrustedKeyIn untrusted: HostKeyValidationDelegate.Box
    ) async throws -> SSHClient {
        let authentication = try SSHAuthenticationFactory.method(for: configuration)
        let validator = SSHHostKeyValidator.custom(HostKeyValidationDelegate(
            host: KnownHostIdentifier(host: configuration.host, port: configuration.port),
            policy: hostKeyTrust,
            untrusted: untrusted
        ))
        return try await SSHClient.connect(
            host: configuration.host,
            port: configuration.port,
            authenticationMethod: authentication,
            hostKeyValidator: validator,
            reconnect: .never,
            connectTimeout: .seconds(20)
        )
    }

    static func translate(_ error: any Error, host: String) -> any Error {
        if error is RemoteError || error is CancellationError { return error }
        // Clé encore refusée après confirmation (elle a changé entre les deux tentatives).
        if error is HostKeyValidationDelegate.Untrusted { return RemoteError.hostKeyRejected(host: host) }
        let description = String(describing: error)
        if description.localizedCaseInsensitiveContains("auth") {
            return RemoteError.authenticationFailed(nil)
        }
        return RemoteError.connectionFailed(description)
    }
}
