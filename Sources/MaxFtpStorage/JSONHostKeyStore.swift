import Foundation
import MaxFtpCore

/// Clés d'hôte SSH approuvées dans l'app (`Application Support/MaxFtp/known_hosts.json`).
///
/// On n'écrit pas dans `~/.ssh/known_hosts` pour ne jamais altérer la config
/// OpenSSH de l'utilisateur ; ce fichier-là est seulement lu.
public struct JSONHostKeyStore: HostKeyStore {
    private let store: JSONFileStore<[String: [String]]>

    public init(fileURL: URL = AppDirectories.applicationSupport.appendingPathComponent("known_hosts.json")) {
        self.store = JSONFileStore(fileURL: fileURL)
    }

    public func trustedKeys(for host: KnownHostIdentifier) throws -> [String] {
        try store.read()?[host.description] ?? []
    }

    public func trust(_ openSSHKey: String, for host: KnownHostIdentifier) throws {
        try store.update(default: [:]) { hosts in
            var keys = hosts[host.description] ?? []
            // Une nouvelle clé du même type remplace l'ancienne (rotation de clé).
            let type = openSSHKey.split(separator: " ").first
            keys.removeAll { $0.split(separator: " ").first == type }
            keys.append(openSSHKey)
            hosts[host.description] = keys
        }
    }
}
