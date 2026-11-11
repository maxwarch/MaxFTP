import Foundation

/// Arbre XML minimal : les réponses S3 sont petites et peu profondes.
struct S3XMLNode: Equatable, Sendable {
    var name: String
    var text = ""
    var children: [S3XMLNode] = []

    func child(_ name: String) -> S3XMLNode? { children.first { $0.name == name } }
    func children(_ name: String) -> [S3XMLNode] { children.filter { $0.name == name } }
    func value(_ name: String) -> String? { child(name)?.text }

    static func parse(_ data: Data) -> S3XMLNode? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return builder.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var stack: [S3XMLNode] = []
        var root: S3XMLNode?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            stack.append(S3XMLNode(name: name))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard let element = stack.popLast() else { return }
            if stack.isEmpty {
                root = element
            } else {
                stack[stack.count - 1].children.append(element)
            }
        }
    }
}

/// Décodage des réponses S3 utilisées par l'adaptateur. Fonctions pures.
enum S3Response {
    struct Bucket: Equatable {
        let name: String
        let creationDate: Date?
    }

    struct Object: Equatable {
        let key: String
        let size: Int64?
        let lastModified: Date?
    }

    struct ListPage: Equatable {
        var commonPrefixes: [String]
        var objects: [Object]
        var nextContinuationToken: String?
    }

    struct ServiceError: Equatable {
        let code: String
        let message: String
    }

    static func buckets(_ data: Data) -> [Bucket]? {
        guard let root = S3XMLNode.parse(data), root.name == "ListAllMyBucketsResult" else { return nil }
        return root.child("Buckets")?.children("Bucket").compactMap { bucket in
            bucket.value("Name").map { Bucket(name: $0, creationDate: bucket.value("CreationDate").flatMap(date)) }
        } ?? []
    }

    static func listPage(_ data: Data) -> ListPage? {
        guard let root = S3XMLNode.parse(data), root.name == "ListBucketResult" else { return nil }
        let truncated = root.value("IsTruncated") == "true"
        return ListPage(
            commonPrefixes: root.children("CommonPrefixes").compactMap { $0.value("Prefix") },
            objects: root.children("Contents").compactMap { object in
                object.value("Key").map {
                    Object(key: $0, size: object.value("Size").flatMap { Int64($0) }, lastModified: object.value("LastModified").flatMap(date))
                }
            },
            nextContinuationToken: truncated ? root.value("NextContinuationToken") : nil
        )
    }

    /// Erreur S3 (`<Error><Code>…`), y compris dans une réponse 200 (CopyObject, CompleteMultipartUpload).
    static func error(_ data: Data) -> ServiceError? {
        guard let root = S3XMLNode.parse(data), root.name == "Error" else { return nil }
        return ServiceError(code: root.value("Code") ?? "", message: root.value("Message") ?? "")
    }

    static func uploadID(_ data: Data) -> String? {
        guard let root = S3XMLNode.parse(data), root.name == "InitiateMultipartUploadResult" else { return nil }
        return root.value("UploadId")
    }

    static func date(_ string: String) -> Date? {
        (try? Date(string, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
            ?? (try? Date(string, strategy: .iso8601))
    }
}

enum S3RequestBody {
    static func completeMultipartUpload(etags: [String]) -> Data {
        let parts = etags.enumerated().map { index, etag in
            "<Part><PartNumber>\(index + 1)</PartNumber><ETag>\(escape(etag))</ETag></Part>"
        }
        return Data("<CompleteMultipartUpload>\(parts.joined())</CompleteMultipartUpload>".utf8)
    }

    /// Hors `us-east-1` (et `auto` pour R2), AWS exige la région dans le corps de CreateBucket.
    static func createBucket(region: String) -> Data? {
        guard region != "auto", region != "us-east-1" else { return nil }
        return Data(
            "<CreateBucketConfiguration><LocationConstraint>\(escape(region))</LocationConstraint></CreateBucketConfiguration>".utf8
        )
    }

    private static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Découpage d'un upload multipart.
enum S3Multipart {
    /// En dessous, un simple PUT ; au-delà, un upload en plusieurs parties (reprise par partie, pas de limite à 5 Go).
    static let threshold: Int64 = 100 * 1024 * 1024
    static let minimumPartSize: Int64 = 16 * 1024 * 1024
    static let maximumPartCount: Int64 = 10_000

    /// Taille fixe des parties (R2 exige des parties de même taille, la dernière exceptée),
    /// arrondie au Mio, assez grande pour rester sous la limite de 10 000 parties.
    static func partSize(for fileSize: Int64) -> Int64 {
        let mebibyte: Int64 = 1024 * 1024
        let needed = (fileSize + maximumPartCount - 1) / maximumPartCount
        let rounded = (needed + mebibyte - 1) / mebibyte * mebibyte
        return max(minimumPartSize, rounded)
    }
}
