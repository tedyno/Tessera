import XCTest
@testable import DBMCPServer

/// Exercises the transport's security boundary over a real loopback socket: this is
/// the one place an outside caller touches the process, so the checks are asserted
/// end to end rather than in isolation.
final class MCPHTTPServerTests: XCTestCase {
    private let token = "test-token"
    private var server: MCPHTTPServer!
    private var port: Int = 0

    /// Set when the JSON-RPC handler runs, so tests can prove a refused request
    /// never reached it.
    private let handled = Handled()

    final class Handled: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var didRun: Bool { lock.withLock { value } }
        func mark() { lock.withLock { value = true } }
    }

    override func setUp() async throws {
        server = MCPHTTPServer()
        let handled = self.handled
        try await server.start(port: 0, token: token) { payload in
            handled.mark()
            return payload.isEmpty ? nil : Data(#"{"ok":true}"#.utf8)
        }
        port = await server.port
    }

    override func tearDown() async throws {
        await server.stop()
        server = nil
    }

    // MARK: Helpers

    private func send(method: String = "POST",
                      headers: [String: String],
                      body: Data = Data(#"{"jsonrpc":"2.0"}"#.utf8)) async throws -> HTTPURLResponse {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.timeoutInterval = 20
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return try XCTUnwrap(response as? HTTPURLResponse)
    }

    private var auth: [String: String] { ["Authorization": "Bearer \(token)"] }

    // MARK: Tests

    func testValidRequestIsHandled() async throws {
        let response = try await send(headers: auth)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(handled.didRun)
    }

    func testMissingTokenIsRefused() async throws {
        let response = try await send(headers: [:])
        XCTAssertEqual(response.statusCode, 401)
        XCTAssertFalse(handled.didRun)
    }

    func testWrongTokenIsRefused() async throws {
        let response = try await send(headers: ["Authorization": "Bearer nope"])
        XCTAssertEqual(response.statusCode, 401)
        XCTAssertFalse(handled.didRun)
    }

    /// A web page can guess the port, so Origin is refused even with a valid token.
    func testBrowserRequestIsRefusedEvenWithToken() async throws {
        let response = try await send(headers: auth.merging(["Origin": "https://evil.example"]) { $1 })
        XCTAssertEqual(response.statusCode, 403)
        XCTAssertFalse(handled.didRun)
    }

    func testNonPostIsRefused() async throws {
        let response = try await send(method: "GET", headers: auth, body: Data())
        XCTAssertEqual(response.statusCode, 405)
        XCTAssertFalse(handled.didRun)
    }

    /// An authenticated caller still can't hand us an unbounded body.
    func testOversizedBodyIsRefused() async throws {
        let response = try await send(headers: auth, body: Data(repeating: 0x20, count: 9 * 1024 * 1024))
        XCTAssertEqual(response.statusCode, 413)
        XCTAssertFalse(handled.didRun)
    }

    /// The important half of the fix: a caller without a token can send a large body
    /// and it is drained, not buffered — the refusal still comes back promptly.
    func testUnauthenticatedLargeBodyIsRefusedNotBuffered() async throws {
        let response = try await send(headers: [:], body: Data(repeating: 0x20, count: 9 * 1024 * 1024))
        XCTAssertEqual(response.statusCode, 401)
        XCTAssertFalse(handled.didRun)
    }
}
