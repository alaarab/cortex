import Crypto
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSH
import PhrenKit

public enum LiveConnectionError: LocalizedError, Equatable {
    case untrustedHost(String)
    case changedHost
    case authentication
    case timeout
    case disconnected
    case response(Int)
    case oversized

    public var errorDescription: String? {
        switch self {
        case .untrustedHost: return "Verify this computer's SSH fingerprint before connecting."
        case .changedHost: return "This computer's SSH host key has changed. The connection was stopped. Verify the computer before removing and adding this connection again."
        case .authentication: return "SSH did not accept this device's key. Add the public key to the selected user's authorized_keys file and enable Remote Login or SSH."
        case .timeout: return "The connection timed out. Check Tailscale, SSH, and that moshi-hook is running."
        case .disconnected: return "The connection closed before session status arrived. Check that moshi-hook is running and SSH forwarding is allowed."
        case .response(let status): return "The Moshi hook returned HTTP \(status). Check or update moshi-hook on the computer."
        case .oversized: return "The Moshi hook response exceeded the 1 MB limit."
        }
    }
}

/// One bounded, cancellable read. No shell, remote commands, local listener,
/// redirects, approval actions, or arbitrary gateway routes are exposed.
public enum MoshiConnection {
    public static func fetch(host: LiveHost, privateKey: Data) async throws -> MoshiWorkspaces {
        try host.validate()
        let data = try await fetchData(host: host, key: Curve25519.Signing.PrivateKey(rawRepresentation: privateKey))
        try Task.checkCancellation()
        return try MoshiWorkspaces.read(data)
    }

    static func fetchData(host: LiveHost, key: Curve25519.Signing.PrivateKey) async throws -> Data {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let result = loop.makePromise(of: Data.self)
        let exchange = Exchange(result: result)
        // All Exchange access is confined to this event loop, including cancel.
        let deadline = loop.scheduleTask(in: .seconds(20)) { exchange.finish(.failure(LiveConnectionError.timeout)) }
        result.futureResult.whenComplete { _ in
            deadline.cancel()
            exchange.parent?.close(promise: nil)
        }
        let bootstrap = ClientBootstrap(group: loop).connectTimeout(.seconds(10)).channelInitializer { channel in
            exchange.parent = channel
            guard !exchange.finished else { return channel.close() }
            return channel.eventLoop.makeCompletedFuture {
                let ssh = NIOSSHHandler(
                    role: .client(.init(
                        userAuthDelegate: DeviceAuthentication(username: host.username, key: key, exchange: exchange),
                        serverAuthDelegate: PinnedHost(fingerprint: host.fingerprint)
                    )), allocator: channel.allocator,
                    inboundChildChannelInitializer: { channel, _ in
                        channel.eventLoop.makeFailedFuture(LiveConnectionError.disconnected)
                    })
                try channel.pipeline.syncOperations.addHandlers(ssh, GatewayChannel(exchange: exchange))
            }
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            bootstrap.connect(host: host.address, port: host.port).whenFailure { exchange.finish(.failure($0)) }
            return try await result.futureResult.get()
        } onCancel: {
            loop.execute { exchange.finish(.failure(CancellationError())) }
        }
    }

    public static func fingerprint(publicKey: String) -> String? {
        let fields = publicKey.split(separator: " ")
        guard fields.count >= 2, let data = Data(base64Encoded: String(fields[1])) else { return nil }
        return "SHA256:" + Data(SHA256.hash(data: data)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

// NIO callbacks and cancellations are serialized onto the owning event loop.
final class Exchange: @unchecked Sendable {
    let result: EventLoopPromise<Data>
    var parent: Channel?
    private(set) var finished = false
    init(result: EventLoopPromise<Data>) { self.result = result }
    func finish(_ value: Result<Data, Error>) {
        guard !finished else { return }
        finished = true
        result.completeWith(value)
    }
}

final class PinnedHost: NIOSSHClientServerAuthenticationDelegate {
    let fingerprint: String?
    init(fingerprint: String?) { self.fingerprint = fingerprint }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        guard let received = MoshiConnection.fingerprint(publicKey: String(openSSHPublicKey: hostKey)) else {
            validationCompletePromise.fail(LiveConnectionError.changedHost)
            return
        }
        guard let fingerprint else {
            validationCompletePromise.fail(LiveConnectionError.untrustedHost(received))
            return
        }
        if fingerprint == received { validationCompletePromise.succeed(()) }
        else { validationCompletePromise.fail(LiveConnectionError.changedHost) }
    }
}

private final class DeviceAuthentication: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let key: Curve25519.Signing.PrivateKey
    let exchange: Exchange
    var offered = false
    init(username: String, key: Curve25519.Signing.PrivateKey, exchange: Exchange) {
        self.username = username; self.key = key; self.exchange = exchange
    }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !offered, availableMethods.contains(.publicKey) else {
            nextChallengePromise.succeed(nil)
            exchange.finish(.failure(LiveConnectionError.authentication))
            return
        }
        offered = true
        nextChallengePromise.succeed(.init(username: username, serviceName: "ssh-connection",
            offer: .privateKey(.init(privateKey: .init(ed25519Key: key)))))
    }
}

private final class GatewayChannel: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let exchange: Exchange
    init(exchange: Exchange) { self.exchange = exchange }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard event is UserAuthSuccessEvent, !exchange.finished else { return }
        do {
            let ssh = try context.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
            let child = context.eventLoop.makePromise(of: Channel.self)
            child.futureResult.whenFailure { [exchange] in exchange.finish(.failure($0)) }
            let target = SSHChannelType.DirectTCPIP(targetHost: "127.0.0.1", targetPort: 24543,
                originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0))
            ssh.createChannel(child, channelType: .directTCPIP(target)) { [exchange] channel, type in
                guard case .directTCPIP = type else {
                    return channel.eventLoop.makeFailedFuture(LiveConnectionError.disconnected)
                }
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers(
                        SSHHTTPBytes(), HTTPRequestEncoder(),
                        ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .dropBytes)),
                        GatewayResponse(exchange: exchange))
                }
            }
        } catch { exchange.finish(.failure(error)) }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { exchange.finish(.failure(error)) }
    func channelInactive(context: ChannelHandlerContext) { exchange.finish(.failure(LiveConnectionError.disconnected)) }
}

/// HTTPRequestEncoder emits IOData, while the SSH child expects SSHChannelData.
private final class SSHHTTPBytes: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = IOData
    typealias OutboundOut = SSHChannelData
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard message.type == .channel, case .byteBuffer(let bytes) = message.data else {
            context.fireErrorCaught(LiveConnectionError.disconnected); return
        }
        context.fireChannelRead(wrapInboundOut(bytes))
    }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(wrapOutboundOut(.init(type: .channel, data: unwrapOutboundIn(data))), promise: promise)
    }
}

final class GatewayResponse: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart
    let exchange: Exchange
    private var body = Data()
    private var receivedHead = false
    init(exchange: Exchange) { self.exchange = exchange }
    func channelActive(context: ChannelHandlerContext) {
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/v1/workspaces",
            headers: HTTPHeaders([("Host", "127.0.0.1:24543"), ("Accept", "application/json"), ("Connection", "close")]))
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenFailure { [exchange] in exchange.finish(.failure($0)) }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !exchange.finished else { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            guard !receivedHead, head.status.code == 200 else {
                exchange.finish(.failure(LiveConnectionError.response(Int(head.status.code)))); return
            }
            receivedHead = true
            if let length = head.headers.first(name: "content-length"), let size = Int(length), size > 1_048_576 {
                exchange.finish(.failure(LiveConnectionError.oversized))
            }
        case .body(let bytes):
            guard receivedHead, body.count + bytes.readableBytes <= 1_048_576 else {
                exchange.finish(.failure(LiveConnectionError.oversized)); return
            }
            body.append(contentsOf: bytes.readableBytesView)
        case .end:
            exchange.finish(receivedHead ? .success(body) : .failure(LiveConnectionError.disconnected))
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { exchange.finish(.failure(error)) }
    func channelInactive(context: ChannelHandlerContext) { exchange.finish(.failure(LiveConnectionError.disconnected)) }
}
