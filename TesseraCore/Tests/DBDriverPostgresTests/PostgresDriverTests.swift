import XCTest
import DBKit
@testable import DBDriverPostgres

/// Integration tests against a live PostgreSQL instance. Skipped unless the
/// environment provides connection info, so the suite stays green offline.
///
/// Set: TESSERA_PG_HOST, TESSERA_PG_PORT, TESSERA_PG_USER, TESSERA_PG_PASSWORD,
/// TESSERA_PG_DB
final class PostgresDriverTests: XCTestCase {

    private func makeProfileOrSkip() throws -> (ConnectionProfile, Secrets, NetworkEndpoint) {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["TESSERA_PG_HOST"],
              let user = env["TESSERA_PG_USER"],
              let db = env["TESSERA_PG_DB"] else {
            throw XCTSkip("Set TESSERA_PG_* env vars to run Postgres integration tests")
        }
        let port = Int(env["TESSERA_PG_PORT"] ?? "5432") ?? 5432
        let profile = ConnectionProfile(
            name: "test", kind: .postgres, host: host, port: port,
            database: db, username: user, tlsMode: .disable
        )
        let secrets = Secrets(databasePassword: env["TESSERA_PG_PASSWORD"])
        let endpoint = NetworkEndpoint(host: host, port: port)
        return (profile, secrets, endpoint)
    }

    func testConnectAndQueryTypes() async throws {
        let (profile, secrets, endpoint) = try makeProfileOrSkip()
        let driver = PostgresDriver()
        try await driver.connect(profile: profile, secrets: secrets, endpoint: endpoint)
        defer { Task { await driver.close() } }

        let result = try await driver.execute("""
            SELECT 42::int8 AS n, 'hello'::text AS s, true AS b,
                   3.14::numeric AS pi, NULL::text AS nothing
            """)

        XCTAssertEqual(result.columns.map(\.name), ["n", "s", "b", "pi", "nothing"])
        XCTAssertEqual(result.rows.count, 1)

        let row = result.rows[0]
        XCTAssertEqual(row[0].text, "42")
        XCTAssertEqual(row[1].text, "hello")
        XCTAssertEqual(row[2].text, "true")
        XCTAssertEqual(row[3].text, "3.14")
        XCTAssertTrue(row[4].isNull)
    }

    func testFetchSchema() async throws {
        let (profile, secrets, endpoint) = try makeProfileOrSkip()
        let driver = PostgresDriver()
        try await driver.connect(profile: profile, secrets: secrets, endpoint: endpoint)
        defer { Task { await driver.close() } }

        _ = try await driver.execute("CREATE SCHEMA IF NOT EXISTS public")
        _ = try await driver.execute("DROP TABLE IF EXISTS schema_probe")
        _ = try await driver.execute("""
            CREATE TABLE schema_probe (id bigint PRIMARY KEY, label text NOT NULL, note text)
            """)
        defer { Task { _ = try? await driver.execute("DROP TABLE IF EXISTS schema_probe") } }

        let tree = try await driver.fetchSchema()
        let publicSchema = tree.schemas.first { $0.name == "public" }
        XCTAssertNotNil(publicSchema)
        let probe = publicSchema?.tables.first { $0.name == "schema_probe" }
        XCTAssertNotNil(probe)
        XCTAssertEqual(probe?.columns.map(\.name), ["id", "label", "note"])
        XCTAssertEqual(probe?.columns.first { $0.name == "id" }?.isPrimaryKey, true)
        XCTAssertEqual(probe?.columns.first { $0.name == "label" }?.isNullable, false)
    }

    func testForeignKeysAndIndexes() async throws {
        let (profile, secrets, endpoint) = try makeProfileOrSkip()
        let driver = PostgresDriver()
        try await driver.connect(profile: profile, secrets: secrets, endpoint: endpoint)
        defer { Task { await driver.close() } }

        let tree = try await driver.fetchSchema()
        let orders = tree.schemas.first { $0.name == "public" }?.tables.first { $0.name == "orders" }
        XCTAssertNotNil(orders, "seed the orders table before running")
        XCTAssertEqual(orders?.columns.first { $0.name == "id" }?.isPrimaryKey, true)
        XCTAssertEqual(orders?.columns.first { $0.name == "customer_id" }?.isForeignKey, true)
        XCTAssertFalse(orders?.indexes.isEmpty ?? true) // at least the primary-key index
    }

    func testLargeResultSet() async throws {
        let (profile, secrets, endpoint) = try makeProfileOrSkip()
        let driver = PostgresDriver()
        try await driver.connect(profile: profile, secrets: secrets, endpoint: endpoint)
        defer { Task { await driver.close() } }

        let result = try await driver.execute("SELECT g FROM generate_series(1, 100000) AS g")
        XCTAssertEqual(result.rows.count, 100_000)
        XCTAssertEqual(result.rows.first?.first?.text, "1")
        XCTAssertEqual(result.rows.last?.first?.text, "100000")
    }

    func testMultipleRows() async throws {
        let (profile, secrets, endpoint) = try makeProfileOrSkip()
        let driver = PostgresDriver()
        try await driver.connect(profile: profile, secrets: secrets, endpoint: endpoint)
        defer { Task { await driver.close() } }

        let result = try await driver.execute("SELECT g AS id FROM generate_series(1, 5) AS g")
        XCTAssertEqual(result.rows.count, 5)
        XCTAssertEqual(result.rows.map { $0[0].text }, ["1", "2", "3", "4", "5"])
    }
}
