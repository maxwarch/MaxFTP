import Foundation
import MaxFtpCore

/// Métriques R2 via l'API GraphQL d'analytique de Cloudflare.
///
/// Les clés S3 n'y donnent pas accès : il faut un jeton d'API Cloudflare avec la
/// permission « Account Analytics : Read ». Voir l'ADR 0009.
public struct CloudflareR2Analytics: R2UsageProvider {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let endpoint = URL(string: "https://api.cloudflare.com/client/v4/graphql")!

    private let transport: Transport

    public init(transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.transport = transport
    }

    public func usage(accountID: String, apiToken: String, period: DateInterval) async throws -> R2Usage {
        let request = try Self.request(accountID: accountID, apiToken: apiToken, period: period)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw RemoteError.connectionFailed(error.localizedDescription)
        }
        return try Self.parse(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0, period: period)
    }

    // MARK: Requête

    /// Stockage : relevés par bucket, les plus récents d'abord (limite de 10 000 lignes).
    /// Opérations : total des requêtes par type d'action sur la période.
    static let query = """
    query R2Usage($accountTag: string!, $start: Time!, $end: Time!) {
      viewer {
        accounts(filter: { accountTag: $accountTag }) {
          storage: r2StorageAdaptiveGroups(
            limit: 10000
            filter: { datetime_geq: $start, datetime_leq: $end }
            orderBy: [datetime_DESC]
          ) {
            max { objectCount payloadSize metadataSize }
            dimensions { bucketName datetime }
          }
          operations: r2OperationsAdaptiveGroups(
            limit: 10000
            filter: { datetime_geq: $start, datetime_leq: $end }
          ) {
            sum { requests }
            dimensions { actionType }
          }
        }
      }
    }
    """

    static func request(accountID: String, apiToken: String, period: DateInterval) throws -> URLRequest {
        let format = Date.ISO8601FormatStyle()
        let body: [String: Any] = [
            "query": query,
            "variables": [
                "accountTag": accountID,
                "start": period.start.formatted(format),
                "end": period.end.formatted(format),
            ],
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30
        return request
    }

    // MARK: Réponse

    private struct Response: Decodable {
        struct Message: Decodable { let message: String }
        struct DataBlock: Decodable { let viewer: Viewer }
        struct Viewer: Decodable { let accounts: [Account] }
        struct Account: Decodable {
            let storage: [StorageGroup]
            let operations: [OperationGroup]
        }
        struct StorageGroup: Decodable {
            struct Max: Decodable {
                let objectCount: Int64?
                let payloadSize: Int64?
                let metadataSize: Int64?
            }
            struct Dimensions: Decodable {
                let bucketName: String
                let datetime: String
            }
            let max: Max
            let dimensions: Dimensions
        }
        struct OperationGroup: Decodable {
            struct Sum: Decodable { let requests: Int64 }
            struct Dimensions: Decodable { let actionType: String }
            let sum: Sum
            let dimensions: Dimensions
        }

        let data: DataBlock?
        let errors: [Message]?
    }

    static func parse(_ data: Data, status: Int, period: DateInterval) throws -> R2Usage {
        let response = try? JSONDecoder().decode(Response.self, from: data)
        let message = response?.errors?.map(\.message).joined(separator: " ")

        if status == 401 || status == 403
            || (message?.localizedCaseInsensitiveContains("not authorized") ?? false)
            || (message?.localizedCaseInsensitiveContains("authentication") ?? false) {
            throw RemoteError.authenticationFailed(
                "jeton d'API Cloudflare refusé — il doit avoir la permission « Account Analytics : Read »."
            )
        }
        if let message, !message.isEmpty {
            throw RemoteError.serverError(code: status, message: message)
        }
        guard (200..<300).contains(status), let response else {
            throw RemoteError.protocolViolation(String(decoding: data.prefix(200), as: UTF8.self))
        }
        guard let account = response.data?.viewer.accounts.first else {
            throw RemoteError.serverError(code: status, message: "compte Cloudflare introuvable pour ce jeton.")
        }

        let samples = account.storage.compactMap { group -> R2Usage.StorageSample? in
            guard let date = S3Response.date(group.dimensions.datetime) else { return nil }
            return R2Usage.StorageSample(
                bucketName: group.dimensions.bucketName,
                date: date,
                payloadBytes: group.max.payloadSize ?? 0,
                metadataBytes: group.max.metadataSize ?? 0,
                objectCount: group.max.objectCount ?? 0
            )
        }
        var requests: [String: Int64] = [:]
        for group in account.operations {
            requests[group.dimensions.actionType, default: 0] += group.sum.requests
        }
        return R2Usage(period: period, storageSamples: samples, requestsByAction: requests)
    }
}
