import Foundation

/// Parseurs des réponses FTP qui transportent une donnée (port passif, chemin courant…).
enum FTPResponseParsing {
    /// `229 Entering Extended Passive Mode (|||6446|)` → 6446
    static func extendedPassivePort(from message: String) -> Int? {
        guard let open = message.firstIndex(of: "("), let close = message.lastIndex(of: ")"), open < close else { return nil }
        let inner = message[message.index(after: open)..<close]
        guard let delimiter = inner.first else { return nil }
        let fields = inner.split(separator: delimiter, omittingEmptySubsequences: false)
        // Format : <d><d><d><port><d> → ["", "", "", "6446", ""]
        guard fields.count == 5, let port = Int(fields[3]), (1...65535).contains(port) else { return nil }
        return port
    }

    /// `227 Entering Passive Mode (192,168,1,2,19,137)` → 5001
    ///
    /// L'adresse IP annoncée est volontairement ignorée : on se reconnecte à l'hôte
    /// du canal de contrôle (évite les IP privées derrière NAT et les attaques « FTP bounce »).
    static func passivePort(from message: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+),(\d+),(\d+),(\d+),(\d+),(\d+)"#),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let p1Range = Range(match.range(at: 5), in: message),
              let p2Range = Range(match.range(at: 6), in: message),
              let p1 = Int(message[p1Range]), let p2 = Int(message[p2Range]),
              (0...255).contains(p1), (0...255).contains(p2) else { return nil }
        let port = p1 * 256 + p2
        return port > 0 ? port : nil
    }

    /// `257 "/home/user" is the current directory` → `/home/user` (les `""` sont des guillemets échappés).
    static func quotedPath(from message: String) -> String? {
        guard let start = message.firstIndex(of: "\"") else { return nil }
        var result = ""
        var index = message.index(after: start)
        while index < message.endIndex {
            let char = message[index]
            if char == "\"" {
                let next = message.index(after: index)
                if next < message.endIndex, message[next] == "\"" {
                    result.append("\"")
                    index = message.index(after: next)
                    continue
                }
                return result
            }
            result.append(char)
            index = message.index(after: index)
        }
        return nil
    }

    /// Lignes de la réponse `FEAT` → ensemble des mots-clés (`MLST`, `UTF8`, `EPSV`…).
    static func features(from lines: [String]) -> Set<String> {
        Set(lines.dropFirst().dropLast().compactMap { line in
            line.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map { $0.uppercased() }
        })
    }
}
