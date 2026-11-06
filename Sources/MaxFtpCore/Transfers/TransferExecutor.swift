import Foundation

/// Exécute un ``TransferPlan`` sur un ``RemoteFileSystem`` en agrégeant la progression.
public enum TransferExecutor {
    /// - Parameter progress: reçoit le total d'octets transférés pour l'ensemble du plan.
    public static func execute(
        _ plan: TransferPlan,
        on fileSystem: any RemoteFileSystem,
        fileManager: FileManager = .default,
        progress: @escaping TransferProgressHandler
    ) async throws {
        var completedBytes: Int64 = 0

        for step in plan.steps {
            try Task.checkCancellation()
            let base = completedBytes
            let report: TransferProgressHandler = { progress(base + $0) }

            switch step {
            case .createRemoteDirectory(let path):
                try await fileSystem.createDirectoryIfNeeded(at: path)
            case .createLocalDirectory(let url):
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            case .upload(let source, let destination, _):
                try await fileSystem.upload(source, to: destination, progress: report)
            case .download(let source, let destination, _):
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await fileSystem.download(source, to: destination, progress: report)
            }

            completedBytes += step.byteCount
            progress(completedBytes)
        }
    }
}
