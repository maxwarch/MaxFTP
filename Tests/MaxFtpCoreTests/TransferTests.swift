import Foundation
@testable import MaxFtpCore
import MaxFtpTestSupport
import Testing

@Suite("Transferts")
struct TransferTests {
    /// Dossier local temporaire : `site/index.html`, `site/css/app.css`.
    func makeLocalTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let site = root.appendingPathComponent("site")
        try FileManager.default.createDirectory(at: site.appendingPathComponent("css"), withIntermediateDirectories: true)
        try Data("<h1>Hi</h1>".utf8).write(to: site.appendingPathComponent("index.html"))
        try Data("body{}".utf8).write(to: site.appendingPathComponent("css/app.css"))
        return site
    }

    @Test func uploadPlanWalksDirectories() throws {
        let site = try makeLocalTree()
        let plan = try TransferPlanner.uploadPlan(for: site, into: "/var/www")

        #expect(plan.steps.first == .createRemoteDirectory("/var/www/site"))
        #expect(plan.steps.contains(.createRemoteDirectory("/var/www/site/css")))
        #expect(plan.fileCount == 2)
        #expect(plan.totalBytes == 17)
    }

    @Test func uploadsDirectoryEndToEnd() async throws {
        let site = try makeLocalTree()
        let server = InMemoryFileSystem(files: ["/var/www/.keep": ""])
        let plan = try TransferPlanner.uploadPlan(for: site, into: "/var/www")

        try await TransferExecutor.execute(plan, on: server) { _ in }

        #expect(await server.contents(of: "/var/www/site/index.html") == "<h1>Hi</h1>")
        #expect(await server.contents(of: "/var/www/site/css/app.css") == "body{}")
    }

    @Test func downloadsDirectoryEndToEnd() async throws {
        let server = InMemoryFileSystem(files: [
            "/data/report.txt": "rapport",
            "/data/img/logo.svg": "<svg/>",
        ])
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/data")
        let item = RemoteItem(path: "/data", kind: .directory)

        let plan = try await TransferPlanner.downloadPlan(for: item, to: destination, using: server)
        try await TransferExecutor.execute(plan, on: server) { _ in }

        #expect(try String(contentsOf: destination.appendingPathComponent("report.txt"), encoding: .utf8) == "rapport")
        #expect(try String(contentsOf: destination.appendingPathComponent("img/logo.svg"), encoding: .utf8) == "<svg/>")
    }

    @Test func reportsCumulativeProgress() async throws {
        let server = InMemoryFileSystem(files: ["/a.txt": "12345", "/b.txt": "123"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let plan = TransferPlan(steps: [
            .download("/a.txt", to: directory.appendingPathComponent("a.txt"), size: 5),
            .download("/b.txt", to: directory.appendingPathComponent("b.txt"), size: 3),
        ])
        let recorder = ProgressRecorder()
        try await TransferExecutor.execute(plan, on: server) { recorder.append($0) }
        #expect(recorder.values.last == 8)
        #expect(recorder.values == recorder.values.sorted())
    }

    @Test func removesDirectoriesRecursively() async throws {
        let server = InMemoryFileSystem(files: ["/www/a/b/c.txt": "x", "/www/a/d.txt": "y", "/www/keep.txt": "z"])
        try await server.removeItem(RemoteItem(path: "/www/a", kind: .directory))
        let remaining = try await server.contentsOfDirectory(at: "/www").map(\.name)
        #expect(remaining == ["keep.txt"])
    }

    @Test func uniqueLocalURL() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("photo.jpg")
        try Data().write(to: original)
        #expect(LocalFileIO.uniqueURL(for: original).lastPathComponent == "photo 2.jpg")
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int64] = []
    var values: [Int64] { lock.withLock { storage } }
    func append(_ value: Int64) { lock.withLock { storage.append(value) } }
}
