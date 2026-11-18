import Foundation
import MaxFtpCore
@testable import MaxFtpFTP
import NIOCore
import Testing

@Suite("Réponses FTP")
struct FTPReplyTests {
    @Test func singleLine() throws {
        var accumulator = FTPReplyAccumulator()
        let reply = try #require(try accumulator.consume("230 Login successful."))
        #expect(reply.code == 230)
        #expect(reply.message == "Login successful.")
        #expect(reply.isSuccess)
    }

    @Test func multiLine() throws {
        var accumulator = FTPReplyAccumulator()
        #expect(try accumulator.consume("211-Features:") == nil)
        #expect(try accumulator.consume(" MLST type*;size*;modify*;") == nil)
        #expect(try accumulator.consume(" UTF8") == nil)
        #expect(try accumulator.consume("211-pas encore la fin") == nil)
        let reply = try #require(try accumulator.consume("211 End"))
        #expect(reply.lines.count == 5)
        #expect(FTPResponseParsing.features(from: reply.lines) == ["MLST", "UTF8", "211-PAS"])
    }

    @Test func rejectsGarbage() {
        var accumulator = FTPReplyAccumulator()
        #expect(throws: RemoteError.self) { try accumulator.consume("hello") }
    }

    @Test func lineBufferHandlesSplitPackets() throws {
        var buffer = FTPLineBuffer()
        buffer.append(Array("220 Bien".utf8))
        #expect(try buffer.nextLine() == nil)
        buffer.append(Array("venue\r\n331 Mot de passe\n".utf8))
        #expect(try buffer.nextLine() == "220 Bienvenue")
        #expect(try buffer.nextLine() == "331 Mot de passe")
        #expect(try buffer.nextLine() == nil)
    }

    @Test func lineBufferRejectsOversizedLine() {
        var buffer = FTPLineBuffer()
        buffer.append(Array(repeating: UInt8(ascii: "A"), count: FTPLineBuffer.maxLineLength + 1))
        #expect(throws: RemoteError.self) {
            _ = try buffer.nextLine()
        }
    }

    @Test func passivePorts() {
        #expect(FTPResponseParsing.extendedPassivePort(from: "Entering Extended Passive Mode (|||6446|)") == 6446)
        #expect(FTPResponseParsing.extendedPassivePort(from: "Entering Extended Passive Mode (!!!21!)") == 21)
        #expect(FTPResponseParsing.extendedPassivePort(from: "garbage") == nil)
        #expect(FTPResponseParsing.passivePort(from: "Entering Passive Mode (192,168,1,2,19,137).") == 19 * 256 + 137)
        #expect(FTPResponseParsing.passivePort(from: "Entering Passive Mode (1,2,3,4,999,1)") == nil)
    }

    @Test func quotedPath() {
        #expect(FTPResponseParsing.quotedPath(from: #""/home/user" is current directory"#) == "/home/user")
        #expect(FTPResponseParsing.quotedPath(from: #""/dir with ""quotes""" created"#) == #"/dir with "quotes""#)
        #expect(FTPResponseParsing.quotedPath(from: "no quotes") == nil)
    }

    @Test func rejectsCRLFAndNullBytesInCommandLine() {
        #expect(FTPFileSystem.isSafeCommandLine("RETR /pub/fichier.txt"))
        #expect(!FTPFileSystem.isSafeCommandLine("RETR /pub/a\rb"))
        #expect(!FTPFileSystem.isSafeCommandLine("RETR /pub/a\nb"))
        // Grapheme cluster CRLF ("\r\n") : un seul Character en Swift, mais deux octets UTF-8.
        #expect(!FTPFileSystem.isSafeCommandLine("RETR /pub/a\r\nDELE /pub/cible"))
        #expect(!FTPFileSystem.isSafeCommandLine("RETR /pub/a\0b"))
    }

    @Test func inboundBufferBackpressureWatermarks() async throws {
        let buffer = InboundBuffer()
        let chunkSize = 1024 * 1024 // 1 Mio
        let chunk = ByteBuffer(repeating: 0x41, count: chunkSize)

        // 1 Mio < highWatermark (2 Mio) : pas de pause.
        #expect(!buffer.push(chunk))
        // 2 Mio >= highWatermark : demande la suspension d'autoRead.
        #expect(buffer.push(chunk))
        // Déjà en pause : ne redemande pas la suspension.
        #expect(!buffer.push(chunk))

        final class ResumeFlag: @unchecked Sendable { var resumed = false }
        let flag = ResumeFlag()

        // Il reste 2 Mio (> lowWatermark 512 Kio) : pas encore de reprise.
        _ = try await buffer.next { flag.resumed = true }
        #expect(!flag.resumed)

        // Il reste 1 Mio (> lowWatermark 512 Kio) : pas encore de reprise.
        _ = try await buffer.next { flag.resumed = true }
        #expect(!flag.resumed)

        // Il reste 0 octet (<= lowWatermark) : réactive autoRead.
        _ = try await buffer.next { flag.resumed = true }
        #expect(flag.resumed)
    }
}

@Suite("Listings FTP")
struct FTPListParserTests {
    let directory: RemotePath = "/pub"

    @Test func mlsd() throws {
        let items = FTPListParser.parseMLSD("""
        type=cdir;modify=20240101000000; .
        type=dir;modify=20240131120000;UNIX.mode=0755;UNIX.owner=www; images
        type=file;size=1024;modify=20240131120000.123;UNIX.mode=0644; read me.txt
        type=OS.unix=slink:/etc/x;modify=20240131120000; lien
        """, in: directory)

        #expect(items.map(\.name) == ["images", "read me.txt", "lien"])
        #expect(items[0].kind == .directory)
        #expect(items[0].owner == "www")
        #expect(items[1].size == 1024)
        #expect(items[1].permissions?.octalString == "0644")
        #expect(items[1].path == "/pub/read me.txt")
        #expect(items[2].kind == .symbolicLink)

        let date = try #require(items[1].modificationDate)
        #expect(date == Date(timeIntervalSince1970: 1_706_702_400))
    }

    @Test func unixList() throws {
        let now = Date(timeIntervalSince1970: 1_717_200_000)  // 1er juin 2024
        let items = FTPListParser.parseLIST("""
        total 12
        drwxr-xr-x    2 www      www          4096 Jan 31 12:00 site web
        -rw-r--r--    1 www      www         12345 Dec 25  2022 archive.tar.gz
        lrwxrwxrwx    1 root     root            7 Mar  3 09:15 current -> releases/42
        -rw-------    1 ftp       512 Feb  2 10:00 sans-groupe.txt
        drwxr-xr-x    2 www      www          4096 Jan 31 12:00 .
        """, in: directory, now: now)

        #expect(items.map(\.name) == ["site web", "archive.tar.gz", "current", "sans-groupe.txt"])
        #expect(items[0].kind == .directory)
        #expect(items[0].permissions?.octalString == "0755")
        #expect(items[1].size == 12345)
        #expect(items[2].kind == .symbolicLink)
        #expect(items[2].symbolicLinkTarget == "releases/42")
        #expect(items[3].size == 512)
        #expect(items[3].owner == "ftp")
        #expect(items[3].group == nil)

        let calendar = Calendar(identifier: .gregorian)
        #expect(calendar.component(.year, from: items[0].modificationDate!) == 2024)
        #expect(calendar.component(.year, from: items[1].modificationDate!) == 2022)
    }

    @Test func dateWithoutYearInTheFutureMeansLastYear() {
        let now = Date(timeIntervalSince1970: 1_706_745_600)  // 1er février 2024
        let date = FTPListParser.unixDate(month: 12, day: 24, timeOrYear: "18:00", now: now)
        #expect(Calendar(identifier: .gregorian).component(.year, from: date!) == 2023)
    }

    @Test func dosList() {
        let items = FTPListParser.parseLIST("""
        01-31-24  03:45PM       <DIR>          Mes Documents
        01-31-2024  15:45            1234 rapport final.pdf
        """, in: directory)

        #expect(items.map(\.name) == ["Mes Documents", "rapport final.pdf"])
        #expect(items[0].isDirectory)
        #expect(items[1].size == 1234)
        let calendar = Calendar(identifier: .gregorian)
        #expect(calendar.component(.hour, from: items[0].modificationDate!) == 15)
    }

    @Test func rejectsTraversalEntriesInListings() {
        let mlsd = FTPListParser.parseMLSD("""
        type=file;size=10; ../secret.txt
        type=file;size=10; sous/dossier.txt
        type=file;size=10; propre.txt
        """, in: directory)
        #expect(mlsd.map(\.name) == ["propre.txt"])

        let unix = FTPListParser.parseLIST("""
        -rw-r--r-- 1 www www 10 Jan 31 12:00 ../secret.txt
        -rw-r--r-- 1 www www 10 Jan 31 12:00 propre.txt
        """, in: directory)
        #expect(unix.map(\.name) == ["propre.txt"])
    }
}
