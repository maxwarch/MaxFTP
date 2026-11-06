import Foundation

/// Historique « Précédent / Suivant » d'une session, comme dans un navigateur web.
///
/// Value type pur : le modèle de vue ne valide un déplacement qu'une fois le dossier
/// chargé avec succès, si bien qu'un échec réseau ne corrompt jamais l'historique.
public struct NavigationHistory: Equatable, Sendable {
    public private(set) var backStack: [RemotePath] = []
    public private(set) var forwardStack: [RemotePath] = []
    public let limit: Int

    public init(limit: Int = 100) {
        self.limit = max(1, limit)
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    /// Destination de « Précédent » (sans la consommer).
    public var backTarget: RemotePath? { backStack.last }
    /// Destination de « Suivant » (sans la consommer).
    public var forwardTarget: RemotePath? { forwardStack.last }

    /// Nouvelle navigation : `current` rejoint la pile arrière et la pile avant est vidée.
    /// Recharger le même dossier ne crée pas d'entrée.
    public mutating func visit(from current: RemotePath, to destination: RemotePath) {
        guard current != destination else { return }
        backStack.append(current)
        if backStack.count > limit { backStack.removeFirst(backStack.count - limit) }
        forwardStack = []
    }

    /// Valide un retour arrière effectué depuis `current`.
    public mutating func didGoBack(from current: RemotePath) {
        guard backStack.popLast() != nil else { return }
        forwardStack.append(current)
    }

    /// Valide une avancée effectuée depuis `current`.
    public mutating func didGoForward(from current: RemotePath) {
        guard forwardStack.popLast() != nil else { return }
        backStack.append(current)
    }

    public mutating func reset() {
        backStack = []
        forwardStack = []
    }
}
