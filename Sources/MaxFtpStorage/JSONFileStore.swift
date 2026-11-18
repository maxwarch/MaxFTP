import Foundation

/// Lecture / écriture atomique d'une valeur `Codable` dans un fichier JSON.
///
/// Brique générique réutilisée par tous les stores fichier de l'app.
/// Thread-safe : les accès sont sérialisés par un verrou.
public final class JSONFileStore<Value: Codable & Sendable>: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Renvoie `nil` si le fichier n'existe pas encore.
    public func read() throws -> Value? {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return try decoder.decode(Value.self, from: Data(contentsOf: fileURL))
        }
    }

    public func write(_ value: Value) throws {
        try lock.withLock {
            try writeUnlocked(value)
        }
    }

    /// Lecture-modification-écriture sous un même verrou.
    public func update(default defaultValue: Value, _ transform: (inout Value) throws -> Void) throws {
        try lock.withLock {
            var value = defaultValue
            if FileManager.default.fileExists(atPath: fileURL.path) {
                value = try decoder.decode(Value.self, from: Data(contentsOf: fileURL))
            }
            try transform(&value)
            try writeUnlocked(value)
        }
    }

    private func writeUnlocked(_ value: Value) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try encoder.encode(value).write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

/// Emplacements standard des fichiers de l'application.
public enum AppDirectories {
    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MaxFtp", isDirectory: true)
    }

    public static var sshDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
    }
}
