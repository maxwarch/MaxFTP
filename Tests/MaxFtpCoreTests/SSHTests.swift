import CryptoKit
import Foundation
@testable import MaxFtpCore
import Testing

@Suite("SSHConfig")
struct SSHConfigTests {
    let config = SSHConfig(contents: """
    # Commentaire
    Host prod
        HostName 203.0.113.10
        User deploy
        Port 2222
        IdentityFile ~/.ssh/prod_ed25519

    Host *.internal !secret.internal
        User admin

    Host *
        User fallback
        IdentityFile ~/.ssh/id_ed25519
    """)

    @Test func resolvesAlias() {
        let settings = config.settings(forAlias: "prod")
        #expect(settings.hostName == "203.0.113.10")
        #expect(settings.user == "deploy")  // la première valeur gagne
        #expect(settings.port == 2222)
        #expect(settings.identityFiles.count == 2)
        #expect(settings.identityFiles.first?.hasSuffix(".ssh/prod_ed25519") == true)
    }

    @Test func wildcardsAndNegation() {
        #expect(config.settings(forAlias: "db.internal").user == "admin")
        #expect(config.settings(forAlias: "secret.internal").user == "fallback")
        #expect(config.settings(forAlias: "unknown").hostName == "unknown")
    }

    @Test func listsExplicitAliases() {
        #expect(config.aliases == ["prod"])
    }
}

@Suite("KnownHostsFile")
struct KnownHostsFileTests {
    let githubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"

    @Test func matchesPlainEntries() {
        let file = KnownHostsFile(contents: """
        github.com,140.82.121.4 \(githubKey)
        [example.com]:2222 ssh-rsa AAAAB3Nza
        @revoked bad.example ssh-rsa AAAA
        """)
        #expect(file.keys(for: KnownHostIdentifier(host: "GitHub.com", port: 22)) == [githubKey])
        #expect(file.keys(for: KnownHostIdentifier(host: "example.com", port: 2222)) == ["ssh-rsa AAAAB3Nza"])
        #expect(file.keys(for: KnownHostIdentifier(host: "example.com", port: 22)).isEmpty)
    }

    @Test func matchesHashedEntries() {
        let salt = Data((0..<20).map { UInt8($0) })
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data("github.com".utf8), using: SymmetricKey(data: salt))
        let hashed = "|1|\(salt.base64EncodedString())|\(Data(mac).base64EncodedString())"
        let file = KnownHostsFile(contents: "\(hashed) \(githubKey)")
        #expect(file.keys(for: KnownHostIdentifier(host: "github.com", port: 22)) == [githubKey])
        #expect(file.keys(for: KnownHostIdentifier(host: "gitlab.com", port: 22)).isEmpty)
    }

    @Test func fingerprintMatchesOpenSSH() {
        // Empreinte publiée par GitHub pour sa clé ed25519.
        let challenge = HostKeyChallenge(host: KnownHostIdentifier(host: "github.com", port: 22), openSSHKey: githubKey)
        #expect(challenge.fingerprint == "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU")
        #expect(challenge.keyType == "ssh-ed25519")
    }
}
