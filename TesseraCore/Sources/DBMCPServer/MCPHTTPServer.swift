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
        channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
        self.port = port
        isRunning = true
    }

    public func stop() async {
        if let channel { try? await channel.close() }
        channel = nil
        isRunning = false
    }
}

/// Parses one request, checks the token, and writes the JSON-RPC reply.
private final class MCPRequestHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let token: String
    private let handler: MCPHTTPServer.Handler

    private var head: HTTPRequestHead?
    private var body: ByteBuffer?

    init(token: String, handler: @escaping MCPHTTPServer.Handler) {
        self.token = token
        self.handler = handler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body = nil
        case .body(var chunk):
            if body == nil { body = chunk }
            else { body!.writeBuffer(&chunk) }
        case .end:
            guard let head else { return }
            let payload = body.map { Data($0.readableBytesView) } ?? Data()
            respond(context: context, head: head, payload: payload)
            self.head = nil
            body = nil
        }
    }

    private func respond(context: ChannelHandlerContext, head: HTTPRequestHead, payload: Data) {
        // A browser always sends Origin on cross-origin fetches; a real MCP client
        // never does. Refusing it stops a malicious page from driving this server.
        if head.headers.contains(name: "Origin") {
            return write(context: context, status: .forbidden,
                         json: #"{"error":"Browser requests are not accepted."}"#)
        }
        let authorization = head.headers.first(name: "Authorization") ?? ""
        guard authorization == "Bearer \(token)" else {
            return write(context: context, status: .unauthorized,
                         json: #"{"error":"Missing or invalid bearer token."}"#)
        }
        guard head.method == .POST else {
            return write(context: context, status: .methodNotAllowed,
                         json: #"{"error":"Use POST with a JSON-RPC body."}"#)
        }

        let loop = context.eventLoop
        let box = NIOLoopBound(context, eventLoop: loop)
        let handler = self.handler
        Task {
            let reply = await handler(payload)
            loop.execute {
                // A notification has no reply; acknowledge it with 202.
                guard let reply else {
                    self.write(context: box.value, status: .accepted, body: Data())
                    return
                }
                self.write(context: box.value, status: .ok, body: reply)
            }
        }
    }

    private func write(context: ChannelHandlerContext, status: HTTPResponseStatus, json: String) {
        write(context: context, status: status, body: Data(json.utf8))
    }

    private func write(context: ChannelHandlerContext, status: HTTPResponseStatus, body: Data) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: String(body.count))
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}
