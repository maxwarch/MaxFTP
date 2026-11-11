import Foundation
import MaxFtpCore
import UniformTypeIdentifiers

/// Adaptateur pour le stockage objet compatible S3 (Cloudflare R2, AWS S3, MinIO…).
///
/// HTTP sans état : `connect()` ne fait que vérifier les identifiants, et plusieurs
/// requêtes peuvent être en vol en même temps. Les dossiers sont simulés par les
/// préfixes de clés (voir ``S3Location`` et l'ADR 0008).
public actor S3FileSystem: RemoteFileSystem {
    public nonisolated let configuration: ConnectionConfiguration
    private let endpoint: S3Endpoint
    private let session: URLSession
    private var isConnected = false

    public init(configuration: ConnectionConfiguration) {
        self.configuration = configuration
        self.endpoint = S3Endpoint(host: configuration.host, port: configuration.port, region: configuration.s3Region)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: sessionConfiguration)
    }

    // MARK: Connexion

    public func connect() async throws {
        if isConnected { return }
        // Un jeton R2 limité à un bucket n'a pas le droit de lister les buckets :
        // on vérifie alors l'accès au bucket du dossier initial.
        let probe: S3Request
        if let bucket = configuration.initialPath.flatMap({ S3Location($0).bucket }) {
            probe = S3Request(method: "GET", bucket: bucket, query: ["list-type": "2", "max-keys": "1"])
        } else {
            probe = S3Request(method: "GET")
        }
        _ = try await send(probe)
        isConnected = true
    }

    public func disconnect() async {
        isConnected = false
    }

    // MARK: Navigation

    public func homeDirectory() async throws -> RemotePath { .root }

    public func contentsOfDirectory(at path: RemotePath) async throws -> [RemoteItem] {
        let location = S3Location(path)
        guard let bucket = location.bucket else {
            let (data, _) = try await send(S3Request(method: "GET"))
            guard let buckets = S3Response.buckets(data) else { throw Self.unexpected(data) }
            return buckets.map {
                RemoteItem(path: RemotePath(components: [$0.name]), kind: .directory, modificationDate: $0.creationDate)
            }
        }

        let prefix = location.directoryPrefix
        var items: [RemoteItem] = []
        try await forEachPage(bucket: bucket, prefix: prefix, delimiter: "/") { page in
            for common in page.commonPrefixes {
                let name = String(common.dropFirst(prefix.count).dropLast())
                guard Self.isListable(name) else { continue }
                items.append(RemoteItem(path: RemotePath(components: path.components + [name]), kind: .directory))
            }
            for object in page.objects {
                let name = String(object.key.dropFirst(prefix.count))
                // `name` vide : marqueur du dossier lui-même (`dossier/`).
                guard Self.isListable(name) else { continue }
                items.append(RemoteItem(
                    path: RemotePath(components: path.components + [name]),
                    kind: .file,
                    size: object.size,
                    modificationDate: object.lastModified
                ))
            }
        }
        return items
    }

    // MARK: Opérations sur fichiers

    public func createDirectory(at path: RemotePath) async throws {
        switch S3Location(path) {
        case .root:
            throw RemoteError.invalidPath(path.string)
        case .bucket(let bucket):
            let body = S3RequestBody.createBucket(region: endpoint.region)
            _ = try await send(S3Request(method: "PUT", bucket: bucket), body: body)
        case .object(let bucket, let key):
            // Objet vide `dossier/` : rend le dossier visible tant qu'il est vide.
            _ = try await send(S3Request(method: "PUT", bucket: bucket, key: key + "/"), body: Data())
        }
    }

    public func removeFile(at path: RemotePath) async throws {
        guard case .object(let bucket, let key) = S3Location(path) else { throw RemoteError.invalidPath(path.string) }
        _ = try await send(S3Request(method: "DELETE", bucket: bucket, key: key))
    }

    public func removeDirectory(at path: RemotePath) async throws {
        switch S3Location(path) {
        case .root:
            throw RemoteError.invalidPath(path.string)
        case .bucket(let bucket):
            _ = try await send(S3Request(method: "DELETE", bucket: bucket))
        case .object(let bucket, let key):
            // Supprimer un marqueur absent n'est pas une erreur en S3 (204).
            _ = try await send(S3Request(method: "DELETE", bucket: bucket, key: key + "/"))
        }
    }

    /// S3 n'a pas de renommage : copie puis suppression, objet par objet pour un dossier.
    public func moveItem(at source: RemotePath, to destination: RemotePath) async throws {
        guard case .object(let sourceBucket, let sourceKey) = S3Location(source) else {
            throw RemoteError.unsupportedOperation("un bucket ne peut pas être renommé.")
        }
        guard case .object(let destinationBucket, let destinationKey) = S3Location(destination) else {
            throw RemoteError.invalidPath(destination.string)
        }

        if try await objectExists(bucket: sourceBucket, key: sourceKey) {
            try await copyObject(from: (sourceBucket, sourceKey), to: (destinationBucket, destinationKey))
            _ = try await send(S3Request(method: "DELETE", bucket: sourceBucket, key: sourceKey))
            return
        }

        let sourcePrefix = sourceKey + "/"
        var keys: [String] = []
        try await forEachPage(bucket: sourceBucket, prefix: sourcePrefix, delimiter: nil) { page in
            keys += page.objects.map(\.key)
        }
        guard !keys.isEmpty else {
            throw RemoteError.serverError(code: 404, message: "\(source.string) est introuvable.")
        }
        for key in keys {
            try Task.checkCancellation()
            let target = destinationKey + "/" + key.dropFirst(sourcePrefix.count)
            try await copyObject(from: (sourceBucket, key), to: (destinationBucket, target))
        }
        for key in keys {
            _ = try await send(S3Request(method: "DELETE", bucket: sourceBucket, key: key))
        }
    }

    public func setPermissions(_ permissions: POSIXPermissions, at path: RemotePath) async throws {
        throw RemoteError.unsupportedOperation("le stockage S3 n'a pas de permissions POSIX.")
    }

    // MARK: Transferts

    public func download(_ path: RemotePath, to localURL: URL, progress: @escaping TransferProgressHandler) async throws {
        guard case .object(let bucket, let key) = S3Location(path) else { throw RemoteError.invalidPath(path.string) }
        let request = try signed(S3Request(method: "GET", bucket: bucket, key: key))
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw Self.translate(error)
        }

        guard Self.isSuccess(response) else {
            var body = Data()
            for try await byte in bytes.prefix(64 * 1024) { body.append(byte) }
            throw Self.translate(status: Self.status(response), body: body)
        }

        let output = try LocalFileIO.createFileForWriting(at: localURL)
        defer { try? output.close() }
        var buffer = Data()
        buffer.reserveCapacity(LocalFileIO.chunkSize)
        var written: Int64 = 0
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= LocalFileIO.chunkSize {
                    try Task.checkCancellation()
                    try output.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    progress(written)
                }
            }
        } catch {
            throw Self.translate(error)
        }
        try output.write(contentsOf: buffer)
        progress(written + Int64(buffer.count))
    }

    public func upload(_ localURL: URL, to path: RemotePath, progress: @escaping TransferProgressHandler) async throws {
        guard case .object(let bucket, let key) = S3Location(path) else { throw RemoteError.invalidPath(path.string) }
        let size: Int64
        do {
            size = Int64(try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        } catch {
            throw RemoteError.localFileError(error.localizedDescription)
        }
        let contentType = UTType(filenameExtension: localURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"

        guard size > S3Multipart.threshold else {
            let request = try signed(S3Request(method: "PUT", bucket: bucket, key: key, headers: ["content-type": contentType]))
            let delegate = UploadProgress(offset: 0, progress: progress)
            let (data, response) = try await transfer {
                try await $0.upload(for: request, fromFile: localURL, delegate: delegate)
            }
            try Self.check(response, data)
            progress(size)
            return
        }
        try await multipartUpload(localURL, size: size, bucket: bucket, key: key, contentType: contentType, progress: progress)
    }

    private func multipartUpload(
        _ localURL: URL, size: Int64, bucket: String, key: String, contentType: String,
        progress: @escaping TransferProgressHandler
    ) async throws {
        let (created, _) = try await send(S3Request(
            method: "POST", bucket: bucket, key: key, query: ["uploads": ""], headers: ["content-type": contentType]
        ))
        guard let uploadID = S3Response.uploadID(created) else { throw Self.unexpected(created) }

        do {
            let input = try LocalFileIO.openForReading(localURL)
            defer { try? input.close() }
            let partSize = S3Multipart.partSize(for: size)
            var etags: [String] = []
            var offset: Int64 = 0
            while offset < size {
                try Task.checkCancellation()
                let part = try input.read(upToCount: Int(partSize)) ?? Data()
                guard !part.isEmpty else { break }
                let request = try signed(S3Request(
                    method: "PUT", bucket: bucket, key: key,
                    query: ["partNumber": String(etags.count + 1), "uploadId": uploadID]
                ))
                let delegate = UploadProgress(offset: offset, progress: progress)
                let (data, response) = try await transfer {
                    try await $0.upload(for: request, from: part, delegate: delegate)
                }
                try Self.check(response, data)
                guard let etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag") else {
                    throw RemoteError.protocolViolation("ETag manquant pour la partie \(etags.count + 1).")
                }
                etags.append(etag)
                offset += Int64(part.count)
                progress(offset)
            }
            _ = try await send(
                S3Request(method: "POST", bucket: bucket, key: key, query: ["uploadId": uploadID]),
                body: S3RequestBody.completeMultipartUpload(etags: etags)
            )
        } catch {
            // Sans abandon explicite, les parties déjà envoyées resteraient facturées.
            if let abort = try? signed(S3Request(method: "DELETE", bucket: bucket, key: key, query: ["uploadId": uploadID])) {
                _ = try? await session.data(for: abort)
            }
            throw error
        }
    }

    // MARK: Requêtes

    private var credentials: S3Credentials {
        get throws {
            guard case .password(let secret) = configuration.credential,
                  !configuration.username.isEmpty, !secret.isEmpty else {
                throw RemoteError.authenticationFailed("renseignez l'Access Key ID et la Secret Access Key.")
            }
            return S3Credentials(accessKeyID: configuration.username, secretAccessKey: secret)
        }
    }

    private func signed(_ request: S3Request) throws -> URLRequest {
        guard let urlRequest = request.signed(for: endpoint, credentials: try credentials) else {
            throw RemoteError.invalidPath(request.canonicalURI)
        }
        return urlRequest
    }

    /// Envoie la requête et lève une ``RemoteError`` si le statut n'est pas 2xx
    /// ou si le corps contient une erreur S3 (certaines opérations répondent 200 en cas d'échec).
    @discardableResult
    private func send(_ request: S3Request, body: Data? = nil) async throws -> (Data, URLResponse) {
        var urlRequest = try signed(request)
        urlRequest.httpBody = body
        let prepared = urlRequest
        let (data, response) = try await transfer { try await $0.data(for: prepared) }
        try Self.check(response, data)
        return (data, response)
    }

    /// Exécute un appel `URLSession` en traduisant ses erreurs (annulation comprise).
    private func transfer(
        _ operation: @Sendable (URLSession) async throws -> (Data, URLResponse)
    ) async throws -> (Data, URLResponse) {
        do {
            return try await operation(session)
        } catch {
            throw Self.translate(error)
        }
    }

    private func objectExists(bucket: String, key: String) async throws -> Bool {
        let request = try signed(S3Request(method: "HEAD", bucket: bucket, key: key))
        let (data, response) = try await transfer { try await $0.data(for: request) }
        if Self.status(response) == 404 { return false }
        try Self.check(response, data)
        return true
    }

    private func copyObject(from source: (bucket: String, key: String), to destination: (bucket: String, key: String)) async throws {
        let copySource = "/" + S3Encoding.encode(source.bucket, keepingSlashes: false)
            + "/" + S3Encoding.encode(source.key, keepingSlashes: true)
        _ = try await send(S3Request(
            method: "PUT", bucket: destination.bucket, key: destination.key,
            headers: ["x-amz-copy-source": copySource]
        ))
    }

    /// ListObjectsV2, page par page (1 000 clés au plus par réponse).
    private func forEachPage(
        bucket: String, prefix: String, delimiter: String?,
        _ body: (S3Response.ListPage) throws -> Void
    ) async throws {
        var token: String?
        repeat {
            try Task.checkCancellation()
            var query = ["list-type": "2", "prefix": prefix]
            if let delimiter { query["delimiter"] = delimiter }
            if let token { query["continuation-token"] = token }
            let (data, _) = try await send(S3Request(method: "GET", bucket: bucket, query: query))
            guard let page = S3Response.listPage(data) else { throw Self.unexpected(data) }
            try body(page)
            token = page.nextContinuationToken
        } while token != nil
    }

    // MARK: Traduction des erreurs

    /// Les noms `.`/`..` ou vides (clés `a//b`) ne sont pas représentables par ``RemotePath``.
    private static func isListable(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
    }

    private static func status(_ response: URLResponse) -> Int {
        (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private static func isSuccess(_ response: URLResponse) -> Bool {
        (200..<300).contains(status(response))
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        if !isSuccess(response) || S3Response.error(data) != nil {
            throw translate(status: status(response), body: data)
        }
    }

    static func translate(status: Int, body: Data) -> RemoteError {
        let error = S3Response.error(body)
        let message = error.map { $0.message.isEmpty ? $0.code : "\($0.message) (\($0.code))" }
            ?? HTTPURLResponse.localizedString(forStatusCode: status)
        switch (status, error?.code) {
        case (401, _), (_, "InvalidAccessKeyId"), (_, "SignatureDoesNotMatch"), (_, "Unauthorized"):
            return .authenticationFailed(message)
        case (403, _):
            return .serverError(code: 403, message: "accès refusé — vérifiez les droits du jeton. \(message)")
        default:
            return .serverError(code: status, message: message)
        }
    }

    private static func translate(_ error: any Error) -> any Error {
        if error is RemoteError || error is CancellationError { return error }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return CancellationError() }
            return RemoteError.connectionFailed(urlError.localizedDescription)
        }
        return RemoteError.connectionFailed(String(describing: error))
    }

    private static func unexpected(_ data: Data) -> RemoteError {
        .protocolViolation(String(decoding: data.prefix(200), as: UTF8.self))
    }
}

/// Remonte la progression d'un envoi HTTP (délégué propre à la tâche).
private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let offset: Int64
    let progress: TransferProgressHandler

    init(offset: Int64, progress: @escaping TransferProgressHandler) {
        self.offset = offset
        self.progress = progress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress(offset + totalBytesSent)
    }
}
