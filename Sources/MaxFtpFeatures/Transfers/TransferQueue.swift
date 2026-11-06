import Foundation
import MaxFtpCore
import Observation
import os

/// Ce qu'il faut transférer. Chaque cas est indépendant de la fenêtre d'origine.
public enum TransferJob: Sendable {
    /// Fichier ou dossier local (récursif) envoyé dans `remoteDirectory`.
    case upload(URL, into: RemotePath)
    /// Fichier local envoyé vers un chemin précis (ré-upload après édition externe).
    case replace(RemotePath, with: URL)
    /// Fichier ou dossier distant (récursif) téléchargé dans `localDirectory`.
    case download(RemoteItem, into: URL)
}

/// Un transfert affiché dans la file, observé par l'UI.
@MainActor
@Observable
public final class TransferItem: Identifiable {
    public enum Direction { case upload, download }

    public enum State: Equatable {
        case waiting, preparing, running, completed, cancelled
        case failed(String)

        var isFinished: Bool {
            switch self {
            case .completed, .cancelled, .failed: true
            case .waiting, .preparing, .running: false
            }
        }
    }

    public let id = UUID()
    public let title: String
    public let direction: Direction
    public let job: TransferJob
    public let configuration: ConnectionConfiguration
    public internal(set) var state: State = .waiting
    public internal(set) var totalBytes: Int64 = 0
    public internal(set) var transferredBytes: Int64 = 0
    public internal(set) var bytesPerSecond: Double = 0

    let onCompletion: (@MainActor () -> Void)?
    var task: Task<Void, Never>?
    private var lastSample: (date: Date, bytes: Int64)?

    init(job: TransferJob, configuration: ConnectionConfiguration, onCompletion: (@MainActor () -> Void)?) {
        self.job = job
        self.configuration = configuration
        self.onCompletion = onCompletion
        switch job {
        case .upload(let url, _):
            title = url.lastPathComponent
            direction = .upload
        case .replace(let path, _):
            title = path.name
            direction = .upload
        case .download(let item, _):
            title = item.name
            direction = .download
        }
    }

    public var fractionCompleted: Double? {
        totalBytes > 0 ? min(1, Double(transferredBytes) / Double(totalBytes)) : nil
    }

    public func cancel() {
        task?.cancel()
        if state == .waiting { state = .cancelled }
    }

    /// Met à jour la progression et une moyenne glissante de la vitesse.
    func record(bytes: Int64, at date: Date = Date()) {
        guard bytes >= transferredBytes else { return }  // mise à jour arrivée en retard
        if let last = lastSample {
            let elapsed = date.timeIntervalSince(last.date)
            if elapsed > 0 {
                let instant = Double(bytes - last.bytes) / elapsed
                bytesPerSecond = bytesPerSecond == 0 ? instant : bytesPerSecond * 0.7 + instant * 0.3
            }
        }
        lastSample = (date, bytes)
        transferredBytes = bytes
    }
}

/// File de transferts partagée par toutes les fenêtres.
///
/// Chaque transfert ouvre SA PROPRE connexion via la factory : FTP ne permet
/// qu'une opération à la fois par session, et la navigation reste ainsi fluide
/// pendant les transferts.
@MainActor
@Observable
public final class TransferQueue {
    public private(set) var items: [TransferItem] = []

    private let factory: any RemoteFileSystemFactory
    private let maxConcurrent: () -> Int
    private let logger = Logger(subsystem: "com.maxftp.app", category: "Transfers")

    public init(factory: any RemoteFileSystemFactory, maxConcurrent: @escaping () -> Int = { AppSettings.maxConcurrentTransfers }) {
        self.factory = factory
        self.maxConcurrent = maxConcurrent
    }

    public var activeCount: Int { items.filter { !$0.state.isFinished }.count }

    public var failedCount: Int {
        items.filter { if case .failed = $0.state { true } else { false } }.count
    }

    /// Avancement global des transferts en cours (barre d'état).
    public var overallProgress: Double? { Self.overallProgress(of: items) }

    /// Octets transférés / octets à transférer, sur les transferts non terminés dont
    /// la taille est connue. `nil` tant qu'aucune taille n'est connue (préparation).
    static func overallProgress(of items: [TransferItem]) -> Double? {
        let sized = items.filter { !$0.state.isFinished && $0.totalBytes > 0 }
        let total = sized.reduce(Int64(0)) { $0 + $1.totalBytes }
        guard total > 0 else { return nil }
        let done = sized.reduce(Int64(0)) { $0 + min($1.transferredBytes, $1.totalBytes) }
        return Double(done) / Double(total)
    }

    @discardableResult
    public func enqueue(
        _ job: TransferJob,
        configuration: ConnectionConfiguration,
        onCompletion: (@MainActor () -> Void)? = nil
    ) -> TransferItem {
        let item = TransferItem(job: job, configuration: configuration, onCompletion: onCompletion)
        items.append(item)
        startPendingTransfers()
        return item
    }

    public func cancelAll() {
        items.forEach { $0.cancel() }
    }

    public func clearFinished() {
        items.removeAll { $0.state.isFinished }
    }

    // MARK: Ordonnancement

    private func startPendingTransfers() {
        let running = items.filter { $0.state == .preparing || $0.state == .running }.count
        let pending = items.filter { $0.state == .waiting }
        for item in pending.prefix(max(0, maxConcurrent() - running)) {
            item.state = .preparing
            item.task = Task { [weak self] in
                await self?.run(item)
                self?.startPendingTransfers()
            }
        }
    }

    private func run(_ item: TransferItem) async {
        let fileSystem = factory.makeFileSystem(for: item.configuration)
        do {
            try await fileSystem.connect()
            let plan = try await makePlan(for: item.job, using: fileSystem)
            item.totalBytes = plan.totalBytes
            item.state = .running

            let throttle = ProgressThrottle()
            try await TransferExecutor.execute(plan, on: fileSystem) { bytes in
                guard throttle.shouldEmit() else { return }
                Task { @MainActor in item.record(bytes: bytes) }
            }
            item.record(bytes: plan.totalBytes)
            item.state = .completed
            item.onCompletion?()
        } catch {
            if Task.isCancelled || error is CancellationError {
                item.state = .cancelled
            } else {
                logger.error("Échec du transfert \(item.title, privacy: .public) : \(error.localizedDescription, privacy: .public)")
                item.state = .failed(error.localizedDescription)
            }
        }
        await fileSystem.disconnect()
    }

    private func makePlan(for job: TransferJob, using fileSystem: any RemoteFileSystem) async throws -> TransferPlan {
        switch job {
        case .upload(let url, let directory):
            return try TransferPlanner.uploadPlan(for: url, into: directory)
        case .replace(let path, let url):
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return TransferPlan(steps: [.upload(url, to: path, size: Int64(size))])
        case .download(let item, let directory):
            // Ne jamais écraser un fichier local existant : `photo 2.jpg` (comme le Finder).
            let destination = LocalFileIO.uniqueURL(for: directory.appendingPathComponent(item.name, isDirectory: item.isDirectory))
            return try await TransferPlanner.downloadPlan(for: item, to: destination, using: fileSystem)
        }
    }
}

/// Limite la fréquence des mises à jour de progression envoyées à l'UI (~10/s).
final class ProgressThrottle: Sendable {
    private let lastEmission = OSAllocatedUnfairLock(initialState: Date.distantPast)
    private let interval: TimeInterval

    init(interval: TimeInterval = 0.1) {
        self.interval = interval
    }

    func shouldEmit() -> Bool {
        lastEmission.withLock { last in
            let now = Date()
            guard now.timeIntervalSince(last) >= interval else { return false }
            last = now
            return true
        }
    }
}
