import Foundation
import MaxFtpCore
import Observation

/// État partagé par toutes les fenêtres : favoris, signets et file de transferts.
///
/// Injecté dans SwiftUI via `.environment(appEnvironment)`. L'état propre à une
/// fenêtre (session, dossier courant…) vit dans ``BrowserModel``.
@MainActor
@Observable
public final class AppEnvironment {
    public let dependencies: AppDependencies
    public let bookmarks: BookmarksModel
    public let pathBookmarks: PathBookmarksModel
    public let transfers: TransferQueue

    public init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        self.bookmarks = BookmarksModel(
            repository: dependencies.bookmarkRepository,
            secretStore: dependencies.secretStore
        )
        self.pathBookmarks = PathBookmarksModel(repository: dependencies.pathBookmarkRepository)
        self.transfers = TransferQueue(factory: dependencies.fileSystemFactory)
    }

    /// Fabrique le modèle d'une nouvelle fenêtre.
    public func makeBrowserModel() -> BrowserModel {
        BrowserModel(factory: dependencies.fileSystemFactory, transfers: transfers, userPrompts: dependencies.userPrompts)
    }

    public var quickConnectResolver: QuickConnectResolver {
        QuickConnectResolver(
            sshConfig: dependencies.sshConfig(),
            defaultIdentityFiles: dependencies.defaultIdentityFiles()
        )
    }
}
