import Foundation
import MaxFtpCore
import Observation

/// Session de terminal affichée dans la fenêtre : relie un ``RemoteShell`` à l'émulateur.
///
/// Repère aussi la fin des commandes (Entrée, puis plus de sortie pendant un court
/// instant) pour que l'explorateur se mette à jour en direct (`mkdir`, `touch`…).
@MainActor
@Observable
public final class TerminalSession {
    public enum State: Equatable {
        case idle, connecting, running, ended
        case failed(String)
    }

    public private(set) var state: State = .idle
    public let initialDirectory: RemotePath?

    private let shell: any RemoteShell
    private let settleDelay: Duration
    private let onCommandCompleted: @MainActor () -> Void
    private var output: (@MainActor (Data) -> Void)?
    private var reader: Task<Void, Never>?
    private var awaitingCommandEnd = false
    private var settle: Task<Void, Never>?

    public init(
        shell: any RemoteShell,
        initialDirectory: RemotePath?,
        settleDelay: Duration = .milliseconds(400),
        onCommandCompleted: @escaping @MainActor () -> Void = {}
    ) {
        self.shell = shell
        self.initialDirectory = initialDirectory
        self.settleDelay = settleDelay
        self.onCommandCompleted = onCommandCompleted
    }

    /// Ouvre le shell ; `output` reçoit les octets à afficher.
    public func start(columns: Int, rows: Int, output: @escaping @MainActor (Data) -> Void) async {
        guard state != .connecting, state != .running else { return }
        self.output = output
        state = .connecting
        let stream: AsyncThrowingStream<Data, any Error>
        do {
            stream = try await shell.start(columns: columns, rows: rows)
        } catch {
            state = .failed(Self.message(for: error))
            return
        }
        state = .running
        if let initialDirectory {
            await shell.send(Data(ShellCommand.changeDirectory(to: initialDirectory).utf8))
        }
        reader = Task { [weak self] in
            do {
                for try await chunk in stream {
                    self?.received(chunk)
                }
                self?.state = .ended
            } catch {
                self?.state = .failed(Self.message(for: error))
            }
        }
    }

    /// Frappes de l'utilisateur.
    public func send(_ data: Data) {
        if data.contains(0x0D) || data.contains(0x0A) { awaitingCommandEnd = true }
        let shell = shell
        Task { await shell.send(data) }
    }

    public func resize(columns: Int, rows: Int) {
        let shell = shell
        Task { await shell.resize(columns: columns, rows: rows) }
    }

    public func close() async {
        reader?.cancel()
        settle?.cancel()
        await shell.close()
        if state == .running || state == .connecting { state = .ended }
    }

    private func received(_ chunk: Data) {
        output?(chunk)
        guard awaitingCommandEnd else { return }
        // Chaque nouveau bloc repousse l'échéance : on attend que la sortie se calme.
        settle?.cancel()
        settle = Task { [weak self, settleDelay] in
            try? await Task.sleep(for: settleDelay)
            guard !Task.isCancelled, let self else { return }
            self.awaitingCommandEnd = false
            self.onCommandCompleted()
        }
    }

    private static func message(for error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
