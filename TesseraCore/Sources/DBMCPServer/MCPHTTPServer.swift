import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

/// A minimal HTTP transport for the MCP server. It binds to **127.0.0.1 only**, so
/// nothing outside this Mac can reach it, and every request must carry the bearer
/// token. Requests that look like they came from a web page are refused outright.
public actor MCPHTTPServer {
    /// Handles one JSON-RPC body and returns the reply (nil for notifications).
    public typealias Handler = @Sendable (Data) async -> Data?

    private var channel: Channel?
    private let group: MultiThreadedEventLoopGroup = .singleton

    public private(set) var isRunning = false
    public private(set) var port: Int = 0

    public init() {}

    public func start(port: Int, token: String, handler: @escaping Handler) async throws {
        await stop()
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(MCPRequestHandler(token: token, handler: handler))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        // Loopback only — never 0.0.0.0.
        let bound = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
        channel = bound
        // Port 0 means "pick one" — report what we actually got.
        self.port = bound.localAddress?.port ?? port
        isRunning = true
    }

    public func stop() async {
        if let channel { try? await channel.close() }
        channel = nil
        isRunning = false
    }
}

/// Parses one request, checks the token, and writes the JSON-RPC reply.
///
/// State is only ever touched on the channel's event loop, which is why the
/// `@unchecked Sendable` conformance is safe.
private final class MCPRequestHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    /// A JSON-RPC call is small; anything larger is a mistake or an attack. The cap
    /// matters because an unauthenticated caller reaches this buffer.
    private static let maxBodyBytes = 8 * 1024 * 1024

    private let token: String
    private let handler: MCPHTTPServer.Handler

    private var body: ByteBuffer?
    private var keepAlive = true
    /// Set as soon as the request is known to be refusable. The body is then
    /// discarded rather than buffered, so a caller without a token can never make
    /// this process hold their payload in memory.
    private var rejection: (status: HTTPResponseStatus, message: String)?

    init(token: String, handler: @escaping MCPHTTPServer.Handler) {
        self.token = token
        self.handler = handler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            body = nil
            keepAlive = head.isKeepAlive
            rejection = refusal(for: head)
        case .body(var chunk):
            // Refused requests are drained, never accumulated.
            guard rejection == nil else { return }
            if body == nil { body = chunk } else { body!.writeBuffer(&chunk) }
            if body!.readableBytes > Self.maxBodyBytes {
                body = nil
                rejection = (.payloadTooLarge, "Request body is too large.")
            }
        case .end:
            let payload = body.map { Data($0.readableBytesView) } ?? Data()
            body = nil
            if let rejection {
                self.rejection = nil
                // Never keep a refused connection alive.
                write(channel: context.channel, status: rejection.status,
                      body: Data(#"{"error":"\#(rejection.message)"}"#.utf8), close: true)
            } else {
                dispatch(channel: context.channel, payload: payload)
            }
        }
    }

    /// Everything that can be judged from the request head alone.
    private func refusal(for head: HTTPRequestHead) -> (HTTPResponseStatus, String)? {
        // A browser always sends Origin on cross-origin fetches; a real MCP client
        // never does. Refusing it stops a malicious page from driving this server.
        if head.headers.contains(name: "Origin") {
            return (.forbidden, "Browser requests are not accepted.")
        }
        guard head.headers.first(name: "Authorization") == "Bearer \(token)" else {
            return (.unauthorized, "Missing or invalid bearer token.")
        }
        guard head.method == .POST else {
            return (.methodNotAllowed, "Use POST with a JSON-RPC body.")
        }
        return nil
    }

    private func dispatch(channel: Channel, payload: Data) {
        let handler = self.handler
        let keepAlive = self.keepAlive
        // A query can run for a while and the client may hang up meanwhile, so the
        // reply is written to the channel — a context is not valid across the hop.
        Task {
            let reply = await handler(payload)
            channel.eventLoop.execute {
                // A notification has no reply; acknowledge it with 202.
                self.write(channel: channel, status: reply == nil ? .accepted : .ok,
                           body: reply ?? Data(), close: !keepAlive)
            }
        }
    }

    private func write(channel: Channel, status: HTTPResponseStatus, body: Data, close: Bool) {
        guard channel.isActive else { return }   // client hung up
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: String(body.count))
        if close { headers.add(name: "Connection", value: "close") }
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        channel.write(HTTPServerResponsePart.head(head), promise: nil)
        var buffer = channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        let done = channel.writeAndFlush(HTTPServerResponsePart.end(nil))
        if close { done.whenComplete { _ in channel.close(promise: nil) } }
    }
}
