import Foundation
import MaxFtpCore
import NIOCore
import NIOPosix

/// Socket d'écoute pour le mode FTP actif : c'est le serveur qui se connecte à nous.
final class ActiveModeListener: Sendable {
    private let serverChannel: any Channel
    private let accepted: EventLoopPromise<NIOByteStream>

    private init(serverChannel: any Channel, accepted: EventLoopPromise<NIOByteStream>) {
        self.serverChannel = serverChannel
        self.accepted = accepted
    }

    /// Ouvre un port éphémère sur `localAddress` (l'interface du canal de contrôle).
    static func bind(localAddress: String, tls: TLSSettings?, acceptTimeout: TimeAmount = .seconds(20)) async throws -> ActiveModeListener {
        let group = MultiThreadedEventLoopGroup.singleton
        let accepted = group.next().makePromise(of: NIOByteStream.self)

        let server = try await ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 1)
            .childChannelInitializer { child in
                child.eventLoop.makeCompletedFuture {
                    let inbound = InboundBuffer()
                    try NIOByteStream.configurePipeline(child, tls: tls, inbound: inbound)
                    accepted.succeed(NIOByteStream(channel: child, inbound: inbound))
                }
            }
            .bind(host: localAddress, port: 0)
            .get()

        accepted.futureResult.eventLoop.scheduleTask(in: acceptTimeout) {
            accepted.fail(RemoteError.connectionFailed("le serveur ne s'est pas connecté (mode actif)."))
        }
        return ActiveModeListener(serverChannel: server, accepted: accepted)
    }

    /// Commande `PORT` (IPv4) ou `EPRT` (IPv6) annonçant ce socket au serveur.
    var announceCommand: String {
        get throws {
            guard let address = serverChannel.localAddress, let ip = address.ipAddress, let port = address.port else {
                throw RemoteError.connectionFailed("adresse locale indisponible pour le mode actif.")
            }
            if case .v6 = address {
                return "EPRT |2|\(ip)|\(port)|"
            }
            let octets = ip.split(separator: ".").joined(separator: ",")
            return "PORT \(octets),\(port / 256),\(port % 256)"
        }
    }

    func accept() async throws -> NIOByteStream {
        defer { Task { [serverChannel] in try? await serverChannel.close() } }
        return try await accepted.futureResult.get()
    }

    func close() async {
        accepted.fail(CancellationError())
        try? await serverChannel.close()
    }
}
