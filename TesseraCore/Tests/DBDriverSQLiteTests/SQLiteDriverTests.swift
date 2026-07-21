import XCTest
import DBKit
@testable import DBDriverSQLite

/// Unlike the network drivers, these run for real on every test invocation —
/// the database is a temp file, no server needed.
final class SQLiteDriverTests: XCTestCase {
    private var driver: SQLiteDriver!
    private var path: String!

    override func setUp() async throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-test-\(UUID().uuidString).sqlite").path
        driver = SQLiteDriver()
        try await driver.connect(profile: profile(), secrets: Secrets(),
                                 endpoint: NetworkEndpoint(host: "", port: 0))
    }

    override func tearDown() async throws {
        await driver.close()
        try? FileManager.default.removeItem(atPath: path)
    }

    private func profile() -> ConnectionProfile {
        ConnectionProfile(name: "test", kind: .sqlite, host: "", port: 0,
                          database: path, username: "")
    }

    // MARK: Queries

    func testCreateInsertSelectRoundTrip() async throws {
        _ = try await driver.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
        let insert = try await driver.execute("INSERT INTO t (name) VALUES ('a'), ('b')")
        XCTAssertEqual(insert.rowsAffected, 2)

        let result = try await driver.execute("SELECT id, name FROM t ORDER BY id")
        XCTAssertEqual(result.columns.map(\.name), ["id", "name"])
        XCTAssertEqual(result.columns.map(\.typeName), ["integer", "text"])
        XCTAssertEqual(result.rows.map { $0[1].text }, ["a", "b"])
    }

    func testNullAndEmptyStringStayDistinct() async throws {
        _ = try await driver.execute("CREATE TABLE t (v TEXT)")
        _ = try await driver.execute("INSERT INTO t VALUES (NULL), ('')")
        let result = try await driver.execute("SELECT v FROM t")
        XCTAssertNil(result.rows[0][0].text)
        XCTAssertEqual(result.rows[1][0].text, "")
    }

    func testMaxRowsTruncates() async throws {
        _ = try await driver.execute("CREATE TABLE t (n INTEGER)")
        _ = try await driver.execute(
            "INSERT INTO t SELECT value FROM (WITH RECURSIVE s(value) AS "
            + "(SELECT 1 UNION ALL SELECT value + 1 FROM s WHERE value < 20) SELECT value FROM s)")
        let result = try await driver.execute("SELECT n FROM t", maxRows: 5)
        XCTAssertEqual(result.rows.count, 5)
        XCTAssertTrue(result.isTruncated)
    }

    func testMultiStatementScriptShowsLastResult() async throws {
        let result = try await driver.execute(
            "CREATE TABLE t (n INTEGER); INSERT INTO t VALUES (1); SELECT n FROM t")
        XCTAssertEqual(result.columns.map(\.name), ["n"])
        XCTAssertEqual(result.rows.first?.first?.text, "1")
    }

    func testExpressionColumnGetsDynamicType() async throws {
        let result = try await driver.execute("SELECT 1 + 1 AS sum, 'x' AS label")
        XCTAssertEqual(result.columns.map(\.typeName), ["integer", "text"])
    }

    // MARK: Transactions

    func testTransactionRollsBackOnError() async throws {
        _ = try await driver.execute("CREATE TABLE t (n INTEGER NOT NULL)")
        do {
            try await driver.executeTransaction([
                "INSERT INTO t VALUES (1)",
                "INSERT INTO t VALUES (NULL)",   // violates NOT NULL
            ])
            XCTFail("transaction should have thrown")
        } catch {}
        let result = try await driver.execute("SELECT count(*) FROM t")
        XCTAssertEqual(result.rows.first?.first?.text, "0")
    }

    // MARK: Introspection

    func testFetchSchemaShapes() async throws {
        _ = try await driver.execute("""
            CREATE TABLE authors (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL
            );
            CREATE TABLE books (
                isbn TEXT,
                lang TEXT,
                author_id INTEGER REFERENCES authors(id),
                PRIMARY KEY (isbn, lang)
            );
            CREATE INDEX books_author ON books(author_id);
            CREATE UNIQUE INDEX authors_name ON authors(name);
            CREATE VIEW author_names AS SELECT name FROM authors;
            """)

        let tree = try await driver.fetchSchema()
        XCTAssertEqual(tree.databaseName, "main")
        XCTAssertEqual(tree.schemas.count, 1)
        let tables = tree.schemas[0].tables

        let authors = try XCTUnwrap(tables.first { $0.name == "authors" })
        let authorID = try XCTUnwrap(authors.columns.first { $0.name == "id" })
        XCTAssertTrue(authorID.isPrimaryKey)
        XCTAssertTrue(authorID.isAutoIncrement)
        let authorName = try XCTUnwrap(authors.columns.first { $0.name == "name" })
        XCTAssertFalse(authorName.isNullable)
        XCTAssertTrue(authors.indexes.contains { $0.name == "authors_name" && $0.isUnique })

        let books = try XCTUnwrap(tables.first { $0.name == "books" })
        XCTAssertEqual(books.columns.filter(\.isPrimaryKey).count, 2)
        let authorRef = try XCTUnwrap(books.columns.first { $0.name == "author_id" })
        XCTAssertTrue(authorRef.isForeignKey)
        XCTAssertEqual(authorRef.references,
                       ForeignKeyTarget(schema: "main", table: "authors", column: "id"))
        // A composite PK is not a rowid alias — neither key column is generated.
        XCTAssertFalse(books.columns.contains { $0.isAutoIncrement })
        XCTAssertTrue(books.indexes.contains { $0.name == "books_author" && !$0.isUnique })

        let view = try XCTUnwrap(tables.first { $0.name == "author_names" })
        XCTAssertEqual(view.kind, .view)
    }

    // MARK: Cancel

    func testRowsAffectedIsScopedToTheScript() async throws {
        _ = try await driver.execute("CREATE TABLE t (a TEXT)")
        _ = try await driver.execute("INSERT INTO t VALUES ('x'), ('y'), ('z')")
        _ = try await driver.execute("DELETE FROM t")

        // No DML in this script — a stale last-DML counter must not leak in.
        let ddl = try await driver.execute("CREATE TABLE u (b TEXT)")
        XCTAssertEqual(ddl.rowsAffected, 0)

        // Multi-DML script: counts sum across statements, not just the last one.
        let script = try await driver.execute(
            "INSERT INTO u VALUES ('a'), ('b'); INSERT INTO u VALUES ('c')")
        XCTAssertEqual(script.rowsAffected, 3)
    }

    func testImplicitForeignKeyResolvesToParentPrimaryKey() async throws {
        _ = try await driver.execute("CREATE TABLE parent (pid INTEGER PRIMARY KEY, label TEXT)")
        // No target column: "REFERENCES parent" implicitly means parent's PK.
        _ = try await driver.execute("CREATE TABLE child (id INTEGER PRIMARY KEY, pid INTEGER REFERENCES parent)")

        let tree = try await driver.fetchSchema()
        let child = tree.schemas[0].tables.first { $0.name == "child" }
        let fk = child?.columns.first { $0.name == "pid" }
        XCTAssertEqual(fk?.isForeignKey, true)
        XCTAssertEqual(fk?.references?.table, "parent")
        XCTAssertEqual(fk?.references?.column, "pid")
    }

    func testWithoutRowIDPrimaryKeyIsNotAutoIncrement() async throws {
        _ = try await driver.execute(
            "CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT) WITHOUT ROWID")
        let tree = try await driver.fetchSchema()
        let key = tree.schemas[0].tables.first { $0.name == "kv" }?
            .columns.first { $0.name == "k" }
        XCTAssertEqual(key?.isPrimaryKey, true)
        // No rowid to alias — the database will not supply this value.
        XCTAssertEqual(key?.isAutoIncrement, false)
    }

    func testInterruptCancelsARunningQuery() async throws {
        let slow = """
            WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 100000000)
            SELECT count(*) FROM c
            """
        let running = Task { [driver] in
            try await driver!.execute(slow)
        }
        try await Task.sleep(for: .milliseconds(100))
        await driver.cancelRunningQuery()
        do {
            _ = try await running.value
            XCTFail("query should have been cancelled")
        } catch let error as DatabaseError {
            XCTAssertEqual(error, .cancelled)
        }
    }
}
