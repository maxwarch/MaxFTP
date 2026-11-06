@preconcurrency import Citadel
import CryptoKit
import Foundation
import MaxFtpCore

/// Traduit un ``Credential`` du domaine en méthode d'authentification Citadel.
enum SSHAuthenticationFactory {
    static func method(for configuration: ConnectionConfiguration) throws -> SSHAuthenticationMethod {
        let username = configuration.username
        switch configuration.credential {
        case .anonymous:
            return .passwordBased(username: username, password: "")
        case .password(let password):
            return .passwordBased(username: username, password: password)
        case .privateKey(let url, let passphrase):
            return try privateKeyMethod(username: username, keyURL: url, passphrase: passphrase)
        }
    }

    static func privateKeyMethod(username: String, keyURL: URL, passphrase: String?) throws -> SSHAuthenticationMethod {
        let text: String
        do {
            text = try String(contentsOf: keyURL, encoding: .utf8)
        } catch {
            throw RemoteError.localFileError("Lecture de la clé \(keyURL.path) impossible.")
        }

        let decryptionKey = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        let keyType: SSHKeyType
        do {
            keyType = try SSHKeyDetection.detectPrivateKeyType(from: text)
        } catch {
            throw RemoteError.unsupportedPrivateKey("format non reconnu (seul le format OpenSSH est pris en charge).")
        }

        do {
            switch keyType {
            case .ed25519:
                return .ed25519(username: username, privateKey: try Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: decryptionKey))
            case .rsa:
                return .rsa(username: username, privateKey: try Insecure.RSA.PrivateKey(sshRsa: text, decryptionKey: decryptionKey))
            default:
                throw RemoteError.unsupportedPrivateKey("type \(keyType) non pris en charge (utilisez ed25519 ou RSA).")
            }
        } catch let error as RemoteError {
            throw error
        } catch {
            throw RemoteError.unsupportedPrivateKey(
                decryptionKey == nil ? "la clé est peut-être protégée par une passphrase." : "passphrase incorrecte ?"
            )
        }
    }
}
