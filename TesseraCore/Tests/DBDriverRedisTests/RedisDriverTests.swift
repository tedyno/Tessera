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
}
