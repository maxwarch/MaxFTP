import CryptoKit
import Foundation

/// Point d'accès S3 (ex. `<compte>.r2.cloudflarestorage.com`), toujours en HTTPS.
struct S3Endpoint: Equatable, Sendable {
    let host: String
    let port: Int
    let region: String

    /// Accepte aussi une URL collée telle quelle (`https://…/`) : schéma et chemin sont ignorés.
    init(host: String, port: Int, region: String) {
        var cleaned = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = cleaned.range(of: "://") { cleaned = String(cleaned[range.upperBound...]) }
        if let slash = cleaned.firstIndex(of: "/") { cleaned = String(cleaned[..<slash]) }
        self.host = cleaned.lowercased()
        self.port = port
        let trimmedRegion = region.trimmingCharacters(in: .whitespaces)
        self.region = trimmedRegion.isEmpty ? "auto" : trimmedRegion
    }

    /// Valeur de l'en-tête `Host` (le port n'y figure que s'il n'est pas 443).
    var authority: String { port == 443 ? host : "\(host):\(port)" }
}

struct S3Credentials: Sendable {
    let accessKeyID: String
    let secretAccessKey: String
}

/// Requête S3 décrite indépendamment de `URLRequest`, pour que l'URL envoyée et
/// la requête canonique signée soient construites à partir des MÊMES chaînes encodées.
struct S3Request: Sendable {
    var method: String
    var bucket: String?
    var key: String?
    var query: [String: String] = [:]
    var headers: [String: String] = [:]

    /// Corps non haché : accepté par S3 et R2 en HTTPS, évite de lire deux fois les gros fichiers.
    static let unsignedPayload = "UNSIGNED-PAYLOAD"

    /// Chemin « path-style » : `/bucket/clé`, chaque segment encodé une seule fois.
    var canonicalURI: String {
        var path = "/"
        if let bucket {
            path += S3Encoding.encode(bucket, keepingSlashes: false)
            if let key { path += "/" + S3Encoding.encode(key, keepingSlashes: true) }
        }
        return path
    }

    var canonicalQuery: String {
        let pairs: [(name: String, value: String)] = query.map {
            (S3Encoding.encode($0.key, keepingSlashes: false), S3Encoding.encode($0.value, keepingSlashes: false))
        }
        return pairs
            .sorted { $0.name == $1.name ? $0.value < $1.value : $0.name < $1.name }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "&")
    }

    func url(for endpoint: S3Endpoint) -> URL? {
        let query = canonicalQuery
        return URL(string: "https://\(endpoint.authority)\(canonicalURI)" + (query.isEmpty ? "" : "?\(query)"))
    }

    /// `URLRequest` signée (AWS Signature Version 4).
    func signed(
        for endpoint: S3Endpoint,
        credentials: S3Credentials,
        payloadHash: String = S3Request.unsignedPayload,
        date: Date = Date()
    ) -> URLRequest? {
        guard let url = url(for: endpoint) else { return nil }
        let signature = S3Signer.sign(
            self, endpoint: endpoint, credentials: credentials, payloadHash: payloadHash, date: date
        )
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in signature.headers where name != "host" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}

/// Signature AWS Signature Version 4 pour le service `s3`. Logique pure.
enum S3Signer {
    struct Result: Equatable {
        /// En-têtes à envoyer (noms en minuscules), `authorization` compris.
        let headers: [String: String]
        let canonicalRequest: String
        let stringToSign: String
        let signature: String
    }

    static func sign(
        _ request: S3Request,
        endpoint: S3Endpoint,
        credentials: S3Credentials,
        payloadHash: String,
        date: Date
    ) -> Result {
        let (amzDate, day) = timestamps(for: date)

        var headers: [String: String] = [:]
        for (name, value) in request.headers { headers[name.lowercased()] = value }
        headers["host"] = endpoint.authority
        headers["x-amz-date"] = amzDate
        headers["x-amz-content-sha256"] = payloadHash

        let names = headers.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(normalizedHeaderValue(headers[$0]!))\n" }.joined()
        let signedHeaders = names.joined(separator: ";")

        let canonicalRequest = [
            request.method,
            request.canonicalURI,
            request.canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(day)/\(endpoint.region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
        for part in [day, endpoint.region, "s3", "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))

        headers["authorization"] = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return Result(headers: headers, canonicalRequest: canonicalRequest, stringToSign: stringToSign, signature: signature)
    }

    /// `20130524T000000Z` et `20130524`, en UTC.
    static func timestamps(for date: Date) -> (amzDate: String, day: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
        return (day + String(format: "T%02d%02d%02dZ", c.hour!, c.minute!, c.second!), day)
    }

    private static func normalizedHeaderValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum S3Encoding {
    private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~".utf8)

    /// Encodage URI exigé par SigV4 : tout sauf les caractères non réservés (RFC 3986), en `%XX` majuscules.
    static func encode(_ string: String, keepingSlashes: Bool) -> String {
        var result = ""
        for byte in string.utf8 {
            if unreserved.contains(byte) || (keepingSlashes && byte == UInt8(ascii: "/")) {
                result.append(Character(UnicodeScalar(byte)))
            } else {
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }
}
