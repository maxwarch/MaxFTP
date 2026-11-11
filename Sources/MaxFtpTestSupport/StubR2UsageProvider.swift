import Foundation
import MaxFtpCore

/// Doublure de ``R2UsageProvider`` : renvoie un résultat fixe et mémorise les appels.
public final class StubR2UsageProvider: R2UsageProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<R2Usage, any Error>
    private var calls: [(accountID: String, apiToken: String, period: DateInterval)] = []

    public init(_ result: Result<R2Usage, any Error>) {
        self.result = result
    }

    public var receivedTokens: [String] { lock.withLock { calls.map(\.apiToken) } }

    public func usage(accountID: String, apiToken: String, period: DateInterval) async throws -> R2Usage {
        lock.withLock { calls.append((accountID, apiToken, period)) }
        return try result.get()
    }
}
