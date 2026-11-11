import Foundation

/// Résultat de l'analyse du champ « Connexion rapide ».
///
/// Formats acceptés :
/// - `sftp://user:pass@host:2222/var/www` (schémas : sftp, ssh, ftp, ftps, ftpes, s3)
/// - `s3://ACCESS_KEY:SECRET@compte.r2.cloudflarestorage.com/bucket`
/// - `user@host`, `host:port`, `host` (SFTP par défaut)
/// - un alias de `~/.ssh/config`
public struct QuickConnectTarget: Equatable, Sendable {
    public var connectionProtocol: ConnectionProtocol
    public var host: String
    public var port: Int?
    public var username: String?
    public var password: String?
    public var path: RemotePath?

    public init(
        connectionProtocol: ConnectionProtocol,
        host: String,
        port: Int? = nil,
        username: String? = nil,
        password: String? = nil,
        path: RemotePath? = nil
    ) {
        self.connectionProtocol = connectionProtocol
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.path = path
    }

    public init?(parsing input: String, defaultProtocol: ConnectionProtocol = .sftp) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let hasScheme = trimmed.contains("://")
        guard let components = URLComponents(string: hasScheme ? trimmed : "placeholder://" + trimmed),
              let host = components.host, !host.isEmpty else { return nil }

        let proto: ConnectionProtocol
        if hasScheme {
            guard let scheme = components.scheme, let parsed = ConnectionProtocol(urlScheme: scheme) else { return nil }
            proto = parsed
        } else {
            proto = defaultProtocol
        }

        self.init(
            connectionProtocol: proto,
            host: host,
            port: components.port,
            username: components.user?.removingPercentEncoding,
            password: components.password?.removingPercentEncoding,
            path: components.path.isEmpty ? nil : RemotePath(components.path.removingPercentEncoding ?? components.path)
        )
    }
}
