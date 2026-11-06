import Foundation
import MaxFtpCore
import MaxFtpFeatures
import MaxFtpFTP
import MaxFtpSFTP
import MaxFtpStorage

/// Composition root : le SEUL endroit qui connaît les implémentations concrètes.
///
/// Pour remplacer une brique (SwiftData à la place du JSON, un autre client SSH…),
/// on écrit une nouvelle implémentation du protocole concerné et on la branche ici.
/// Aucun autre fichier de l'application n'a besoin de changer.
@MainActor
enum AppComposition {
    static func makeEnvironment() -> AppEnvironment {
        let userPrompts = UserPromptTracker()
        let hostKeyTrust = InteractiveHostKeyTrustPolicy(
            store: JSONHostKeyStore(),
            knownHostsURL: AppDirectories.sshDirectory.appendingPathComponent("known_hosts"),
            prompt: { challenge in
                await userPrompts.during { await MainActor.run { HostKeyAlert.present(challenge) } }
            }
        )

        let dependencies = AppDependencies(
            bookmarkRepository: JSONBookmarkRepository(),
            pathBookmarkRepository: JSONPathBookmarkRepository(),
            secretStore: KeychainSecretStore(),
            fileSystemFactory: ProtocolFileSystemFactory(hostKeyTrust: hostKeyTrust),
            sshConfig: { SSHConfig.load(from: AppDirectories.sshDirectory.appendingPathComponent("config")) },
            defaultIdentityFiles: {
                ["id_ed25519", "id_rsa"].map { AppDirectories.sshDirectory.appendingPathComponent($0) }
            },
            userPrompts: userPrompts
        )
        return AppEnvironment(dependencies: dependencies)
    }
}

/// Associe chaque protocole à son adaptateur.
///
/// Le `switch` exhaustif est volontaire : ajouter un cas à ``ConnectionProtocol``
/// (WebDAV, S3…) provoque une erreur de compilation ICI, impossible à oublier.
struct ProtocolFileSystemFactory: RemoteFileSystemFactory {
    let hostKeyTrust: any HostKeyTrustPolicy

    func makeFileSystem(for configuration: ConnectionConfiguration) -> any RemoteFileSystem {
        switch configuration.connectionProtocol {
        case .sftp:
            SFTPFileSystem(configuration: configuration, hostKeyTrust: hostKeyTrust)
        case .ftp, .ftpsExplicit, .ftpsImplicit:
            FTPFileSystem(configuration: configuration)
        }
    }
}
