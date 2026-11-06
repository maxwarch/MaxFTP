import Foundation

/// Paramètres effectifs d'un hôte après résolution de `~/.ssh/config`.
public struct SSHHostSettings: Equatable, Sendable {
    public var hostName: String
    public var user: String?
    public var port: Int?
    public var identityFiles: [String] = []
}

/// Parseur minimal de `~/.ssh/config` : `Host`, `HostName`, `User`, `Port`, `IdentityFile`.
///
/// Respecte la sémantique OpenSSH : la PREMIÈRE valeur trouvée gagne, les motifs
/// `*`, `?` et la négation `!` sont supportés. `Match` et `Include` sont ignorés.
public struct SSHConfig: Sendable {
    struct Block: Sendable {
        var patterns: [String]
        var options: [(key: String, value: String)]
    }

    var blocks: [Block]

    public init(contents: String) {
        var blocks = [Block(patterns: ["*"], options: [])]
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let (key, value) = Self.splitOption(line)
            if key == "host" {
                blocks.append(Block(patterns: value.split(separator: " ").map(String.init), options: []))
            } else if key == "match" {
                blocks.append(Block(patterns: [], options: []))  // bloc jamais appliqué
            } else {
                blocks[blocks.count - 1].options.append((key, value))
            }
        }
        self.blocks = blocks
    }

    public static func load(from url: URL) -> SSHConfig {
        SSHConfig(contents: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    /// Résout un alias (`Host monserveur`) vers ses paramètres effectifs.
    public func settings(forAlias alias: String) -> SSHHostSettings {
        var settings = SSHHostSettings(hostName: alias)
        var seen = Set<String>()
        for block in blocks where Self.matches(alias, patterns: block.patterns) {
            for (key, value) in block.options {
                if key == "identityfile" {
                    settings.identityFiles.append((value as NSString).expandingTildeInPath)
                    continue
                }
                guard seen.insert(key).inserted else { continue }
                switch key {
                case "hostname": settings.hostName = value.replacingOccurrences(of: "%h", with: alias)
                case "user": settings.user = value
                case "port": settings.port = Int(value)
                default: break
                }
            }
        }
        return settings
    }

    /// Alias explicites (sans joker) — pour l'autocomplétion de la connexion rapide.
    public var aliases: [String] {
        blocks.flatMap(\.patterns).filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
    }

    static func splitOption(_ line: String) -> (String, String) {
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "="))
        guard let range = line.rangeOfCharacter(from: separators) else { return (line.lowercased(), "") }
        let key = String(line[..<range.lowerBound]).lowercased()
        var value = String(line[range.upperBound...]).trimmingCharacters(in: separators)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return (key, value)
    }

    static func matches(_ host: String, patterns: [String]) -> Bool {
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if glob(String(pattern.dropFirst()), matches: host) { return false }
            } else if glob(pattern, matches: host) {
                matched = true
            }
        }
        return matched
    }

    static func glob(_ pattern: String, matches string: String) -> Bool {
        let regex = "^" + NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".") + "$"
        return string.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
