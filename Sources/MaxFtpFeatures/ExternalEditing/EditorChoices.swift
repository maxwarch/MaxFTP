import Foundation

/// Applications choisies pour l'édition externe : un éditeur par défaut (Réglages)
/// et des associations par extension (« Toujours ouvrir avec », comme le Finder).
///
/// Ordre de résolution : extension → éditeur par défaut → application du système (`nil`).
public struct EditorChoices: Codable, Equatable, Sendable {
    public var defaultEditor: URL?
    /// Extension en minuscules (`""` = fichiers sans extension) → application.
    public var byExtension: [String: URL]

    public init(defaultEditor: URL? = nil, byExtension: [String: URL] = [:]) {
        self.defaultEditor = defaultEditor
        self.byExtension = byExtension
    }

    public static func extensionKey(forFileNamed name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    /// Application à utiliser pour ce fichier ; une app désinstallée est ignorée.
    public func application(forFileNamed name: String, exists: (URL) -> Bool = Self.applicationExists) -> URL? {
        if let specific = byExtension[Self.extensionKey(forFileNamed: name)], exists(specific) {
            return specific
        }
        if let defaultEditor, exists(defaultEditor) {
            return defaultEditor
        }
        return nil
    }

    public mutating func alwaysOpen(filesNamedLike name: String, with application: URL) {
        byExtension[Self.extensionKey(forFileNamed: name)] = application
    }

    public static func applicationExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: Persistance (UserDefaults, données JSON)

    public init(data: Data) {
        self = (try? JSONDecoder().decode(Self.self, from: data)) ?? Self()
    }

    public var data: Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }
}
