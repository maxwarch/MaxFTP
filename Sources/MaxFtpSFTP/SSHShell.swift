@preconcurrency import Citadel
import Foundation
import MaxFtpCore
import NIOCore
import NIOSSH

/// Shell interactif sur un pseudo-terminal SSH (Citadel).
///
/// Ouvre sa propre connexion, comme les transferts (ADR 0005) : fermer le terminal
/// ne perturbe pas la session SFTP de la fenêtre, et inversement.
public actor SSHShell: RemoteShell {
    public nonisolated let configuration: ConnectionConfiguration
    private let hostKeyTrust: any HostKeyTrustPolicy

    private enum Input: Sendable {
        case data(Data)
        case resize(columns: Int, rows: Int)
    }

    private var client: SSHClient?
    private var input: AsyncStream<Input>.Continuation?
    private var session: Task<Void, Never>?

    public init(configuration: ConnectionConfiguration, hostKeyTrust: any HostKeyTrustPolicy) {
        self.configuration = configuration
        self.hostKeyTrust = hostKeyTrust
    }

    public func start(columns: Int, rows: Int) async throws -> AsyncThrowingStream<Data, any Error> {
        guard #available(macOS 15, *) else {
            throw RemoteError.unsupportedOperation("le terminal intégré nécessite macOS 15. Utilisez « Ouvrir dans Terminal ».")
        }
        await close()
        let client = try await SSHConnector.connect(configuration, hostKeyTrust: hostKeyTrust)
        self.client = client

        let (inputs, inputContinuation) = AsyncStream<Input>.makeStream()
        let (output, outputContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        input = inputContinuation

        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: columns,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        let host = configuration.host
        session = Task {
            do {
                try await client.withPTY(request) { inbound, outbound in
                    // Écriture (frappes, redimensionnement) et lecture en parallèle ;
                    // la lecture se termine quand le shell se ferme.
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for await event in inputs {
                                switch event {
                                case .data(let data):
                                    try await outbound.write(ByteBuffer(bytes: data))
                                case .resize(let columns, let rows):
                                    try await outbound.changeSize(cols: columns, rows: rows, pixelWidth: 0, pixelHeight: 0)
                                }
                            }
                        }
                        for try await chunk in inbound {
                            switch chunk {
                            case .stdout(let buffer), .stderr(let buffer):
                                outputContinuation.yield(Data(buffer.readableBytesView))
                            }
                        }
                        group.cancelAll()
                    }
                }
                outputContinuation.finish()
            } catch is SSHClient.CommandFailed {
                // `exit 1` ou dernière commande en échec : fin normale du shell.
                outputContinuation.finish()
            } catch let error as ChannelError where error == .alreadyClosed {
                // Après `exit`, le serveur a déjà fermé le canal que Citadel tente de refermer.
                outputContinuation.finish()
            } catch {
                outputContinuation.finish(throwing: SSHConnector.translate(error, host: host))
            }
            try? await client.close()
        }
        return output
    }

    public func send(_ data: Data) async {
        input?.yield(.data(data))
    }

    public func resize(columns: Int, rows: Int) async {
        input?.yield(.resize(columns: columns, rows: rows))
    }

    public func close() async {
        input?.finish()
        input = nil
        session?.cancel()
        session = nil
        try? await client?.close()
        client = nil
    }
}
