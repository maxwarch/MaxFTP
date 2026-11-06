import Foundation
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

    public init(
        bookmarkRepository: any BookmarkRepository,
        pathBookmarkRepository: any PathBookmarkRepository,
        secretStore: any SecretStore,
        fileSystemFactory: any RemoteFileSystemFactory,
        sshConfig: @escaping @Sendable () -> SSHConfig = { SSHConfig(contents: "") },
        defaultIdentityFiles: @escaping @Sendable () -> [URL] = { [] },
        userPrompts: UserPromptTracker = UserPromptTracker()
    ) {
        self.userPrompts = userPrompts
        self.bookmarkRepository = bookmarkRepository
        self.pathBookmarkRepository = pathBookmarkRepository
        self.secretStore = secretStore
        self.fileSystemFactory = fileSystemFactory
        self.sshConfig = sshConfig
        self.defaultIdentityFiles = defaultIdentityFiles
    }
}
