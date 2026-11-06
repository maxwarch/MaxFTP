import Foundation

/// Permissions POSIX (`rwxr-xr-x` / `0755`), bits spéciaux setuid/setgid/sticky inclus.
public struct POSIXPermissions: Hashable, Sendable, Codable {
    public enum Scope: Int, CaseIterable, Sendable {
        case owner = 6, group = 3, others = 0

        public var label: String {
            switch self {
            case .owner: "Propriétaire"
            case .group: "Groupe"
            case .others: "Autres"
            }
        }
    }

    public enum Access: UInt16, CaseIterable, Sendable {
        case read = 4, write = 2, execute = 1

        public var label: String {
            switch self {
            case .read: "Lecture"
            case .write: "Écriture"
            case .execute: "Exécution"
            }
        }
    }

    static let setUID: UInt16 = 0o4000
    static let setGID: UInt16 = 0o2000
    static let sticky: UInt16 = 0o1000

    public private(set) var rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue & 0o7777
    }

    /// `"755"` ou `"0755"`.
    public init?(octal: String) {
        let trimmed = octal.trimmingCharacters(in: .whitespaces)
        guard (3...4).contains(trimmed.count), let value = UInt16(trimmed, radix: 8) else { return nil }
        self.init(rawValue: value)
    }

    /// `"rwxr-xr-x"`, ou la forme `ls -l` à 10 caractères (`"drwxr-xr-x"`).
    public init?(symbolic: String) {
        var chars = Array(symbolic)
        if chars.count == 10 { chars.removeFirst() }
        guard chars.count == 9 else { return nil }

        var value: UInt16 = 0
        for (index, scope) in Scope.allCases.enumerated() {
            let triplet = chars[(index * 3)..<(index * 3 + 3)].map { $0 }
            let shift = UInt16(scope.rawValue)
            if triplet[0] == "r" { value |= 4 << shift } else if triplet[0] != "-" { return nil }
            if triplet[1] == "w" { value |= 2 << shift } else if triplet[1] != "-" { return nil }

            let special: UInt16 = switch scope {
            case .owner: Self.setUID
            case .group: Self.setGID
            case .others: Self.sticky
            }
            switch triplet[2] {
            case "x": value |= 1 << shift
            case "s", "t": value |= (1 << shift) | special
            case "S", "T": value |= special
            case "-": break
            default: return nil
            }
        }
        self.init(rawValue: value)
    }

    /// Toujours 4 chiffres : `"0755"`.
    public var octalString: String {
        let digits = String(rawValue, radix: 8)
        return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }

    public var symbolicString: String {
        var result = ""
        for scope in Scope.allCases {
            result += allows(.read, for: scope) ? "r" : "-"
            result += allows(.write, for: scope) ? "w" : "-"
            let exec = allows(.execute, for: scope)
            let special: Bool
            let marks: (set: Character, unset: Character)
            switch scope {
            case .owner: special = rawValue & Self.setUID != 0; marks = ("s", "S")
            case .group: special = rawValue & Self.setGID != 0; marks = ("s", "S")
            case .others: special = rawValue & Self.sticky != 0; marks = ("t", "T")
            }
            result.append(special ? (exec ? marks.set : marks.unset) : (exec ? "x" : "-"))
        }
        return result
    }

    public func allows(_ access: Access, for scope: Scope) -> Bool {
        rawValue & (access.rawValue << UInt16(scope.rawValue)) != 0
    }

    public mutating func set(_ access: Access, for scope: Scope, enabled: Bool) {
        let bit = access.rawValue << UInt16(scope.rawValue)
        rawValue = enabled ? (rawValue | bit) : (rawValue & ~bit)
    }
}
