import Foundation

/// Délai dépassé par ``withTimeout(_:operation:)``.
public struct TimeoutError: Error, Equatable, Sendable {
    public init() {}
}

/// Exécute `operation` et lève ``TimeoutError`` si elle dépasse `duration`.
///
/// Contrairement à un `TaskGroup`, on n'attend PAS la fin d'une opération qui ignore
/// l'annulation (certaines bibliothèques réseau restent bloquées sur une réponse qui
/// ne vient jamais) : on rend la main tout de suite, l'opération est annulée et son
/// résultat éventuel ignoré. Charge à l'appelant de fermer la ressource concernée.
///
/// `pausedWhile` : tant qu'il renvoie `true`, le temps ne s'écoule pas (une question
/// posée à l'utilisateur ne doit pas consommer le délai).
public func withTimeout<T: Sendable>(
    _ duration: Duration,
    pausedWhile isPaused: @escaping @Sendable () -> Bool = { false },
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let gate = ResumeOnce<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)
            let work = Task {
                do {
                    gate.resume(with: .success(try await operation()))
                } catch {
                    gate.resume(with: .failure(error))
                }
            }
            gate.onFinish { work.cancel() }
            Task {
                let tick = Duration.milliseconds(50)
                var remaining = duration
                while remaining > .zero, !gate.isFinished {
                    let step = min(tick, remaining)
                    try? await Task.sleep(for: step)
                    if !isPaused() { remaining -= step }
                }
                gate.resume(with: .failure(TimeoutError()))
            }
        }
    } onCancel: {
        gate.resume(with: .failure(CancellationError()))
    }
}

/// Reprend une continuation une seule fois, quel que soit le premier arrivé.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var pending: Result<T, any Error>?
    private var finished = false
    private var finishHandlers: [@Sendable () -> Void] = []

    var isFinished: Bool { lock.withLock { finished } }

    func install(_ continuation: CheckedContinuation<T, any Error>) {
        let early: Result<T, any Error>? = lock.withLock {
            if let pending { return pending }
            self.continuation = continuation
            return nil
        }
        if let early { continuation.resume(with: early) }
    }

    func onFinish(_ handler: @escaping @Sendable () -> Void) {
        let runNow = lock.withLock {
            if finished { return true }
            finishHandlers.append(handler)
            return false
        }
        if runNow { handler() }
    }

    func resume(with result: Result<T, any Error>) {
        let (continuation, handlers): (CheckedContinuation<T, any Error>?, [@Sendable () -> Void]) = lock.withLock {
            guard !finished else { return (nil, []) }
            finished = true
            let handlers = finishHandlers
            finishHandlers = []
            guard let continuation = self.continuation else {
                pending = result  // annulé avant l'installation de la continuation
                return (nil, handlers)
            }
            self.continuation = nil
            return (continuation, handlers)
        }
        continuation?.resume(with: result)
        handlers.forEach { $0() }
    }
}
