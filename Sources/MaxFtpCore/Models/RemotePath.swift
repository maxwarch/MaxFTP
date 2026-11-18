import Foundation

/// Chemin absolu et normalisé sur le serveur distant (séparateur `/`).
///
/// Value type immuable : `.` et `..` sont résolus à la construction, si bien que
/// deux chemins égaux désignent toujours la même ressource.
public struct RemotePath: Hashable, Comparable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let components: [String]

    public static let root = RemotePath(components: [])

    public init(components: [String]) {
        self.components = Self.normalize(components)
    }

    public init(_ string: String) {
        self.components = Self.normalize(string.split(separator: "/", omittingEmptySubsequences: true))
    }

    private static func normalize<S: Sequence>(_ rawComponents: S) -> [String] where S.Element: StringProtocol {
        var result: [String] = []
        for raw in rawComponents {
            for part in raw.split(separator: "/", omittingEmptySubsequences: true) {
                let cleaned = part.replacingOccurrences(of: "\0", with: "")
                switch cleaned {
                case "", ".": continue
                case "..": _ = result.popLast()
                default: result.append(cleaned)
                }
            }
        }
        return result
    }

    /// Indique si `name` est un nom d'entrée valide (un seul segment, sans caractère de contrôle ni `.`/`..`).
    ///
    /// L'inspection se fait sur `utf8` : en Swift, `"\r\n"` forme un seul `Character` (grapheme cluster),
    /// si bien que `String.contains("\r")` et `String.contains("\n")` renverraient tous deux `false` sur `"\r\n"`.
    public static func isValidEntryName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        for byte in name.utf8 {
            if byte == UInt8(ascii: "/") || byte == 0 || byte == 0x0A || byte == 0x0D {
                return false
            }
        }
        return true
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    /// Représentation textuelle, toujours absolue (`/var/www`).
    public var string: String { "/" + components.joined(separator: "/") }
    public var description: String { string }

    public var isRoot: Bool { components.isEmpty }

    /// Dernier composant, ou `/` pour la racine.
    public var name: String { components.last ?? "/" }

    public var parent: RemotePath {
        isRoot ? self : RemotePath(components: Array(components.dropLast()))
    }

    /// Ajoute un nom de fichier. Un nom contenant `/` est découpé (comportement de `cd`).
    public func appending(_ name: String) -> RemotePath {
        RemotePath(string + "/" + name)
    }

    /// La racine puis chaque dossier jusqu'à `self` inclus — utile pour le fil d'Ariane.
    public var ancestors: [RemotePath] {
        (0...components.count).map { RemotePath(components: Array(components.prefix($0))) }
    }

    /// Élément direct de `ancestor` sur le chemin menant à `self`
    /// (`/a/b/c` sous `/a` → `/a/b`), ou `nil` si `self` n'est pas dessous.
    public func child(under ancestor: RemotePath) -> RemotePath? {
        guard isDescendant(of: ancestor) else { return nil }
        return RemotePath(components: Array(components.prefix(ancestor.components.count + 1)))
    }

    public func isDescendant(of other: RemotePath) -> Bool {
        components.count > other.components.count
            && Array(components.prefix(other.components.count)) == other.components
    }

    public static func < (lhs: RemotePath, rhs: RemotePath) -> Bool {
        lhs.string.localizedStandardCompare(rhs.string) == .orderedAscending
    }
}

extension RemotePath: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}
