import AppKit
import MaxFtpCore
import UniformTypeIdentifiers

/// Formatage cohérent des valeurs affichées dans toute l'app.
enum Formatting {
    static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func size(of item: RemoteItem) -> String {
        guard !item.isDirectory, let size = item.size else { return "—" }
        return byteCount(size)
    }

    static func date(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "—"
    }

    static func permissions(_ permissions: POSIXPermissions?) -> String {
        guard let permissions else { return "—" }
        return "\(permissions.symbolicString)  \(permissions.octalString)"
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        byteCount(Int64(bytesPerSecond)) + "/s"
    }
}

/// Icônes système (Finder) des fichiers distants, mises en cache par type.
@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func contentType(for item: RemoteItem) -> UTType {
        switch item.kind {
        case .directory: .folder
        case .symbolicLink where item.canBeOpenedAsDirectory && item.pathExtension.isEmpty: .aliasFile
        default: UTType(filenameExtension: item.pathExtension) ?? .data
        }
    }

    static func icon(for item: RemoteItem) -> NSImage {
        let type = contentType(for: item)
        if let cached = cache[type.identifier] { return cached }
        let icon = NSWorkspace.shared.icon(for: type)
        cache[type.identifier] = icon
        return icon
    }
}
