import Foundation
import MaxFtpCore
import Observation

/// Tableau de bord d'un compte Cloudflare R2 : stockage, requêtes et budget du mois.
///
/// Le jeton d'API Cloudflare (distinct des clés S3) est rangé dans le trousseau,
/// une fois par compte, et partagé par tous les favoris de ce compte.
@MainActor
@Observable
public final class R2DashboardModel: Identifiable {
    public enum State: Equatable {
        case needsToken
        case loading
        case loaded(R2Bill)
        case failed(String)
    }

    public let accountID: String
    public private(set) var state: State = .needsToken
    public private(set) var lastUpdate: Date?

    private let provider: any R2UsageProvider
    private let secretStore: any SecretStore
    private let now: @Sendable () -> Date

    public init(
        accountID: String,
        provider: any R2UsageProvider,
        secretStore: any SecretStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.accountID = accountID
        self.provider = provider
        self.secretStore = secretStore
        self.now = now
    }

    private var secretAccount: String { R2Account.apiTokenSecretAccount(accountID: accountID) }

    public var hasToken: Bool { ((try? secretStore.secret(for: secretAccount)) ?? nil)?.isEmpty == false }

    public func refresh() async {
        guard let token = (try? secretStore.secret(for: secretAccount)) ?? nil, !token.isEmpty else {
            state = .needsToken
            return
        }
        state = .loading
        do {
            let usage = try await provider.usage(
                accountID: accountID, apiToken: token, period: R2Account.currentPeriod(at: now())
            )
            state = .loaded(R2Bill(usage: usage))
            lastUpdate = now()
        } catch is CancellationError {
            return
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public func saveToken(_ token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try secretStore.setSecret(trimmed, for: secretAccount)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        await refresh()
    }

    public func forgetToken() {
        try? secretStore.removeSecret(for: secretAccount)
        state = .needsToken
        lastUpdate = nil
    }
}

/// Niveau d'alerte d'un quota gratuit (affiché avec icône + libellé, jamais par la couleur seule).
public enum QuotaLevel: Equatable, Sendable {
    case comfortable, nearLimit, exceeded

    /// Alerte à partir de 80 % du quota.
    public init(ratio: Double) {
        self = ratio >= 1 ? .exceeded : ratio >= 0.8 ? .nearLimit : .comfortable
    }
}
