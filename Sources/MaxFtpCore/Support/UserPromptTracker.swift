import Foundation

/// Sait si une question est en cours auprès de l'utilisateur (ex. confirmer une clé d'hôte).
///
/// Les délais de connexion sont suspendus pendant ce temps : on ne veut pas qu'une
/// connexion échoue parce que l'utilisateur lit attentivement une empreinte.
public final class UserPromptTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var openPrompts = 0

    public init() {}

    public var isPrompting: Bool { lock.withLock { openPrompts > 0 } }

    public func during<T: Sendable>(_ prompt: @Sendable () async -> T) async -> T {
        lock.withLock { openPrompts += 1 }
        defer { lock.withLock { openPrompts -= 1 } }
        return await prompt()
    }
}
