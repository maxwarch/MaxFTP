import Foundation

/// Un fichier, dossier ou lien listé sur le serveur, indépendamment du protocole.
public struct RemoteItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case file, directory, symbolicLink, other
    }

    public var id: RemotePath { path }
    public let path: RemotePath
    public var kind: Kind
    public var size: Int64?
    public var modificationDate: Date?
    public var permissions: POSIXPermissions?
    public var owner: String?
    public var group: String?
    public var symbolicLinkTarget: String?

    public init(
        path: RemotePath,
        kind: Kind,
        size: Int64? = nil,
        modificationDate: Date? = nil,
        permissions: POSIXPermissions? = nil,
        owner: String? = nil,
        group: String? = nil,
        symbolicLinkTarget: String? = nil
    ) {
        self.path = path
        self.kind = kind
        self.size = size
        self.modificationDate = modificationDate
        self.permissions = permissions
        self.owner = owner
        self.group = group
        self.symbolicLinkTarget = symbolicLinkTarget
    }

    public var name: String { path.name }
    public var isDirectory: Bool { kind == .directory }
    public var isHidden: Bool { name.hasPrefix(".") }

    /// Un lien symbolique peut pointer vers un dossier : on tente d'y naviguer.
    public var canBeOpenedAsDirectory: Bool { kind == .directory || kind == .symbolicLink }

    /// Extension de fichier, utile pour déterminer l'UTType.
    public var pathExtension: String { (name as NSString).pathExtension }
}

// MARK: - Clés de tri non optionnelles (pour `KeyPathComparator` / `Table`)

extension RemoteItem {
    public var sortableSize: Int64 { isDirectory ? -1 : (size ?? 0) }
    public var sortableDate: Date { modificationDate ?? .distantPast }
    public var sortablePermissions: UInt16 { permissions?.rawValue ?? 0 }
}
