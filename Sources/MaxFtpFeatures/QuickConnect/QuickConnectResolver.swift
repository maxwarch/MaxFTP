import Foundation
import MaxFtpCore

/// Transforme la saisie de la connexion rapide en ``ConnectionConfiguration``,
/// en complétant avec `~/.ssh/config` et les clés SSH par défaut.
///
/// Logique pure (aucune UI, aucun accès disque hors `fileExists`) : testable unitairement.
public struct QuickConnectResolver: Sendable {
    let sshConfig: SSHConfig
    let defaultIdentityFiles: [URL]
    let localUsername: String

    public init(sshConfig: SSHConfig, defaultIdentityFiles: [URL], localUsername: String = NSUserName()) {
        self.sshConfig = sshConfig
        self.defaultIdentityFiles = defaultIdentityFiles
        self.localUsername = localUsername
    }

    public var sshAliases: [String] { sshConfig.aliases }

    public func configuration(
        for input: String,
        password: String,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> ConnectionConfiguration? {
        guard let target = QuickConnectTarget(parsing: input) else { return nil }
        let secret = password.isEmpty ? (target.password ?? "") : password

        guard target.connectionProtocol == .sftp else {
            let username = target.username ?? ""
            return ConnectionConfiguration(
                connectionProtocol: target.connectionProtocol,
                host: target.host,
                port: target.port,
                username: username,
                credential: username.isEmpty && secret.isEmpty ? .anonymous : .password(secret),
                initialPath: target.path
            )
        }

        let settings = sshConfig.settings(forAlias: target.host)
        let credential: Credential
        if !secret.isEmpty {
            credential = .password(secret)
        } else if let key = (settings.identityFiles.map { URL(fileURLWithPath: $0) } + defaultIdentityFiles).first(where: fileExists) {
            credential = .privateKey(key, passphrase: nil)
        } else {
            credential = .password("")
        }

        return ConnectionConfiguration(
            connectionProtocol: .sftp,
            host: settings.hostName,
            port: target.port ?? settings.port,
            username: target.username ?? settings.user ?? localUsername,
            credential: credential,
            initialPath: target.path
        )
    }
}
