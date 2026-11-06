import Foundation
import MaxFtpCore

/// Doublures thread-safe des stores persistants.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    public init(_ secrets: [String: String] = [:]) {
        self.secrets = secrets
    }

    public func secret(for account: String) throws -> String? {
        lock.withLock { secrets[account] }
    }

    public func setSecret(_ secret: String, for account: String) throws {
        lock.withLock { secrets[account] = secret }
    }

    public func removeSecret(for account: String) throws {
        lock.withLock { _ = secrets.removeValue(forKey: account) }
    }
}

public final class InMemoryBookmarkRepository: BookmarkRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ServerBookmark]

    public init(_ bookmarks: [ServerBookmark] = []) {
        self.stored = bookmarks
    }

    public var bookmarks: [ServerBookmark] { lock.withLock { stored } }

    public func loadBookmarks() throws -> [ServerBookmark] { bookmarks }

    public func saveBookmarks(_ bookmarks: [ServerBookmark]) throws {
        lock.withLock { stored = bookmarks }
    }
}

public final class InMemoryHostKeyStore: HostKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [KnownHostIdentifier: [String]] = [:]

    public init() {}

    public func trustedKeys(for host: KnownHostIdentifier) throws -> [String] {
        lock.withLock { keys[host] ?? [] }
    }

    public func trust(_ openSSHKey: String, for host: KnownHostIdentifier) throws {
        lock.withLock { keys[host, default: []].append(openSSHKey) }
    }
}

public final class InMemoryPathBookmarkRepository: PathBookmarkRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: [PathBookmark]]

    public init(_ bookmarks: [String: [PathBookmark]] = [:]) {
        self.stored = bookmarks
    }

    public var bookmarks: [String: [PathBookmark]] { lock.withLock { stored } }

    public func loadPathBookmarks() throws -> [String: [PathBookmark]] { bookmarks }

    public func savePathBookmarks(_ bookmarks: [String: [PathBookmark]]) throws {
        lock.withLock { stored = bookmarks }
    }
}
