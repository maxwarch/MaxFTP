import Foundation
import MaxFtpCore
import NIOCore

// Mécanique du protocole FTP : session de contrôle, commandes, canal de données.
// Toutes ces méthodes supposent d'être appelées DEPUIS `exclusive { … }`.

extension FTPFileSystem {
    // MARK: Session

    /// Ouvre la session si elle n'existe pas ou si le serveur l'a fermée (timeout d'inactivité…).
    func ensureConnected() async throws {
        if let control, control.isActive { return }
        await closeSession(sendQuit: false)
        do {
            try await openSession()
        } catch {
            await closeSession(sendQuit: false)
            throw error
        }
    }

    private func openSession() async throws {
        let proto = configuration.connectionProtocol
        tls = proto.usesTLS
            ? try TLSSettings.make(host: configuration.host, allowUntrusted: configuration.allowsUntrustedCertificates)
            : nil
        lineBuffer = FTPLineBuffer()
        features = []

        do {
            control = try await NIOByteStream.connect(
                host: configuration.host,
                port: configuration.port,
                tls: proto == .ftpsImplicit ? tls : nil
            )
        } catch {
            throw RemoteError.connectionFailed(String(describing: error))
        }

        let greeting = try await readReply()
        guard greeting.code == 220 else { throw greeting.error }

        if proto == .ftpsExplicit, let tls {
            try await command("AUTH TLS", expecting: 234)
            try await control?.startTLS(tls)
        }

        try await login()

        if tls != nil {
            try await command("PBSZ 0", expecting: 200)
            try await command("PROT P", expecting: 200)
        }
        try await command("TYPE I", expecting: 200)

        if let feat = try? await command("FEAT"), feat.code == 211 {
            features = FTPResponseParsing.features(from: feat.lines)
        }
        if features.contains("UTF8") {
            _ = try? await command("OPTS UTF8 ON")
        }
        logger.info("Session FTP ouverte sur \(self.configuration.host, privacy: .public) — \(self.features.sorted(), privacy: .public)")
    }

    private func login() async throws {
        let user: String
        let password: String
        switch configuration.credential {
        case .anonymous:
            (user, password) = ("anonymous", "anonymous@")
        case .password(let secret):
            (user, password) = (configuration.username.isEmpty ? "anonymous" : configuration.username, secret)
        case .privateKey:
            throw RemoteError.authenticationFailed("l'authentification par clé n'existe pas en FTP.")
        }

        let userReply = try await command("USER \(user)")
        switch userReply.code {
        case 230:
            return
        case 331, 332:
            let passReply = try await command("PASS \(password)")
            guard passReply.code == 230 || passReply.code == 202 else {
                throw RemoteError.authenticationFailed(passReply.message)
            }
        default:
            throw userReply.error
        }
    }

    func closeSession(sendQuit: Bool) async {
        guard let control else { return }
        if sendQuit, control.isActive {
            try? await control.write(Array("QUIT\r\n".utf8))
        }
        await control.close()
        self.control = nil
    }

    // MARK: Commandes

    /// Envoie une commande et attend la réponse complète.
    /// Si `codes` n'est pas vide, tout autre code est converti en erreur.
    @discardableResult
    func command(_ line: String, expecting codes: Set<Int> = []) async throws -> FTPReply {
        try await send(line)
        let reply = try await readReply()
        if !codes.isEmpty, !codes.contains(reply.code) {
            throw reply.error
        }
        return reply
    }

    @discardableResult
    func command(_ line: String, expecting code: Int) async throws -> FTPReply {
        try await command(line, expecting: [code])
    }

    private func send(_ line: String) async throws {
        // Un CR/LF dans un nom de fichier permettrait d'injecter des commandes.
        guard !line.contains("\r"), !line.contains("\n") else {
            throw RemoteError.invalidPath(line)
        }
        guard let control else { throw RemoteError.notConnected }
        let logged = line.hasPrefix("PASS ") ? "PASS ••••" : line
        logger.debug("→ \(logged, privacy: .public)")
        do {
            try await control.write(Array((line + "\r\n").utf8))
        } catch {
            await closeSession(sendQuit: false)
            throw RemoteError.connectionClosed
        }
    }

    func readReply() async throws -> FTPReply {
        var accumulator = FTPReplyAccumulator()
        while true {
            let line = try await readLine()
            if let reply = try accumulator.consume(line) {
                logger.debug("← \(reply.code) \(reply.message, privacy: .public)")
                if reply.code == 421 { await closeSession(sendQuit: false) }
                return reply
            }
        }
    }

    private func readLine() async throws -> String {
        while true {
            if let line = lineBuffer.nextLine() { return line }
            guard let control else { throw RemoteError.notConnected }
            guard let chunk = try await control.next() else {
                await closeSession(sendQuit: false)
                throw RemoteError.connectionClosed
            }
            lineBuffer.append(chunk.readableBytesView)
        }
    }

    // MARK: Canal de données

    /// Lit intégralement la réponse d'une commande de listing.
    func receiveData(_ commandLine: String) async throws -> [UInt8] {
        try await withDataConnection(commandLine) { data in
            var bytes: [UInt8] = []
            while let chunk = try await data.next() {
                bytes.append(contentsOf: chunk.readableBytesView)
            }
            return bytes
        }
    }

    /// Ouvre un canal de données (passif ou actif), envoie `commandLine`, exécute
    /// `body` sur le canal puis attend la réponse finale (`226`).
    ///
    /// En cas d'erreur ou d'annulation pendant `body`, l'état du canal de contrôle
    /// devient incertain : on ferme la session, elle sera rouverte à la prochaine opération.
    func withDataConnection<T: Sendable>(_ commandLine: String, _ body: (NIOByteStream) async throws -> T) async throws -> T {
        let data = try await openDataConnection(for: commandLine)

        let result: T
        do {
            result = try await body(data)
        } catch {
            await data.close()
            await closeSession(sendQuit: false)
            throw error
        }

        await data.close()
        let final = try await readReply()
        guard final.isSuccess else { throw final.error }
        return result
    }

    private func openDataConnection(for commandLine: String) async throws -> NIOByteStream {
        switch configuration.ftpDataMode {
        case .passive:
            let port = try await enterPassiveMode()
            let data: NIOByteStream
            do {
                data = try await NIOByteStream.connect(host: configuration.host, port: port, tls: tls)
            } catch {
                throw RemoteError.connectionFailed("canal de données : \(error)")
            }
            let reply = try await command(commandLine)
            guard reply.isPreliminary else {
                await data.close()
                throw reply.error
            }
            return data

        case .active:
            guard let localIP = control?.channel.localAddress?.ipAddress else { throw RemoteError.notConnected }
            let listener = try await ActiveModeListener.bind(localAddress: localIP, tls: tls)
            do {
                try await command(try listener.announceCommand, expecting: 200)
                let reply = try await command(commandLine)
                guard reply.isPreliminary else { throw reply.error }
                return try await listener.accept()
            } catch {
                await listener.close()
                throw error
            }
        }
    }

    /// `EPSV` (IPv4/IPv6), avec repli sur `PASV` pour les vieux serveurs.
    private func enterPassiveMode() async throws -> Int {
        if !extendedPassiveUnsupported {
            let reply = try await command("EPSV")
            if reply.code == 229, let port = FTPResponseParsing.extendedPassivePort(from: reply.message) {
                return port
            }
            extendedPassiveUnsupported = true
        }
        let reply = try await command("PASV", expecting: 227)
        guard let port = FTPResponseParsing.passivePort(from: reply.message) else {
            throw RemoteError.protocolViolation(reply.message)
        }
        return port
    }
}
