import XCTest
import DBKit
@testable import DBDriverMySQL

/// Integration tests against a live MariaDB instance — same driver as MySQL,
/// exercised separately because the server's handshake and version string
/// differ. Skipped unless the environment provides connection info.
///
/// Set: TESSERA_MARIADB_HOST, TESSERA_MARIADB_PORT, TESSERA_MARIADB_USER,
/// TESSERA_MARIADB_PASSWORD, TESSERA_MARIADB_DB
final class MariaDBDriverTests: XCTestCase {

    private func makeProfileOrSkip() throws -> (ConnectionProfile, Secrets, NetworkEndpoint) {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["TESSERA_MARIADB_HOST"],
              let user = env["TESSERA_MARIADB_USER"],
              let db = env["TESSERA_MARIADB_DB"] else {
            throw XCTSkip("Set TESSERA_MARIADB_* env vars to run MariaDB integration tests")
        }
        let port = Int(env["TESSERA_MARIADB_PORT"] ?? "3306") ?? 3306
        let profile = ConnectionProfile(
            name: "test", kind: .mariadb, host: host, port: port,
            database: db, username: user, tlsMode: .disable)
        let secrets = Secrets(databasePassword: env["TESSERA_MARIADB_PASSWORD"])
        return (profile, secrets, NetworkEndpoint(host: host, port: port))
    }

    func testConnectAndQuery() async throws {
        let (profile, secrets, endpoint) = try makeProfileOrSkip()
        let driver = MySQLDriver()
        try await driver.connect(profile: profile, secrets: secrets, endpoint: endpoint)
        defer { Task { await driver.close() } }

        let result = try await driver.execute(
            "SELECT 42 AS n, 'hello' AS s, CAST(3.14 AS DECIMAL(5,2)) AS pi, NULL AS nothing")
        XCTAssertEqual(result.columns.map(\.name), ["n", "s", "pi", "nothing"])
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0][0].text, "42")
        XCTAssertEqual(result.rows[0][1].text, "hello")
        XCTAssertEqual(result.rows[0][2].text, "3.14")
        XCTAssertTrue(result.rows[0][3].isNull)
    }

    func testFetchSchema() async throws {
        let (profile, secrets, endpoint) = try makeProfileOrSkip()
        let driver = MySQLDriver()
        try await driver.connect(profile: profile, secrets: secrets, endpoint: endpoint)
        defer { Task { await driver.close() } }

        _ = try await driver.execute("DROP TABLE IF EXISTS schema_probe")
        _ = try await driver.execute(
            "CREATE TABLE schema_probe (id BIGINT PRIMARY KEY, label TEXT NOT NULL)")
        defer { Task { _ = try? await driver.execute("DROP TABLE IF EXISTS schema_probe") } }

        let tree = try await driver.fetchSchema()
        let probe = tree.schemas.first?.tables.first { $0.name == "schema_probe" }
        XCTAssertNotNil(probe)
        XCTAssertEqual(probe?.columns.first { $0.name == "id" }?.isPrimaryKey, true)
    }
}
