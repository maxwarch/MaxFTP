import Foundation
@testable import MaxFtpCore
import Testing

@Suite("RemotePath")
struct RemotePathTests {
    @Test func childUnderAncestor() {
        #expect(RemotePath("/a/b/c").child(under: "/a") == "/a/b")
        #expect(RemotePath("/a/b").child(under: "/a") == "/a/b")
        #expect(RemotePath("/a/b").child(under: "/") == "/a")
        #expect(RemotePath("/a").child(under: "/a") == nil)
        #expect(RemotePath("/x/y").child(under: "/a") == nil)
    }

    @Test func normalizesDotsAndSlashes() {
        #expect(RemotePath("/var//www/./site/../html/").string == "/var/www/html")
        #expect(RemotePath("").isRoot)
        #expect(RemotePath("/..").isRoot)
    }

    @Test func navigation() {
        let path: RemotePath = "/var/www/index.html"
        #expect(path.name == "index.html")
        #expect(path.parent == "/var/www")
        #expect(RemotePath.root.parent == .root)
        #expect(path.ancestors.map(\.string) == ["/", "/var", "/var/www", "/var/www/index.html"])
        #expect(RemotePath("/var").appending("log/app.log").string == "/var/log/app.log")
        #expect(path.isDescendant(of: "/var"))
        #expect(!RemotePath("/var").isDescendant(of: "/var"))
    }

    @Test func codableAsString() throws {
        let data = try JSONEncoder().encode(RemotePath("/a/b"))
        #expect(String(decoding: data, as: UTF8.self) == "\"\\/a\\/b\"")
        #expect(try JSONDecoder().decode(RemotePath.self, from: data) == "/a/b")
    }
}

@Suite("POSIXPermissions")
struct POSIXPermissionsTests {
    @Test(arguments: [
        ("rwxr-xr-x", "0755"),
        ("rw-r--r--", "0644"),
        ("drwx------", "0700"),
        ("rwsr-xr-x", "4755"),
        ("rwxrwxrwt", "1777"),
        ("rw-r-Sr--", "2644"),
    ])
    func symbolicToOctal(symbolic: String, octal: String) throws {
        let permissions = try #require(POSIXPermissions(symbolic: symbolic))
        #expect(permissions.octalString == octal)
        #expect(POSIXPermissions(octal: octal) == permissions)
    }

    @Test func roundTripsSymbolic() {
        for value: UInt16 in [0o755, 0o644, 0o4755, 0o1777, 0o2640] {
            let permissions = POSIXPermissions(rawValue: value)
            #expect(POSIXPermissions(symbolic: permissions.symbolicString) == permissions)
        }
    }

    @Test func rejectsGarbage() {
        #expect(POSIXPermissions(symbolic: "rwx") == nil)
        #expect(POSIXPermissions(symbolic: "rwxr-xr-q") == nil)
        #expect(POSIXPermissions(octal: "999") == nil)
    }

    @Test func toggleBits() {
        var permissions = POSIXPermissions(rawValue: 0o644)
        permissions.set(.execute, for: .owner, enabled: true)
        permissions.set(.read, for: .others, enabled: false)
        #expect(permissions.octalString == "0740")
        #expect(permissions.allows(.write, for: .owner))
        #expect(!permissions.allows(.write, for: .group))
    }
}

@Suite("QuickConnectTarget")
struct QuickConnectTargetTests {
    @Test func fullURL() throws {
        let target = try #require(QuickConnectTarget(parsing: "ftps://bob:p%40ss@ftp.example.com:2121/pub/files"))
        #expect(target == QuickConnectTarget(
            connectionProtocol: .ftpsImplicit,
            host: "ftp.example.com",
            port: 2121,
            username: "bob",
            password: "p@ss",
            path: "/pub/files"
        ))
    }

    @Test func s3URLTargetsBucket() throws {
        let target = try #require(QuickConnectTarget(parsing: "s3://AKID:SECRET@acc.r2.cloudflarestorage.com/photos"))
        #expect(target.connectionProtocol == .s3)
        #expect(target.username == "AKID")
        #expect(target.password == "SECRET")
        #expect(target.path == "/photos")
    }

    @Test func shorthandDefaultsToSFTP() throws {
        let target = try #require(QuickConnectTarget(parsing: "alice@server.local"))
        #expect(target.connectionProtocol == .sftp)
        #expect(target.username == "alice")
        #expect(target.host == "server.local")
        #expect(target.port == nil)
    }

    @Test func rejectsInvalid() {
        #expect(QuickConnectTarget(parsing: "   ") == nil)
        #expect(QuickConnectTarget(parsing: "gopher://host") == nil)
    }
}

@Suite("ServerBookmark")
struct ServerBookmarkTests {
    @Test func decodesOlderSchemaWithDefaults() throws {
        // Favori écrit par une version qui ne connaissait pas encore les champs optionnels.
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","connectionProtocol":"ftp","host":"ftp.example.com"}"#
        let bookmark = try JSONDecoder().decode(ServerBookmark.self, from: Data(json.utf8))
        #expect(bookmark.port == 21)
        #expect(bookmark.ftpDataMode == .passive)
        #expect(bookmark.authenticationKind == .password)
        #expect(bookmark.displayName == "ftp.example.com")
        #expect(bookmark.s3Region == "auto")
    }

    @Test func s3BookmarkKeepsRegionAndHidesAccessKey() throws {
        let bookmark = ServerBookmark(connectionProtocol: .s3, host: "acc.r2.cloudflarestorage.com", username: "AKID", s3Region: "eu-west-3")
        let decoded = try JSONDecoder().decode(ServerBookmark.self, from: JSONEncoder().encode(bookmark))
        #expect(decoded.port == 443)
        let configuration = decoded.configuration(secret: "secret")
        #expect(configuration.s3Region == "eu-west-3")
        #expect(configuration.credential == .password("secret"))
        #expect(configuration.displayName == "acc.r2.cloudflarestorage.com")
        #expect(ServerBookmark.from(configuration, name: "R2").bookmark.s3Region == "eu-west-3")
        #expect(!ConnectionProtocol.s3.isFTPFamily && !ConnectionProtocol.s3.supportsPermissions)
    }

    @Test func configurationUsesSecret() {
        let key = ServerBookmark(connectionProtocol: .sftp, host: "h", username: "u", authenticationKind: .privateKey, privateKeyPath: "/k")
        #expect(key.configuration(secret: "pass").credential == .privateKey(URL(fileURLWithPath: "/k"), passphrase: "pass"))

        let anonymous = ServerBookmark(connectionProtocol: .ftp, host: "h")
        #expect(anonymous.configuration(secret: nil).credential == .anonymous)

        // Une clé n'a pas de sens en FTP : on retombe sur le mot de passe.
        let ftpKey = ServerBookmark(connectionProtocol: .ftp, host: "h", username: "u", authenticationKind: .privateKey)
        #expect(ftpKey.configuration(secret: "pw").credential == .password("pw"))
    }
}
