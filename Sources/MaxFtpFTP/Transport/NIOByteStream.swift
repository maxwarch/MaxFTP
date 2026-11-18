import Foundation
import MaxFtpCore
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL

/// Paramètres TLS partagés par le canal de contrôle et les canaux de données.
struct TLSSettings: Sendable {
    let context: NIOSSLContext
    /// `nil` quand l'hôte est une adresse IP (SNI interdit).
    let serverHostname: String?

    func makeHandler() throws -> NIOSSLClientHandler {
        try NIOSSLClientHandler(context: context, serverHostname: serverHostname)
    }

    static func make(host: String, allowUntrusted: Bool) throws -> TLSSettings {
        var configuration = TLSConfiguration.makeClientConfiguration()
        let isIPAddress = (try? SocketAddress(ipAddress: host, port: 0)) != nil
        if allowUntrusted {
            configuration.certificateVerification = .none
        } else if isIPAddress {
            configuration.certificateVerification = .noHostnameVerification
        }
        return TLSSettings(context: try NIOSSLContext(configuration: configuration), serverHostname: isIPAddress ? nil : host)
    }
}

/// Connexion TCP (éventuellement TLS) exposée sous forme d'API `async`.
///
/// Encapsule tout le code SwiftNIO : le reste du module FTP ne manipule que
/// `write`, `next` et `close`. Remplacer NIO par Network.framework ne toucherait
/// que ce fichier et ``ActiveModeListener``.
final class NIOByteStream: Sendable {
    let channel: any Channel
    private let inbound: InboundBuffer

    init(channel: any Channel, inbound: InboundBuffer) {
        self.channel = channel
        self.inbound = inbound
    }

    static func connect(host: String, port: Int, tls: TLSSettings?, timeout: TimeAmount = .seconds(20)) async throws -> NIOByteStream {
        let inbound = InboundBuffer()
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(timeout)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try configurePipeline(channel, tls: tls, inbound: inbound)
                }
            }
            .connect(host: host, port: port)
            .get()
        return NIOByteStream(channel: channel, inbound: inbound)
    }

    static func configurePipeline(_ channel: any Channel, tls: TLSSettings?, inbound: InboundBuffer) throws {
        if let tls {
            try channel.pipeline.syncOperations.addHandler(try tls.makeHandler())
        }
        try channel.pipeline.syncOperations.addHandler(InboundBufferHandler(buffer: inbound))
    }

    var isActive: Bool { channel.isActive }

    func write(_ bytes: some Sequence<UInt8>) async throws {
        try await channel.writeAndFlush(ByteBuffer(bytes: bytes))
    }

    /// Prochain bloc reçu, ou `nil` en fin de flux.
    func next() async throws -> ByteBuffer? {
        let channel = self.channel
        return try await withTaskCancellationHandler {
            try await inbound.next {
                _ = channel.setOption(ChannelOptions.autoRead, value: true)
            }
        } onCancel: {
            inbound.fail(CancellationError())
        }
    }

    /// Bascule une connexion en clair vers TLS (`AUTH TLS` du FTPS explicite).
    func startTLS(_ tls: TLSSettings) async throws {
        try await channel.eventLoop.submit { [channel] in
            try channel.pipeline.syncOperations.addHandler(try tls.makeHandler(), position: .first)
        }.get()
    }

    func close() async {
        try? await channel.close()
    }
}

// MARK: - Tampon de réception

/// File d'attente thread-safe entre la boucle d'événements NIO (producteur)
/// et le code `async` (consommateur unique), avec contrôle de flux par seuils
/// (high / low watermark) pour borner l'empreinte mémoire lors des gros téléchargements.
final class InboundBuffer: Sendable {
    static let highWatermark = 2 * 1024 * 1024
    static let lowWatermark = 512 * 1024

    private enum Completion {
        case finished
        case failed(any Error)
    }

    private struct State {
        var chunks: [ByteBuffer] = []
        var headIndex = 0
        var queuedBytes = 0
        var isReadingPaused = false
        var completion: Completion?
        var waiter: CheckedContinuation<ByteBuffer?, any Error>?
    }

    private let state = NIOLockedValueBox(State())

    /// Ajoute un bloc reçu. Renvoie `true` si le tampon dépasse ``highWatermark`` et que
    /// la lecture automatique du canal (`autoRead`) doit être mise en pause.
    @discardableResult
    func push(_ chunk: ByteBuffer) -> Bool {
        state.withLockedValue { state in
            if let waiter = state.waiter {
                state.waiter = nil
                waiter.resume(returning: chunk)
                return false
            }
            state.chunks.append(chunk)
            state.queuedBytes += chunk.readableBytes
            if !state.isReadingPaused, state.queuedBytes >= Self.highWatermark {
                state.isReadingPaused = true
                return true
            }
            return false
        }
    }

    func finish() { complete(.finished) }
    func fail(_ error: any Error) { complete(.failed(error)) }

    private func complete(_ completion: Completion) {
        state.withLockedValue { state in
            guard state.completion == nil else { return }
            state.completion = completion
            if let waiter = state.waiter {
                state.waiter = nil
                switch completion {
                case .finished: waiter.resume(returning: nil)
                case .failed(let error): waiter.resume(throwing: error)
                }
            }
        }
    }

    func next(onResumeReading: @Sendable () -> Void = {}) async throws -> ByteBuffer? {
        var shouldResumeReading = false
        defer {
            if shouldResumeReading { onResumeReading() }
        }
        return try await withCheckedThrowingContinuation { continuation in
            state.withLockedValue { state in
                if state.headIndex < state.chunks.count {
                    let chunk = state.chunks[state.headIndex]
                    state.headIndex += 1
                    state.queuedBytes = max(0, state.queuedBytes - chunk.readableBytes)
                    if state.headIndex == state.chunks.count {
                        state.chunks.removeAll(keepingCapacity: true)
                        state.headIndex = 0
                    } else if state.headIndex >= 64 {
                        state.chunks.removeSubrange(..<state.headIndex)
                        state.headIndex = 0
                    }
                    if state.isReadingPaused, state.queuedBytes <= Self.lowWatermark {
                        state.isReadingPaused = false
                        shouldResumeReading = true
                    }
                    continuation.resume(returning: chunk)
                } else if let completion = state.completion {
                    switch completion {
                    case .finished: continuation.resume(returning: nil)
                    case .failed(let error): continuation.resume(throwing: error)
                    }
                } else {
                    state.waiter = continuation
                }
            }
        }
    }
}

/// Dernier handler du pipeline : pousse les octets reçus dans l'``InboundBuffer``
/// et suspend `autoRead` lorsque le tampon atteint sa limite haute.
final class InboundBufferHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let buffer: InboundBuffer

    init(buffer: InboundBuffer) {
        self.buffer = buffer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if buffer.push(unwrapInboundIn(data)) {
            _ = context.channel.setOption(ChannelOptions.autoRead, value: false)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        buffer.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        // Beaucoup de serveurs FTPS ferment le canal de données sans `close_notify` :
        // on le traite comme une fin de flux normale.
        if case NIOSSLError.uncleanShutdown? = error as? NIOSSLError {
            buffer.finish()
        } else {
            buffer.fail(RemoteError.connectionFailed(String(describing: error)))
        }
        context.close(promise: nil)
    }
}
