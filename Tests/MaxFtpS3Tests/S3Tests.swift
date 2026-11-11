import Foundation
import MaxFtpCore
@testable import MaxFtpS3
import Testing

@Suite("Signature SigV4")
struct S3SignerTests {
    // Exemples officiels de la documentation AWS (« Signature Calculations for the
    // Authorization Header »), en style « virtual host » : le bucket est dans l'hôte.
    let endpoint = S3Endpoint(host: "examplebucket.s3.amazonaws.com", port: 443, region: "us-east-1")
    let credentials = S3Credentials(
        accessKeyID: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    )
    let date = Date(timeIntervalSince1970: 1_369_353_600)  // 24/05/2013 00:00:00 UTC
    let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    @Test func getObjectWithRange() {
        // `bucket` porte ici le chemin `/test.txt` de l'exemple.
        let request = S3Request(method: "GET", bucket: "test.txt", headers: ["Range": "bytes=0-9"])
        let result = S3Signer.sign(request, endpoint: endpoint, credentials: credentials, payloadHash: emptyHash, date: date)
        #expect(result.signature == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
        #expect(result.headers["authorization"]?.contains("SignedHeaders=host;range;x-amz-content-sha256;x-amz-date") == true)
    }

    @Test func listObjectsWithQuery() {
        let request = S3Request(method: "GET", query: ["prefix": "J", "max-keys": "2"])
        let result = S3Signer.sign(request, endpoint: endpoint, credentials: credentials, payloadHash: emptyHash, date: date)
        #expect(result.canonicalRequest.split(separator: "\n", omittingEmptySubsequences: false)[2] == "max-keys=2&prefix=J")
        #expect(result.signature == "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")
    }

    @Test func subresourceWithoutValue() {
        let request = S3Request(method: "GET", query: ["lifecycle": ""])
        let result = S3Signer.sign(request, endpoint: endpoint, credentials: credentials, payloadHash: emptyHash, date: date)
        #expect(result.signature == "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543")
    }

    @Test func urlAndCanonicalPathShareEncoding() {
        let r2 = S3Endpoint(host: "https://ACCOUNT.r2.cloudflarestorage.com/", port: 443, region: "")
        #expect(r2.host == "account.r2.cloudflarestorage.com")
        #expect(r2.region == "auto")

        let request = S3Request(method: "GET", bucket: "photos", key: "été 2024/a+b.jpg", query: ["prefix": "a b/"])
        #expect(request.canonicalURI == "/photos/%C3%A9t%C3%A9%202024/a%2Bb.jpg")
        #expect(request.url(for: r2)?.absoluteString
            == "https://account.r2.cloudflarestorage.com/photos/%C3%A9t%C3%A9%202024/a%2Bb.jpg?prefix=a%20b%2F")
    }

    @Test func nonDefaultPortIsSigned() {
        let local = S3Endpoint(host: "localhost", port: 9000, region: "us-east-1")
        let result = S3Signer.sign(S3Request(method: "GET"), endpoint: local, credentials: credentials, payloadHash: emptyHash, date: date)
        #expect(result.canonicalRequest.contains("host:localhost:9000\n"))
    }
}

@Suite("Chemins S3")
struct S3LocationTests {
    @Test func mapsPathToBucketAndKey() {
        #expect(S3Location(.root) == .root)
        #expect(S3Location("/photos") == .bucket("photos"))
        #expect(S3Location("/photos/2024/a.jpg") == .object(bucket: "photos", key: "2024/a.jpg"))
        #expect(S3Location("/photos/2024").directoryPrefix == "2024/")
        #expect(S3Location("/photos").directoryPrefix == "")
    }
}

@Suite("Réponses S3")
struct S3ResponseTests {
    @Test func listBuckets() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Owner><ID>x</ID></Owner>
          <Buckets>
            <Bucket><Name>photos</Name><CreationDate>2024-03-01T10:20:30.000Z</CreationDate></Bucket>
            <Bucket><Name>sauvegardes</Name><CreationDate>2024-03-02T00:00:00Z</CreationDate></Bucket>
          </Buckets>
        </ListAllMyBucketsResult>
        """
        let buckets = try #require(S3Response.buckets(Data(xml.utf8)))
        #expect(buckets.map(\.name) == ["photos", "sauvegardes"])
        #expect(buckets[0].creationDate == Date(timeIntervalSince1970: 1_709_288_430))
        #expect(buckets[1].creationDate != nil)
    }

    @Test func listObjectsPage() throws {
        let xml = """
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Name>photos</Name><Prefix>2024/</Prefix><IsTruncated>true</IsTruncated>
          <NextContinuationToken>abc==</NextContinuationToken>
          <Contents><Key>2024/</Key><Size>0</Size></Contents>
          <Contents><Key>2024/a &amp; b.jpg</Key><Size>1234</Size><LastModified>2024-01-01T00:00:00.000Z</LastModified></Contents>
          <CommonPrefixes><Prefix>2024/janvier/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """
        let page = try #require(S3Response.listPage(Data(xml.utf8)))
        #expect(page.commonPrefixes == ["2024/janvier/"])
        #expect(page.objects.map(\.key) == ["2024/", "2024/a & b.jpg"])
        #expect(page.objects[1].size == 1234)
        #expect(page.nextContinuationToken == "abc==")
    }

    @Test func lastPageHasNoToken() throws {
        let xml = "<ListBucketResult><IsTruncated>false</IsTruncated><NextContinuationToken>x</NextContinuationToken></ListBucketResult>"
        #expect(try #require(S3Response.listPage(Data(xml.utf8))).nextContinuationToken == nil)
    }

    @Test func errors() {
        let xml = "<Error><Code>SignatureDoesNotMatch</Code><Message>Bad signature</Message></Error>"
        #expect(S3Response.error(Data(xml.utf8)) == .init(code: "SignatureDoesNotMatch", message: "Bad signature"))
        #expect(S3Response.error(Data("<ListBucketResult/>".utf8)) == nil)
        #expect(S3FileSystem.translate(status: 403, body: Data(xml.utf8)) == .authenticationFailed("Bad signature (SignatureDoesNotMatch)"))
        #expect(S3FileSystem.translate(status: 404, body: Data()) == .serverError(code: 404, message: "not found"))
    }

    @Test func multipartBodies() throws {
        let id = "<InitiateMultipartUploadResult><Bucket>b</Bucket><Key>k</Key><UploadId>u-1</UploadId></InitiateMultipartUploadResult>"
        #expect(S3Response.uploadID(Data(id.utf8)) == "u-1")

        let body = String(decoding: S3RequestBody.completeMultipartUpload(etags: ["\"e1\"", "\"e2\""]), as: UTF8.self)
        #expect(body == "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>&quot;e1&quot;</ETag></Part>"
            + "<Part><PartNumber>2</PartNumber><ETag>&quot;e2&quot;</ETag></Part></CompleteMultipartUpload>")

        #expect(S3RequestBody.createBucket(region: "auto") == nil)
        #expect(S3RequestBody.createBucket(region: "eu-west-3") != nil)
    }

    @Test func partSizeStaysUnderPartLimit() {
        let mebibyte: Int64 = 1024 * 1024
        #expect(S3Multipart.partSize(for: 200 * mebibyte) == 16 * mebibyte)
        let huge: Int64 = 500 * 1024 * mebibyte  // 500 Gio
        let size = S3Multipart.partSize(for: huge)
        #expect(size % mebibyte == 0)
        #expect((huge + size - 1) / size <= S3Multipart.maximumPartCount)
    }
}

@Suite("Analytique Cloudflare R2")
struct CloudflareR2AnalyticsTests {
    let period = DateInterval(start: Date(timeIntervalSince1970: 1_793_491_200), duration: 86_400)

    @Test func buildsAuthenticatedGraphQLRequest() throws {
        let request = try CloudflareR2Analytics.request(accountID: "acc", apiToken: "tok", period: period)
        #expect(request.url == CloudflareR2Analytics.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let variables = try #require(body["variables"] as? [String: String])
        #expect(variables["accountTag"] == "acc")
        #expect(variables["start"] == "2026-11-01T00:00:00Z")
        #expect((body["query"] as? String)?.contains("r2OperationsAdaptiveGroups") == true)
    }

    @Test func parsesStorageAndOperations() throws {
        let json = """
        {"data":{"viewer":{"accounts":[{
          "storage":[{"max":{"objectCount":12,"payloadSize":6000,"metadataSize":40},
                      "dimensions":{"bucketName":"photos","datetime":"2026-11-01T10:00:00Z"}}],
          "operations":[{"sum":{"requests":5},"dimensions":{"actionType":"PutObject"}},
                        {"sum":{"requests":3},"dimensions":{"actionType":"GetObject"}}]
        }]}},"errors":null}
        """
        let usage = try CloudflareR2Analytics.parse(Data(json.utf8), status: 200, period: period)
        #expect(usage.storageSamples == [.init(
            bucketName: "photos", date: Date(timeIntervalSince1970: 1_793_527_200),
            payloadBytes: 6000, metadataBytes: 40, objectCount: 12
        )])
        #expect(usage.requestsByAction == ["PutObject": 5, "GetObject": 3])
    }

    @Test func reportsRefusedToken() {
        let json = #"{"data":null,"errors":[{"message":"not authorized for that account"}]}"#
        #expect(throws: RemoteError.self) {
            try CloudflareR2Analytics.parse(Data(json.utf8), status: 200, period: period)
        }
        do {
            _ = try CloudflareR2Analytics.parse(Data(json.utf8), status: 200, period: period)
        } catch let error as RemoteError {
            guard case .authenticationFailed = error else { Issue.record("attendu : authenticationFailed"); return }
        } catch {
            Issue.record("erreur inattendue \(error)")
        }
    }

    @Test func usesInjectedTransport() async throws {
        let analytics = CloudflareR2Analytics { request in
            let json = #"{"data":{"viewer":{"accounts":[{"storage":[],"operations":[]}]}}}"#
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let usage = try await analytics.usage(accountID: "acc", apiToken: "tok", period: period)
        #expect(usage.storageSamples.isEmpty && usage.requestsByAction.isEmpty)
    }
}
