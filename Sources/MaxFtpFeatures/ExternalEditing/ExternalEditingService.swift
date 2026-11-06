import AppKit
import Foundation
import MaxFtpCore

/// Édition d'un fichier distant dans une app externe (BBEdit, VS Code, Nova…).
///
/// Le fichier est téléchargé dans un dossier temporaire puis surveillé : chaque
/// sauvegarde déclenche un ré-upload via la file de transferts. On compare la date
/// de modification par sondage (1 s) plutôt qu'avec FSEvents/kqueue, car beaucoup
/// d'éditeurs enregistrent par remplacement atomique du fichier, ce qui casse les
/// surveillances par descripteur.
@MainActor
final class ExternalEditingService {
    private struct Session {
        let task: Task<Void, Never>
    }

    private let transfers: TransferQueue
    private var sessions: [URL: Session] = [:]
    private let pollInterval: Duration

    init(transfers: TransferQueue, pollInterval: Duration = .seconds(1)) {
        self.transfers = transfers
        self.pollInterval = pollInterval
    }

    func beginEditing(
        _ localURL: URL,
        remotePath: RemotePath,
        configuration: ConnectionConfiguration,
        application: URL?,
        onUploaded: @escaping @MainActor () -> Void
    ) async throws {
        if let application {
            _ = try await NSWorkspace.shared.open([localURL], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
        } else if !NSWorkspace.shared.open(localURL) {
            throw RemoteError.localFileError("Aucune application ne sait ouvrir \(localURL.lastPathComponent).")
        }
        watch(localURL, remotePath: remotePath, configuration: configuration, onUploaded: onUploaded)
    }

    func stopAll() {
        sessions.values.forEach { $0.task.cancel() }
        sessions.removeAll()
    }

    private func watch(_ url: URL, remotePath: RemotePath, configuration: ConnectionConfiguration, onUploaded: @escaping @MainActor () -> Void) {
        sessions[url]?.task.cancel()
        let interval = pollInterval
        let task = Task { [weak self] in
            var lastModified = Self.modificationDate(of: url)
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                let modified = Self.modificationDate(of: url)
                guard let modified, modified != lastModified else { continue }
                lastModified = modified
                self?.transfers.enqueue(.replace(remotePath, with: url), configuration: configuration, onCompletion: onUploaded)
            }
        }
        sessions[url] = Session(task: task)
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
