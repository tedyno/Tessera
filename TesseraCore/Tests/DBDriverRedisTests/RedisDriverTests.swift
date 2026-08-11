import XCTest
import DBKit
@testable import DBDriverRedis

/// Integration tests against a live Redis instance. Skipped unless the
/// environment provides connection info.
///
/// Set: TESSERA_REDIS_HOST (and optionally TESSERA_REDIS_PORT,
/// TESSERA_REDIS_PASSWORD, TESSERA_REDIS_DB).
final class RedisDriverTests: XCTestCase {

    private func makeDriverOrSkip() async throws -> RedisDriver {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["TESSERA_REDIS_HOST"] else {
            throw XCTSkip("Set TESSERA_REDIS_* env vars to run Redis integration tests")
        }
        let port = Int(env["TESSERA_REDIS_PORT"] ?? "6379") ?? 6379
        let profile = ConnectionProfile(
            name: "test", kind: .redis, host: host, port: port,
            database: env["TESSERA_REDIS_DB"] ?? "0", username: "")
        let secrets = Secrets(databasePassword: env["TESSERA_REDIS_PASSWORD"])
        let driver = RedisDriver()
        try await driver.connect(profile: profile, secrets: secrets,
                                 endpoint: NetworkEndpoint(host: host, port: port))
        return driver
    }

    func testPingSetGetDelete() async throws {
        let driver = try await makeDriverOrSkip()
        defer { Task { await driver.close() } }

        let pong = try await driver.execute("PING", maxRows: nil)
        XCTAssertEqual(pong.rows, [[Cell("PONG")]])

        _ = try await driver.execute(#"SET tessera:test:k "hello world""#, maxRows: nil)
        let got = try await driver.execute("GET tessera:test:k", maxRows: nil)
        XCTAssertEqual(got.rows, [[Cell("hello world")]])

        let deleted = try await driver.deleteKeys(["tessera:test:k"])
        XCTAssertEqual(deleted, 1)
    }

    func testHashRendersPairsAndScanFindsKey() async throws {
        let driver = try await makeDriverOrSkip()
        defer { Task { await driver.close() } }

        _ = try await driver.execute("HSET tessera:test:h f1 v1 f2 v2", maxRows: nil)
        defer { Task { _ = try? await driver.deleteKeys(["tessera:test:h"]) } }

        let hash = try await driver.execute("HGETALL tessera:test:h", maxRows: nil)
        XCTAssertEqual(hash.columns.map(\.name), ["field", "value"])
        XCTAssertEqual(hash.rows.count, 2)

        var cursor = "0"
        var found: RedisKeyInfo?
        repeat {
            let page = try await driver.scanKeys(matching: "tessera:test:*",
                                                 cursor: cursor, count: 100)
            cursor = page.cursor
            if let match = page.keys.first(where: { $0.key == "tessera:test:h" }) {
                found = match
            }
        } while cursor != "0" && found == nil
        XCTAssertEqual(found?.type, "hash")
        XCTAssertNil(found?.ttlSeconds)
        XCTAssertEqual(found?.size, 2, "hash glimpse carries HLEN")
    }

    func testStringKeysCarrySizeAndPreview() async throws {
        let driver = try await makeDriverOrSkip()
        defer { Task { await driver.close() } }

        _ = try await driver.execute(#"SET tessera:test:s "hello preview""#, maxRows: nil)
        defer { Task { _ = try? await driver.deleteKeys(["tessera:test:s"]) } }

        var cursor = "0"
        var found: RedisKeyInfo?
        repeat {
            let page = try await driver.scanKeys(matching: "tessera:test:s",
                                                 cursor: cursor, count: 100)
            cursor = page.cursor
            if let match = page.keys.first(where: { $0.key == "tessera:test:s" }) {
                found = match
            }
        } while cursor != "0" && found == nil
        XCTAssertEqual(found?.preview, "hello preview")
        XCTAssertEqual(found?.size, "hello preview".utf8.count)
    }

    func testErrorReplySurfacesAsQueryFailed() async throws {
        let driver = try await makeDriverOrSkip()
        defer { Task { await driver.close() } }
        do {
            _ = try await driver.execute("NOSUCHCOMMAND", maxRows: nil)
            XCTFail("expected an error")
        } catch let DatabaseError.queryFailed(message) {
            XCTAssertTrue(message.lowercased().contains("unknown command"), message)
        }
    }

    func testServerVersionIsReported() async throws {
        let driver = try await makeDriverOrSkip()
        defer { Task { await driver.close() } }
        let version = try await driver.serverVersion()
        XCTAssertFalse(version.isEmpty)
    }

    // MARK: Helpers for the paging / parser tests

    /// Writes `count` filler keys under `prefix` in MSET batches.
    private func fill(_ driver: RedisDriver, prefix: String, count: Int) async throws {
        for start in stride(from: 0, to: count, by: 2_000) {
            var line = "MSET"
            for index in start..<min(start + 2_000, count) {
                line += " \(prefix)\(index) v\(index)"
            }
            _ = try await driver.execute(line, maxRows: nil)
        }
    }

    /// Deletes everything under `prefix`, so a run leaves no residue behind.
    private func removeAll(_ driver: RedisDriver, prefix: String) async throws {
        var cursor = "0"
        repeat {
            let page = try await driver.scanKeys(matching: "\(prefix)*",
                                                 cursor: cursor, count: 1_000)
            cursor = page.cursor
            if !page.keys.isEmpty {
                _ = try await driver.deleteKeys(page.keys.map(\.key))
            }
        } while cursor != "0"
    }

    // MARK: Scan paging

    func testScanPageFindsRareMatchesInALargeKeyspace() async throws {
        let driver = try await makeDriverOrSkip()
        defer { Task { await driver.close() } }
        let filler = "tessera:test:bulk:"
        let needle = "tessera:test:needle:"
        try await removeAll(driver, prefix: "tessera:test:")
        try await fill(driver, prefix: filler, count: 20_000)
        _ = try await driver.execute("MSET \(needle)a 1 \(needle)b 2 \(needle)c 3", maxRows: nil)

        // What the browser does: page until the cursor comes home. Every match
        // must show up — SCAN's per-call filtering used to hide them behind
        // page after empty page.
        var cursor = "0"
        var found: Set<String> = []
        var pages = 0
        repeat {
            let page = try await driver.scanPage(matching: "\(needle)*",
                                                 cursor: cursor, target: 500)
            cursor = page.cursor
            pages += 1
            found.formUnion(page.keys.map(\.key))
            XCTAssertLessThan(pages, 200, "paging should converge, not crawl")
        } while cursor != "0"

        XCTAssertEqual(found, [needle + "a", needle + "b", needle + "c"])
        // Each scanPage bundles up to 20 SCANs, so a 20k keyspace takes a
        // handful of pages rather than the ~40 a single-SCAN page would need.
        XCTAssertLessThanOrEqual(pages, 6, "took \(pages) pages")
        try await removeAll(driver, prefix: "tessera:test:")
    }

    func testFirstPageIsNotEmptyWhenMatchesExist() async throws {
        let driver = try await makeDriverOrSkip()
        defer { Task { await driver.close() } }
        let prefix = "tessera:test:first:"
        try await removeAll(driver, prefix: "tessera:test:")
        try await fill(driver, prefix: "tessera:test:bulk:", count: 20_000)
        try await fill(driver, prefix: prefix, count: 50)

        // The regression that started this: opening the browser with a filter
        // showed nothing at all until the user clicked "Load more" repeatedly.
        let page = try await driver.scanPage(matching: "\(prefix)*", cursor: "0", target: 500)
        XCTAssertFalse(page.keys.isEmpty, "the first page must show matches, not an empty grid")
        try await removeAll(driver, prefix: "tessera:test:")
    }

    // MARK: Blocking commands

    func testBlockingCommandsAreRefusedAndLeaveTheSessionUsable() async throws {
        let driver = try await makeDriverOrSkip()
        defer { Task { await driver.close() } }
        _ = try await driver.execute("ZADD tessera:test:z 1 a", maxRows: nil)
        defer { Task { _ = try? await driver.deleteKeys(["tessera:test:z"]) } }

        // Each of these would take the command lock and never give it back.
        for command in ["BZPOPMIN tessera:test:z 0", "BZPOPMAX tessera:test:z 0",
                        "BZMPOP 0 1 tessera:test:z MIN"] {
            do {
                _ = try await driver.execute(command, maxRows: nil)
                XCTFail("expected \(command) to be refused")
            } catch DatabaseError.unsupported {
                // expected
            }
        }
        // The refusal happens before the write, so the session is still healthy.
        let pong = try await driver.execute("PING", maxRows: nil)
        XCTAssertEqual(pong.rows, [[Cell("PONG")]])
    }

    // MARK: Transactions

    func testTransactionReportsAFailureCarriedInsideExec() async throws {
        let driver = try await makeDriverOrSkip()
        defer { Task { await driver.close() } }
        _ = try await driver.execute("SET tessera:test:str plain", maxRows: nil)
        defer { Task { _ = try? await driver.deleteKeys(["tessera:test:str"]) } }

        // LPUSH against a string fails inside EXEC's array, not as a RESP error
        // on EXEC itself — returning normally would claim the batch committed.
        do {
            try await driver.executeTransaction(["SET tessera:test:ok 1",
                                                 "LPUSH tessera:test:str x"])
            XCTFail("expected the transaction to report the WRONGTYPE failure")
        } catch let DatabaseError.queryFailed(message) {
            XCTAssertTrue(message.contains("WRONGTYPE"), message)
        }
        _ = try? await driver.deleteKeys(["tessera:test:ok"])
    }

    func testSuccessfulTransactionApplies() async throws {
        let driver = try await makeDriverOrSkip()
        defer { Task { await driver.close() } }
        defer { Task { _ = try? await driver.deleteKeys(["tessera:test:t1", "tessera:test:t2"]) } }
        try await driver.executeTransaction(["SET tessera:test:t1 one",
                                             "SET tessera:test:t2 two"])
        let got = try await driver.execute("MGET tessera:test:t1 tessera:test:t2", maxRows: nil)
        XCTAssertEqual(got.rows, [[Cell("one")], [Cell("two")]])
    }

    // MARK: Large replies

    func testLargeReplyArrivesIntactAcrossManyReads() async throws {
        let driver = try await makeDriverOrSkip()
        defer { Task { await driver.close() } }
        let key = "tessera:test:bigset"
        _ = try? await driver.deleteKeys([key])
        defer { Task { _ = try? await driver.deleteKeys([key]) } }
        for start in stride(from: 0, to: 20_000, by: 2_000) {
            var line = "SADD \(key)"
            for index in start..<(start + 2_000) { line += " member-\(index)" }
            _ = try await driver.execute(line, maxRows: nil)
        }

        // A reply this size lands in many TCP chunks: the parser has to carry
        // its state between reads instead of restarting on each one.
        let clock = ContinuousClock()
        let start = clock.now
        let members = try await driver.execute("SMEMBERS \(key)", maxRows: nil)
        let elapsed = clock.now - start
        XCTAssertEqual(members.rows.count, 20_000)
        XCTAssertLessThan(elapsed, .seconds(10), "re-parsing every chunk shows up here")

        // And the connection is still aligned afterwards.
        let count = try await driver.execute("SCARD \(key)", maxRows: nil)
        XCTAssertEqual(count.rows, [[Cell("20000")]])
    }

    func testRepliesStayInOrderAfterALargeOne() async throws {
        let driver = try await makeDriverOrSkip()
        defer { Task { await driver.close() } }
        let key = "tessera:test:seq"
        defer { Task { _ = try? await driver.deleteKeys([key]) } }
        var line = "RPUSH \(key)"
        for index in 0..<5_000 { line += " item-\(index)" }
        _ = try? await driver.deleteKeys([key])
        _ = try await driver.execute(line, maxRows: nil)

        _ = try await driver.execute("LRANGE \(key) 0 -1", maxRows: nil)
        // FIFO matching must survive the big frame: a desync would answer these
        // with each other's replies.
        let first = try await driver.execute("LINDEX \(key) 0", maxRows: nil)
        let last = try await driver.execute("LINDEX \(key) -1", maxRows: nil)
        XCTAssertEqual(first.rows, [[Cell("item-0")]])
        XCTAssertEqual(last.rows, [[Cell("item-4999")]])
    }

    // MARK: Database index

    func testNonNumericDatabaseIndexIsRefusedInsteadOfUsingDatabaseZero() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["TESSERA_REDIS_HOST"] else {
            throw XCTSkip("Set TESSERA_REDIS_* env vars to run Redis integration tests")
        }
        let port = Int(env["TESSERA_REDIS_PORT"] ?? "6379") ?? 6379
        let profile = ConnectionProfile(name: "test", kind: .redis, host: host, port: port,
                                        database: "appdb", username: "")
        let driver = RedisDriver()
        do {
            try await driver.connect(profile: profile, secrets: Secrets(databasePassword: nil),
                                     endpoint: NetworkEndpoint(host: host, port: port))
            await driver.close()
            XCTFail("a non-numeric index must not silently connect to db0")
        } catch let DatabaseError.connectionFailed(message) {
            XCTAssertTrue(message.contains("database index"), message)
        }
    }

    func testNumericDatabaseIndexSelectsThatDatabase() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["TESSERA_REDIS_HOST"] else {
            throw XCTSkip("Set TESSERA_REDIS_* env vars to run Redis integration tests")
        }
        let port = Int(env["TESSERA_REDIS_PORT"] ?? "6379") ?? 6379
        let profile = ConnectionProfile(name: "test", kind: .redis, host: host, port: port,
                                        database: " 3 ", username: "")
        let driver = RedisDriver()
        try await driver.connect(profile: profile, secrets: Secrets(databasePassword: nil),
                                 endpoint: NetworkEndpoint(host: host, port: port))
        defer { Task { await driver.close() } }
        let tree = try await driver.fetchSchema()
        XCTAssertEqual(tree.databaseName, "db3")
    }
}
