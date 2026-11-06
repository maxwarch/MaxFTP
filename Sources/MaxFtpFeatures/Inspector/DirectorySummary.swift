import Foundation
import MaxFtpCore

/// Résumé d'un dossier pour l'inspecteur : compteurs, poids des fichiers et
/// premières entrées (dossiers d'abord, ordre du Finder).
struct DirectorySummary: Equatable {
    let entries: [RemoteItem]
    let folderCount: Int
    let fileCount: Int
    /// Éléments cachés (`.env`…) non affichés selon la préférence.
    let hiddenCount: Int
    /// Somme des tailles des fichiers du premier niveau (sans parcourir les sous-dossiers).
    let totalFileBytes: Int64
    /// Entrées visibles au-delà de `limit`, non listées.
    let remainingCount: Int

    init(items: [RemoteItem], showHidden: Bool, limit: Int = 200) {
        let visible = showHidden ? items : items.filter { !$0.isHidden }
        let byName: (RemoteItem, RemoteItem) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let folders = visible.filter(\.canBeOpenedAsDirectory).sorted(by: byName)
        let files = visible.filter { !$0.canBeOpenedAsDirectory }.sorted(by: byName)
        let ordered = folders + files

        entries = Array(ordered.prefix(limit))
        folderCount = folders.count
        fileCount = files.count
        hiddenCount = items.count - visible.count
        totalFileBytes = files.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        remainingCount = max(0, ordered.count - limit)
    }

    var isEmpty: Bool { folderCount + fileCount == 0 }

    /// « 3 dossiers · 12 fichiers »
    var countsDescription: String {
        func plural(_ count: Int, _ singular: String, _ plural: String) -> String {
            "\(count) \(count > 1 ? plural : singular)"
        }
        var parts: [String] = []
        if folderCount > 0 { parts.append(plural(folderCount, "dossier", "dossiers")) }
        if fileCount > 0 { parts.append(plural(fileCount, "fichier", "fichiers")) }
        return parts.isEmpty ? "Vide" : parts.joined(separator: " · ")
    }
}
