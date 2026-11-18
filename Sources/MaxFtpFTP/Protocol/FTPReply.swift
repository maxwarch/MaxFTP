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
    static let maxLines = 1_024

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
            guard lines.count < Self.maxLines else {
                throw RemoteError.protocolViolation("Réponse FTP multi-lignes trop volumineuse.")
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
///
/// Utilise un curseur de lecture (`readIndex`) pour consommer en O(1) amorti sans
/// décaler tout le tableau à chaque ligne, et plafonne la longueur d'une ligne pour
/// éviter tout épuisement mémoire face à un flux sans retour à la ligne.
struct FTPLineBuffer {
    static let maxLineLength = 64 * 1024

    private var bytes: [UInt8] = []
    private var readIndex = 0

    mutating func append<S: Sequence>(_ data: S) where S.Element == UInt8 {
        bytes.append(contentsOf: data)
    }

    mutating func nextLine() throws -> String? {
        let slice = bytes[readIndex...]
        guard let newline = slice.firstIndex(of: UInt8(ascii: "\n")) else {
            if slice.count > Self.maxLineLength {
                throw RemoteError.protocolViolation("Ligne de réponse FTP trop longue.")
            }
            return nil
        }
        if newline - readIndex > Self.maxLineLength {
            throw RemoteError.protocolViolation("Ligne de réponse FTP trop longue.")
        }
        var end = newline
        if end > readIndex, bytes[end - 1] == UInt8(ascii: "\r") { end -= 1 }
        let line = String(decoding: bytes[readIndex..<end], as: UTF8.self)
        readIndex = newline + 1
        if readIndex == bytes.count {
            bytes.removeAll(keepingCapacity: true)
            readIndex = 0
        } else if readIndex >= 4096 {
            bytes.removeSubrange(..<readIndex)
            readIndex = 0
        }
        return line
    }
}
