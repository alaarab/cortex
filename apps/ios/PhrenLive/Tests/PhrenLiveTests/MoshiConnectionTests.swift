import Crypto
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import NIOSSH
import PhrenKit
import XCTest
@testable import PhrenLive

final class MoshiConnectionTests: XCTestCase {
    func testAuthenticatedLoopbackReadAndParentCloses() async throws {
        let server = try await TestSSHServer.start()
        addTeardownBlock { try await server.close() }
        let result = try await MoshiConnection.fetch(host: server.host(), privateKey: server.deviceKey.rawRepresentation)
        XCTAssertEqual(result.groups.first?.children.first?.status, "Working")
        let request = try await server.request.futureResult.get()
        XCTAssertTrue(request.hasPrefix("GET /v1/workspaces HTTP/1.1\r\n"))
        XCTAssertTrue(request.contains("Host: 127.0.0.1:24543\r\n"))
        try await server.disconnected.futureResult.get()
    }

    func testUntrustedAndChangedKeysStopBeforeAuthentication() async throws {
        for changed in [false, true] {
            let server = try await TestSSHServer.start()
            addTeardownBlock { try await server.close() }
            var host = try server.host()
            host.fingerprint = changed ? "SHA256:" + String(repeating: "A", count: 43) : nil
            do {
                _ = try await MoshiConnection.fetch(host: host, privateKey: server.deviceKey.rawRepresentation)
                XCTFail("An unverified host must not connect")
            } catch let error as LiveConnectionError {
                XCTAssertEqual(error, changed ? .changedHost : .untrustedHost(try server.host().fingerprint!))
            }
            let offers = try await server.channel.eventLoop.submit { server.auth.offers }.get()
            XCTAssertEqual(offers, 0)
            try await server.disconnected.futureResult.get()
        }
    }

    func testRejectedDeviceKeyAndCancellationCloseSocket() async throws {
        let rejecting = try await TestSSHServer.start()
        addTeardownBlock { try await rejecting.close() }
        do {
            _ = try await MoshiConnection.fetch(host: rejecting.host(), privateKey: Curve25519.Signing.PrivateKey().rawRepresentation)
            XCTFail("Wrong key must fail")
        } catch { XCTAssertEqual(error as? LiveConnectionError, .authentication) }
        try await rejecting.disconnected.futureResult.get()

        let slow = try await TestSSHServer.start(respond: false)
        addTeardownBlock { try await slow.close() }
        let task = Task { try await MoshiConnection.fetch(host: slow.host(), privateKey: slow.deviceKey.rawRepresentation) }
        _ = try await slow.request.futureResult.get()
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled read must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await slow.disconnected.futureResult.get()
    }

    func testResponsesRejectRedirectsAndBoundStreamingBodies() throws {
        for status in [HTTPResponseStatus.found, .ok] {
            let loop = EmbeddedEventLoop()
            let promise = loop.makePromise(of: Data.self)
            let exchange = Exchange(result: promise)
            let channel = EmbeddedChannel(handler: GatewayResponse(exchange: exchange), loop: loop)
            try channel.writeInbound(HTTPClientResponsePart.head(.init(version: .http1_1, status: status)))
            if status == .ok {
                for _ in 0..<17 {
                    try channel.writeInbound(HTTPClientResponsePart.body(ByteBuffer(bytes: repeatElement(UInt8(0), count: 65536))))
                }
            }
            XCTAssertThrowsError(try promise.futureResult.wait()) { error in
                XCTAssertEqual(error as? LiveConnectionError, status == .ok ? .oversized : .response(302))
            }
            _ = try channel.finish()
        }
    }

    func testPublicAuthorizationLineContainsOnlyPublicKeyAndForwardRestriction() throws {
        let key = Curve25519.Signing.PrivateKey()
        let line = DeviceSSHKey.authorizedKey(privateKey: key)
        XCTAssertTrue(line.hasPrefix("restrict,port-forwarding,permitopen=\"127.0.0.1:24543\",command=\"/usr/bin/false\" ssh-ed25519 "))
        XCTAssertFalse(line.contains(key.rawRepresentation.base64EncodedString()))
        XCTAssertNotNil(MoshiConnection.fingerprint(publicKey: String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey)))
    }

    /// Opt in locally; never requires a running hook in CI and never prints or
    /// saves the host's private project names or session metadata.
    func testInstalledHookContractWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["PHREN_TEST_MOSHI_HOOK"] == "1" else {
            throw XCTSkip("Optional installed moshi-hook contract check")
        }
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:24543/v1/workspaces")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        _ = try MoshiWorkspaces.read(data)
    }
}

private final class TestAuth: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
    let publicKey: NIOSSHPublicKey
    var offers = 0 // server event loop only
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .publicKey }
    init(key: Curve25519.Signing.PrivateKey) { publicKey = NIOSSHPrivateKey(ed25519Key: key).publicKey }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        offers += 1
        if request.username == "fixture", case .publicKey(let key) = request.request, key.publicKey == publicKey {
            responsePromise.succeed(.success)
        } else { responsePromise.succeed(.failure) }
    }
}

private final class TestSSHServer: @unchecked Sendable {
    let deviceKey: Curve25519.Signing.PrivateKey
    let hostKey: Curve25519.Signing.PrivateKey
    let auth: TestAuth
    let channel: Channel
    let request: EventLoopPromise<String>
    let disconnected: EventLoopPromise<Void>
    init(deviceKey: Curve25519.Signing.PrivateKey, hostKey: Curve25519.Signing.PrivateKey, auth: TestAuth,
         channel: Channel, request: EventLoopPromise<String>, disconnected: EventLoopPromise<Void>) {
        self.deviceKey = deviceKey; self.hostKey = hostKey; self.auth = auth
        self.channel = channel; self.request = request; self.disconnected = disconnected
    }
    func host() throws -> LiveHost {
        try LiveHost(name: "Fixture", address: "127.0.0.1", port: channel.localAddress!.port!, username: "fixture",
            fingerprint: MoshiConnection.fingerprint(publicKey: String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: hostKey).publicKey)))
    }
    static func start(respond: Bool = true) async throws -> TestSSHServer {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let hostKey = Curve25519.Signing.PrivateKey()
        let deviceKey = Curve25519.Signing.PrivateKey()
        let auth = TestAuth(key: deviceKey)
        let request = loop.makePromise(of: String.self)
        let disconnected = loop.makePromise(of: Void.self)
        let channel = try await ServerBootstrap(group: loop).childChannelInitializer { channel in
            channel.closeFuture.cascade(to: disconnected)
            return channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                role: .server(.init(hostKeys: [.init(ed25519Key: hostKey)], userAuthDelegate: auth)),
                allocator: channel.allocator, inboundChildChannelInitializer: { child, type in
                    guard case .directTCPIP(let target) = type,
                          target.targetHost == "127.0.0.1", target.targetPort == 24543 else {
                        return child.eventLoop.makeFailedFuture(LiveConnectionError.disconnected)
                    }
                    return child.pipeline.addHandler(TestGateway(request: request, respond: respond))
                }))
            }
        }.bind(host: "127.0.0.1", port: 0).get()
        return TestSSHServer(deviceKey: deviceKey, hostKey: hostKey, auth: auth, channel: channel,
                             request: request, disconnected: disconnected)
    }
    func close() async throws {
        // Tests await the client's parent close before tearing down the listener.
        request.fail(CancellationError())
        try await channel.close()
    }
}

private final class TestGateway: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    let request: EventLoopPromise<String>
    let respond: Bool
    var received = ""
    var handled = false
    init(request: EventLoopPromise<String>, respond: Bool) { self.request = request; self.respond = respond }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .byteBuffer(let buffer) = unwrapInboundIn(data).data, !handled else { return }
        received += String(decoding: buffer.readableBytesView, as: UTF8.self)
        guard received.contains("\r\n\r\n") else { return }
        handled = true
        request.succeed(received)
        guard respond else { return }
        let body = #"{"kind":"herdr","groups":[{"id":"w1","label":"Project","children":[{"id":"w1:t1","label":"Build","agentStatus":"working"}]}]}"#
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        context.writeAndFlush(wrapOutboundOut(.init(type: .channel, data: .byteBuffer(ByteBuffer(string: response)))), promise: nil)
    }
}
