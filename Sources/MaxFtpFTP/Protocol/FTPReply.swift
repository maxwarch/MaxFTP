import Foundation
import MaxFtpCore

/// Réponse du serveur FTP (RFC 959 §4.2), éventuellement multi-lignes.
struct FTPReply: Equatable, Sendable {
    let code: Int
    let lines: [String]

    var message: String { lines.joined(separator: "\n").trimmingCharacters(in: .whitespaces) }

    var isPreliminary: Bool { (100..<200).contains(code) }
    var isSuccess: Bool { (200..<300).contains(code) }
    var isIntermediate: Bool { (300..<400).contains(code) }

    /// Transforme la réponse en erreur du domaine.
    var error: RemoteError {
        switch code {
        case 530: .authenticationFailed(message)
        case 421: .connectionClosed
        default: .serverError(code: code, message: message)
        }
    }
}

/// Assemble les lignes reçues en ``FTPReply`` complètes.
///
/// Multi-lignes : `123-début` … lignes libres … `123 fin`.
struct FTPReplyAccumulator {
    private var pendingCode: Int?
    private var lines: [String] = []

    /// Renvoie une réponse quand la dernière ligne est reçue, `nil` sinon.
    mutating func consume(_ line: String) throws -> FTPReply? {
        if let code = pendingCode {
            if Self.code(of: line) == code, line.dropFirst(3).first == " " {
                lines.append(String(line.dropFirst(4)))
                pendingCode = nil
                defer { lines = [] }
                return FTPReply(code: code, lines: lines)
            }
            lines.append(line)
            return nil
        }

        guard let code = Self.code(of: line) else {
            throw RemoteError.protocolViolation(line)
        }
        if line.dropFirst(3).first == "-" {
            pendingCode = code
            lines = [String(line.dropFirst(4))]
            return nil
        }
        return FTPReply(code: code, lines: [String(line.dropFirst(4))])
    }

    private static func code(of line: String) -> Int? {
        guard line.count >= 3 else { return nil }
        let prefix = line.prefix(3)
        guard prefix.allSatisfy(\.isNumber) else { return nil }
        return Int(prefix)
    }
}

/// Découpe un flux d'octets en lignes terminées par CRLF (ou LF seul, toléré).
struct FTPLineBuffer {
    private var bytes: [UInt8] = []

    mutating func append<S: Sequence>(_ data: S) where S.Element == UInt8 {
        bytes.append(contentsOf: data)
    }

    mutating func nextLine() -> String? {
        guard let newline = bytes.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        var end = newline
        if end > 0, bytes[end - 1] == UInt8(ascii: "\r") { end -= 1 }
        let line = String(decoding: bytes[..<end], as: UTF8.self)
        bytes.removeSubrange(...newline)
        return line
    }
}
