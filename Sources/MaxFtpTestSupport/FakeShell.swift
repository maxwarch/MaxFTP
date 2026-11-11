import Foundation
import MaxFtpCore

/// Doublure de ``RemoteShell`` : mémorise ce qui est envoyé, émet la sortie à la demande.
public actor FakeShell: RemoteShell {
    public private(set) var sent: [Data] = []
    public private(set) var sizes: [(columns: Int, rows: Int)] = []
    public private(set) var isClosed = false
    private let failure: (any Error)?
    private var continuation: AsyncThrowingStream<Data, any Error>.Continuation?

    public init(failure: (any Error)? = nil) {
        self.failure = failure
    }

    public var sentText: String { sent.map { String(decoding: $0, as: UTF8.self) }.joined() }

    public func start(columns: Int, rows: Int) async throws -> AsyncThrowingStream<Data, any Error> {
        if let failure { throw failure }
        sizes.append((columns, rows))
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    public func send(_ data: Data) async { sent.append(data) }
    public func resize(columns: Int, rows: Int) async { sizes.append((columns, rows)) }

    public func close() async {
        isClosed = true
        continuation?.finish()
    }

    /// Simule une sortie du shell.
    public func emit(_ text: String) { continuation?.yield(Data(text.utf8)) }
    /// Simule `exit`.
    public func finish() { continuation?.finish() }
}
