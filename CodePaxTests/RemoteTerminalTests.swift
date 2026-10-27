import XCTest
import SwiftTerm
import Citadel
import NIOCore
import NIOPosix
import NIOSSH
@testable import CodePax

final class RemoteTerminalTests: XCTestCase {
    func testDimensionsAndProjectDirectoryDoNotAllowControlCharactersIntoShellInput() {
        XCTAssertEqual(TerminalDimensions(columns: 0, rows: -1), TerminalDimensions(columns: 2, rows: 1))
        XCTAssertEqual(TerminalDimensions(columns: 9000, rows: 9000), TerminalDimensions(columns: 500, rows: 250))
        let command = TerminalPolicy.startDirectoryCommand("/project/it's a test;$(touch nope)")
        XCTAssertEqual(command, "cd -- "+RemoteShell.quote("/project/it's a test;$(touch nope)")+"\r")
        for path in ["/project/a\nb", "/project/a\rb", "/project/a\u{1b}b", ""] {
            XCTAssertNil(TerminalPolicy.startDirectoryCommand(path))
        }
        XCTAssertNil(TerminalPolicy.startDirectoryCommand(nil))
    }

    func testOutputKeepsSplitUnicodeScalarsWithoutChangingANSIEscapeBytes() {
        var output = TerminalOutputBuffer()
        XCTAssertEqual(output.append([0xe4]), [])
        XCTAssertEqual(output.append([0xb8]), [])
        XCTAssertEqual(output.append([0xad, 0xe6, 0x96]), [0xe4, 0xb8, 0xad])
        XCTAssertEqual(output.append([0x87, 0x1b, 0x5b]), [0xe6, 0x96, 0x87, 0x1b, 0x5b])
        XCTAssertEqual(output.append(Array("32m".utf8)), Array("32m".utf8))
        XCTAssertEqual(output.append([0xf0, 0x9f, 0x98]), [])
        XCTAssertEqual(output.append([0x80]), [0xf0, 0x9f, 0x98, 0x80])
        XCTAssertEqual(output.append([0xff]), [0xff])
    }

    @MainActor
    func testPTYStreamsUTF8AndControlKeysResizesAndClosesWithoutClosingSharedSSH() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let hostKey = NIOSSHPrivateKey(p521Key: .init())
        let listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.pipeline.addHandler(NIOSSHHandler(
                role: .server(.init(hostKeys: [hostKey], userAuthDelegate: TerminalTestAuthentication())),
                allocator: channel.allocator,
                inboundChildChannelInitializer: { child, _ in child.pipeline.addHandler(TerminalTestChannel()) }))
        }.bind(host: "127.0.0.1", port: 0).get()
        let port = try XCTUnwrap(listener.localAddress?.port)
        do {
            let client = try await SSHClient.connect(host: "127.0.0.1", port: port,
                authenticationMethod: .passwordBased(username: "terminal-test", password: "test-only"),
                hostKeyValidator: .trustedKeys([hostKey.publicKey]), reconnect: .never)
            do {
                let transport = TerminalTestConnection(client: client)
                let model = RemoteTerminalModel(connection: transport)
                let view = model.terminal
                defer { model.stop() }
                model.start(directory: "/project/a b")
                try await waitFor { model.state == .running || model.state == .failed }
                XCTAssertEqual(model.state, .running, model.error ?? "")
                try await waitFor { buffer(model).contains("cd --") }
                model.sendBytes([0xe4]); model.sendBytes([0xb8, 0xad, 0xe6, 0x96, 0x87])
                model.sendKey("\r")
                model.sendKey("\u{03}")
                model.sizeChanged(source: view, newCols: 120, newRows: 40)
                try await waitFor { buffer(model).contains("SIZE:120x40") }
                XCTAssertTrue(buffer(model).contains("中文"), String(buffer(model).prefix(600)))
                XCTAssertTrue(buffer(model).contains("CTRL-C"))
                model.startIfNeeded(directory: "/must-not-restart")
                XCTAssertTrue(model.terminal === view)
                XCTAssertTrue(buffer(model).contains("中文"), String(buffer(model).prefix(600)))
                model.stop()
                XCTAssertEqual(model.state, .ended)
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertTrue(client.isConnected)
                let output = try await client.executeCommand("test-after-terminal", maxResponseSize: 1024)
                XCTAssertTrue(String(decoding: output.readableBytesView, as: UTF8.self).contains("EXEC_OK"))
                model.start(directory: nil)
                try await waitFor { model.state == .running }
                model.stop(disconnected: true)
                XCTAssertEqual(model.state, .disconnected)
                let before = buffer(model)
                model.sendKey("must-not-be-sent")
                XCTAssertEqual(buffer(model), before)
                try await client.close()
            } catch { try? await client.close(); throw error }
            try await listener.close().get()
            try await group.shutdownGracefully()
        } catch {
            try? await listener.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @MainActor private func buffer(_ model: RemoteTerminalModel) -> String {
        String(decoding: model.terminal.getTerminal().getBufferAsData(), as: UTF8.self).replacingOccurrences(of: "\0", with: "")
    }
    @MainActor private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<160 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "TerminalTestTimeout", code: 1)
    }
}

@MainActor
private final class TerminalTestConnection: TerminalConnection {
    let client: SSHClient
    init(client: SSHClient) { self.client = client }
    var isConnected: Bool { client.isConnected }
    func withTerminal(dimensions: TerminalDimensions,
                      perform: @MainActor (TTYOutput, TTYStdinWriter) async throws -> Void) async throws {
        try await client.withPTY(TerminalPolicy.request(dimensions)) { input, output in try await perform(input, output) }
    }
}
private struct TerminalTestAuthentication: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .password
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        if case .password(let value) = request.request, request.username == "terminal-test", value.password == "test-only" {
            responsePromise.succeed(.success)
        } else { responsePromise.succeed(.failure) }
    }
}
private final class TerminalTestChannel: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let request as SSHChannelRequestEvent.PseudoTerminalRequest:
            if request.wantReply { context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
        case let request as SSHChannelRequestEvent.ShellRequest:
            if request.wantReply { context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
            output("\u{1b}[32mREADY\u{1b}[0m\r\n", context)
        case let size as SSHChannelRequestEvent.WindowChangeRequest:
            output("\r\nSIZE:\(size.terminalCharacterWidth)x\(size.terminalRowHeight)\r\n", context)
        case is SSHChannelRequestEvent.ExecRequest:
            context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            context.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(string: "EXEC_OK\r\n")))))
                .flatMap { context.channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 0)) }
                .whenComplete { _ in context.close(promise: nil) }
        default: context.fireUserInboundEventTriggered(event)
        }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let packet = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = packet.data else { return }
        if buffer.readableBytesView.contains(3) { output("\r\nCTRL-C\r\n", context) }
        else { context.writeAndFlush(NIOAny(packet), promise: nil) }
    }
    private func output(_ text: String, _ context: ChannelHandlerContext) {
        context.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(string: text)))), promise: nil)
    }
}
