import Foundation
import DBKit
import NIOCore
import NIOPosix
import NIOSSL

/// Redis implementation of `DatabaseDriver` plus the key-value API the browser
/// uses. `execute` treats its "SQL" as a redis-cli command line — the console
/// tab is a Redis CLI. Hand-rolled RESP2 over NIO; one connection per session,
/// serialized the same way as the MySQL driver.
public actor RedisDriver: DatabaseDriver, KeyValueDriver {
    private var channel: Channel?
    private var handler: RESPClientHandler?
    private var databaseIndex = 0
    private var serverVersionString: String?

    // Serializes command batches: actor reentrancy would otherwise interleave
    // two multi-command operations (e.g. a SCAN page's TYPE/TTL pipeline).
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    private func lock() async {
        while busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
    }

    private func unlock() {
        busy = false
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    // MARK: Connect / close

    public func connect(profile: ConnectionProfile, secrets: Secrets,
                        endpoint: NetworkEndpoint) async throws {
        await close()
        let handler = RESPClientHandler()
        // Redis has no STARTTLS: the socket speaks TLS from byte one or not at
        // all, so `prefer` cannot negotiate and stays plain (the common case —
        // Tessera's Redis connections usually ride an SSH tunnel anyway).
        let tls: NIOSSLContext?
        switch profile.tlsMode {
        case .disable, .prefer:
            tls = nil
        case .require, .verifyCA, .verifyFull:
            var configuration = TLSConfiguration.makeClientConfiguration()
            configuration.certificateVerification = switch profile.tlsMode {
            case .require: .none
            case .verifyCA: .noHostnameVerification
            default: .fullVerification
            }
            do {
                tls = try NIOSSLContext(configuration: configuration)
            } catch {
                // Never downgrade silently: the user demanded TLS, so a setup
                // failure is a connection failure, not a plaintext fallback.
                throw DatabaseError.connectionFailed("TLS setup failed: \(error)")
            }
        }
        // SNI wants the certificate's name (the profile host, not the tunnel
        // endpoint) — and must be nil for IP literals, which SNI cannot carry.
        // Only actual dotted-quad / IPv6 shapes count; an all-hex *hostname*
        // like "abc" still gets SNI.
        let isIPLiteral = profile.host.contains(":")
            || profile.host.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#,
                                  options: .regularExpression) != nil
        let serverHostname = isIPLiteral ? nil : profile.host
        do {
            let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .connectTimeout(.seconds(10))
                .channelInitializer { channel in
                    do {
                        if let tls {
                            let ssl = try NIOSSLClientHandler(context: tls,
                                                              serverHostname: serverHostname)
                            try channel.pipeline.syncOperations.addHandler(ssl)
                        }
                        try channel.pipeline.syncOperations.addHandler(handler)
                        return channel.eventLoop.makeSucceededVoidFuture()
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                .connect(host: endpoint.host, port: endpoint.port)
                .get()
            self.channel = channel
            self.handler = handler
        } catch {
            throw DatabaseError.connectionFailed("Redis connect failed: \(error)")
        }

        do {
            // AUTH first (ACL user+password on Redis 6+, plain password before).
            if let password = secrets.databasePassword, !password.isEmpty {
                let auth = profile.username.isEmpty
                    ? ["AUTH", password]
                    : ["AUTH", profile.username, password]
                try check(await send(auth))
            }
            // The profile's "database" is the numeric db index (default 0).
            let index = try RedisDatabaseIndex.parse(profile.database)
            if index != 0 {
                try check(await send(["SELECT", String(index)]))
            }
            databaseIndex = index
            try check(await send(["PING"]))
            serverVersionString = try await fetchServerVersion()
        } catch let error as DatabaseError {
            await close()
            throw error
        } catch {
            await close()
            throw DatabaseError.connectionFailed("Redis handshake failed: \(error)")
        }
    }

    public func close() async {
        if let channel {
            try? await channel.close().get()
        }
        channel = nil
        handler = nil
    }

    // MARK: DatabaseDriver

    /// Commands this driver must refuse: subscriptions, MONITOR and the
    /// replication stream turn the connection into a push stream (desyncing
    /// FIFO reply matching for every later command), and blocking commands
    /// would hold the session's command lock forever with no way to cancel
    /// (`future.get()` isn't cancellable, and there is no second connection to
    /// CLIENT KILL from). Every blocking form has to be listed — missing one
    /// hangs the whole session, key browser included.
    private static let unsupportedCommands: Set<String> = [
        "SUBSCRIBE", "PSUBSCRIBE", "SSUBSCRIBE", "MONITOR", "SYNC", "PSYNC",
        "BLPOP", "BRPOP", "BLMOVE", "BLMPOP", "BRPOPLPUSH",
        "BZPOPMIN", "BZPOPMAX", "BZMPOP", "WAIT", "WAITAOF",
    ]

    private static func checkSupported(_ command: [String]) throws {
        let name = command[0].uppercased()
        if unsupportedCommands.contains(name) {
            throw DatabaseError.unsupported(
                "\(name) needs a dedicated connection and is not supported here.")
        }
        // XREAD/XREADGROUP are fine unless they BLOCK.
        if name == "XREAD" || name == "XREADGROUP",
           command.dropFirst().contains(where: { $0.uppercased() == "BLOCK" }) {
            throw DatabaseError.unsupported(
                "\(name) BLOCK would hang the session and is not supported here.")
        }
    }

    /// Executes one redis-cli style command line typed in the console.
    public func execute(_ sql: String, maxRows: Int?) async throws -> QueryResult {
        let tokens = RedisCommandLine.tokenize(sql)
        guard let command = tokens, !command.isEmpty else {
            throw DatabaseError.queryFailed(
                tokens == nil ? "Unbalanced quote in the command" : "Empty command")
        }
        try Self.checkSupported(command)
        await lock()
        defer { unlock() }
        let clock = ContinuousClock()
        let start = clock.now
        let reply = try await send(command)
        if case .error(let message) = reply {
            throw DatabaseError.queryFailed(message)
        }
        var result = RedisReplyDisplay.result(command: command, reply: reply, maxRows: maxRows)
        result.elapsed = clock.now - start
        return result
    }

    public func executeTransaction(_ statements: [String]) async throws {
        // MULTI/EXEC: queue every command, then run atomically — mirrors the
        // SQL drivers' BEGIN…COMMIT contract.
        let commands = try statements.map { statement -> [String] in
            guard let command = RedisCommandLine.tokenize(statement), !command.isEmpty else {
                throw DatabaseError.queryFailed("Unbalanced quote in the command")
            }
            try Self.checkSupported(command)
            return command
        }
        guard !commands.isEmpty else { return }
        await lock()
        defer { unlock() }
        try check(await send(["MULTI"]))
        do {
            for command in commands { try check(await send(command)) }
        } catch {
            _ = try? await send(["DISCARD"])
            throw error
        }
        try Self.checkExecReply(await send(["EXEC"]))
    }

    /// EXEC reports per-command failures *inside* its array rather than as a
    /// RESP error, and answers `*-1` when a WATCH made the transaction abort.
    /// Both mean the batch didn't apply, so both have to throw — the callers
    /// of a transaction take a return as "committed".
    static func checkExecReply(_ reply: RESPValue) throws {
        if case .error(let message) = reply { throw DatabaseError.queryFailed(message) }
        guard case .array(let results) = reply else { return }
        guard let results else {
            throw DatabaseError.queryFailed(
                "The transaction was aborted because a watched key changed.")
        }
        // Report the first failure: the rest are usually its consequences.
        for case .error(let message) in results {
            throw DatabaseError.queryFailed(message)
        }
    }

    /// The keyspace has no relational schema; the tree only names the database
    /// index so the sidebar header shows what the session points at.
    public func fetchSchema() async throws -> DatabaseTree {
        DatabaseTree(databaseName: "db\(databaseIndex)", schemas: [])
    }

    public func cancelRunningQuery() async {
        // Single-command execution over one connection: nothing long-running to
        // kill client-side. (CLIENT KILL needs a second connection; out of scope.)
    }

    public func serverVersion() async throws -> String {
        if let serverVersionString { return serverVersionString }
        throw DatabaseError.notConnected
    }

    // MARK: KeyValueDriver

    public func scanKeys(matching pattern: String, cursor: String,
                         count: Int) async throws -> (cursor: String, keys: [RedisKeyInfo]) {
        await lock()
        defer { unlock() }
        let reply = try await send(["SCAN", cursor, "MATCH", pattern.isEmpty ? "*" : pattern,
                                    "COUNT", String(count)])
        guard case .array(let parts?) = reply, parts.count == 2,
              let nextCursor = parts[0].displayText,
              case .array(let keyValues?) = parts[1] else {
            throw DatabaseError.queryFailed("Unexpected SCAN reply")
        }
        let names = keyValues.compactMap(\.displayText)
        // Pipeline TYPE + TTL for the whole page — one round trip.
        var batch: [[String]] = []
        for name in names {
            batch.append(["TYPE", name])
            batch.append(["TTL", name])
        }
        let replies = try await sendPipeline(batch)
        var keys: [RedisKeyInfo] = []
        keys.reserveCapacity(names.count)
        for (index, name) in names.enumerated() {
            let type = replies[index * 2].displayText ?? "unknown"
            var ttl: Int? = nil
            if case .integer(let seconds) = replies[index * 2 + 1], seconds >= 0 {
                ttl = Int(seconds)
            }
            keys.append(RedisKeyInfo(key: name, type: type, ttlSeconds: ttl))
        }
        try await addGlimpses(to: &keys)
        return (nextCursor, keys)
    }

    /// How many bytes of a string value the browser's preview column shows.
    private static let previewBytes = 120

    /// Second pipeline over a SCAN page (types now known): element counts for
    /// collections, byte length + first bytes for strings.
    private func addGlimpses(to keys: inout [RedisKeyInfo]) async throws {
        var batch: [[String]] = []
        // Which reply indices belong to which key, since kinds differ in arity.
        var slots: [(key: Int, replies: Range<Int>)] = []
        for (index, info) in keys.enumerated() {
            let start = batch.count
            switch info.type.lowercased() {
            case "string":
                batch.append(["STRLEN", info.key])
                batch.append(["GETRANGE", info.key, "0", String(Self.previewBytes - 1)])
            case "hash": batch.append(["HLEN", info.key])
            case "list": batch.append(["LLEN", info.key])
            case "set": batch.append(["SCARD", info.key])
            case "zset": batch.append(["ZCARD", info.key])
            case "stream": batch.append(["XLEN", info.key])
            default: continue
            }
            slots.append((index, start..<batch.count))
        }
        guard !batch.isEmpty else { return }
        let replies = try await sendPipeline(batch)
        for slot in slots {
            let first = replies[slot.replies.lowerBound]
            if case .integer(let count) = first { keys[slot.key].size = Int(count) }
            if slot.replies.count == 2,
               case .bulkString(let text?) = replies[slot.replies.lowerBound + 1] {
                let truncated = (keys[slot.key].size ?? 0) > Self.previewBytes
                keys[slot.key].preview = truncated ? text + "…" : text
            }
        }
    }

    public func deleteKeys(_ keys: [String]) async throws -> Int {
        guard !keys.isEmpty else { return 0 }
        await lock()
        defer { unlock() }
        let reply = try await send(["DEL"] + keys)
        guard case .integer(let count) = reply else {
            if case .error(let message) = reply { throw DatabaseError.queryFailed(message) }
            throw DatabaseError.queryFailed("Unexpected DEL reply")
        }
        return Int(count)
    }

    // MARK: Wire

    /// Throws when the reply is a RESP error; used for handshake commands.
    private func check(_ reply: RESPValue) throws {
        if case .error(let message) = reply {
            throw DatabaseError.queryFailed(message)
        }
    }

    private func send(_ command: [String]) async throws -> RESPValue {
        try await sendPipeline([command]).first ?? .bulkString(nil)
    }

    /// Writes all commands at once and awaits their replies in order.
    private func sendPipeline(_ commands: [[String]]) async throws -> [RESPValue] {
        guard let channel, let handler else { throw DatabaseError.notConnected }
        guard !commands.isEmpty else { return [] }
        var buffer = channel.allocator.buffer(capacity: 256)
        for command in commands {
            RESPCodec.encode(command: command, into: &buffer)
        }
        let futures = handler.expectReplies(count: commands.count, on: channel.eventLoop)
        channel.writeAndFlush(buffer, promise: nil)
        var replies: [RESPValue] = []
        replies.reserveCapacity(commands.count)
        for future in futures {
            replies.append(try await future.get())
        }
        return replies
    }

    private func fetchServerVersion() async throws -> String? {
        let reply = try await send(["INFO", "server"])
        guard case .bulkString(let info?) = reply else { return nil }
        // INFO uses CRLF line ends; "\r\n" is a single grapheme in Swift, so a
        // split on "\n" would never match — split on any newline instead.
        for line in info.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("redis_version:") {
                return line.dropFirst("redis_version:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

/// Accumulates inbound bytes, parses RESP replies, and fulfills the pending
/// promises in FIFO order (replies always arrive in command order).
///
/// State is only ever touched on the channel's event loop — `expectReplies`
/// hops there before it registers anything — which is why the `@unchecked
/// Sendable` conformance is safe.
final class RESPClientHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var buffer = ByteBufferAllocator().buffer(capacity: 0)
    /// Stateful on purpose: it carries a half-received reply between reads, so
    /// it must be the same instance for the lifetime of the connection.
    private var parser = RESPParser()
    private var pending: [EventLoopPromise<RESPValue>] = []
    /// Flips when the connection dies. Promises registered afterwards fail
    /// immediately — a command sent after a remote disconnect must error, not
    /// hang forever with the driver's command lock held.
    private var isDead = false

    /// Registers `count` promises for the replies of a just-written pipeline.
    /// Hop to the event loop so `pending` (and `isDead`) are only ever touched
    /// there.
    func expectReplies(count: Int, on eventLoop: EventLoop) -> [EventLoopFuture<RESPValue>] {
        let promises = (0..<count).map { _ in eventLoop.makePromise(of: RESPValue.self) }
        eventLoop.execute {
            if self.isDead {
                for promise in promises {
                    promise.fail(DatabaseError.connectionFailed("Connection closed"))
                }
            } else {
                self.pending.append(contentsOf: promises)
            }
        }
        return promises.map(\.futureResult)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        while !pending.isEmpty {
            do {
                guard let reply = try parser.next(&buffer) else { break }
                pending.removeFirst().succeed(reply)
            } catch {
                die(with: error, context: context)
                return
            }
        }
        if buffer.readableBytes == 0 {
            // Reclaim consumed bytes so a long session doesn't grow the buffer.
            // The parser keeps any half-built value, so this is safe mid-frame.
            buffer.clear()
        } else if pending.isEmpty {
            // Bytes with nothing awaiting them are either an unsolicited push
            // (a subscribe leak) or a peer that isn't Redis. Matching either to
            // a later command would silently shift every reply — kill the
            // connection instead so the failure is loud and immediate. A parse
            // error counts: swallowing it would leave the stream desynced.
            do {
                if try parser.next(&buffer) != nil {
                    die(with: DatabaseError.connectionFailed(
                        "Protocol desync: the server sent an unsolicited reply"), context: context)
                }
            } catch {
                die(with: error, context: context)
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        isDead = true
        failAll(DatabaseError.connectionFailed("Connection closed"))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        die(with: error, context: context)
    }

    private func die(with error: Error, context: ChannelHandlerContext) {
        isDead = true
        failAll(error)
        context.close(promise: nil)
    }

    private func failAll(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for promise in waiting { promise.fail(error) }
    }
}
