import CryptoKit
import Foundation

/// Lecture (seule) d'un fichier OpenSSH `~/.ssh/known_hosts`, y compris les entrées
/// hachées (`|1|sel|hash`, option `HashKnownHosts yes`).
///
/// L'app n'écrit jamais dans ce fichier : les approbations sont enregistrées dans
/// son propre ``HostKeyStore``.
public struct KnownHostsFile: Sendable {
    struct Entry: Sendable {
        let hostPatterns: [String]
        let keyType: String
        let keyBase64: String
    }

    let entries: [Entry]

    public init(contents: String) {
        entries = contents.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            var fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // Marqueurs `@cert-authority` / `@revoked` : non gérés, on ignore la ligne.
            if fields.first?.hasPrefix("@") == true { return nil }
            guard fields.count >= 3 else { return nil }
            let patterns = fields.removeFirst().split(separator: ",").map(String.init)
            return Entry(hostPatterns: patterns, keyType: fields[0], keyBase64: fields[1])
        }
    }

    public static func load(from url: URL) -> KnownHostsFile {
        KnownHostsFile(contents: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    /// Clés OpenSSH (`type base64`) enregistrées pour cet hôte.
    public func keys(for host: KnownHostIdentifier) -> [String] {
        let name = host.description
        return entries
            .filter { entry in entry.hostPatterns.contains { Self.matches(pattern: $0, hostName: name) } }
            .map { "\($0.keyType) \($0.keyBase64)" }
    }

    static func matches(pattern: String, hostName: String) -> Bool {
        if pattern.hasPrefix("|1|") {
            let parts = pattern.split(separator: "|").map(String.init)
            guard parts.count == 3,
                  let salt = Data(base64Encoded: parts[1]),
                  let expected = Data(base64Encoded: parts[2]) else { return false }
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(hostName.utf8), using: SymmetricKey(data: salt))
            return Data(mac) == expected
        }
        return pattern.lowercased() == hostName
    }
}
