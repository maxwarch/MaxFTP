import Foundation
import SwiftUI
import MaxFtpCore

/// Tout ce dont la couche présentation a besoin, exprimé UNIQUEMENT en contrats du domaine.
///
/// Construit une seule fois par `AppComposition` (module MaxFtpApp) ; les tests
/// en fabriquent une version avec des doublures en mémoire.
public struct AppDependencies: Sendable {
    public var bookmarkRepository: any BookmarkRepository
    public var pathBookmarkRepository: any PathBookmarkRepository
    public var secretStore: any SecretStore
    public var fileSystemFactory: any RemoteFileSystemFactory
    /// Lecture paresseuse de `~/.ssh/config` (relue à chaque connexion rapide).
    public var sshConfig: @Sendable () -> SSHConfig
    /// Clés privées testées par défaut (`~/.ssh/id_ed25519`, `~/.ssh/id_rsa`…).
    public var defaultIdentityFiles: @Sendable () -> [URL]
    /// Questions en cours à l'utilisateur (suspendent les délais de connexion).
    public var userPrompts: UserPromptTracker
    /// Métriques Cloudflare R2 ; `nil` = pas de tableau de bord (tests).
    public var r2UsageProvider: (any R2UsageProvider)?
    /// Terminal intégré ; `nil` = indisponible (tests).
    public var terminalPanel: TerminalPanelBuilder?
    /// Fournisseur de mot de passe `sudo` pour la session ; `nil` en tests.
    public var sudoPasswords: (any SudoPasswordProvider)?

    public init(
        bookmarkRepository: any BookmarkRepository,
        pathBookmarkRepository: any PathBookmarkRepository,
        secretStore: any SecretStore,
        fileSystemFactory: any RemoteFileSystemFactory,
        sshConfig: @escaping @Sendable () -> SSHConfig = { SSHConfig(contents: "") },
        defaultIdentityFiles: @escaping @Sendable () -> [URL] = { [] },
        userPrompts: UserPromptTracker = UserPromptTracker(),
        r2UsageProvider: (any R2UsageProvider)? = nil,
        terminalPanel: TerminalPanelBuilder? = nil,
        sudoPasswords: (any SudoPasswordProvider)? = nil
    ) {
        self.terminalPanel = terminalPanel
        self.sudoPasswords = sudoPasswords
        self.userPrompts = userPrompts
        self.r2UsageProvider = r2UsageProvider
        self.bookmarkRepository = bookmarkRepository
        self.pathBookmarkRepository = pathBookmarkRepository
        self.secretStore = secretStore
        self.fileSystemFactory = fileSystemFactory
        self.sshConfig = sshConfig
        self.defaultIdentityFiles = defaultIdentityFiles
    }
}

/// Fabrique la vue du terminal intégré. L'émulateur (SwiftTerm) et le shell SSH sont
/// fournis par la composition root : MaxFtpFeatures n'en connaît que cette signature.
public struct TerminalPanelBuilder: Sendable {
    /// Configuration, dossier d'ouverture, rappel à la fin de chaque commande.
    public typealias Make = @MainActor @Sendable (
        ConnectionConfiguration, RemotePath, @escaping @MainActor @Sendable () -> Void
    ) -> AnyView

    let make: Make

    public init(_ make: @escaping Make) {
        self.make = make
    }
}
