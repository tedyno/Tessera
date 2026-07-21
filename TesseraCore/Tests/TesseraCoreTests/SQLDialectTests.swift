import XCTest
@testable import DBKit

final class SQLDialectTests: XCTestCase {

    // MARK: Quoting

    func testQuoteEscapesTheQuoteCharacter() {
        XCTAssertEqual(DatabaseKind.postgres.dialect.quote("we\"ird"), "\"we\"\"ird\"")
        XCTAssertEqual(DatabaseKind.mysql.dialect.quote("we`ird"), "`we``ird`")
        XCTAssertEqual(DatabaseKind.mariadb.dialect.quote("order"), "`order`")
        XCTAssertEqual(DatabaseKind.sqlite.dialect.quote("order"), "\"order\"")
    }

    func testPostgresFoldsUnquotedNamesSoMixedCaseNeedsQuoting() {
        let pg = DatabaseKind.postgres.dialect
        XCTAssertFalse(pg.needsQuoting("plain_name"))
        XCTAssertTrue(pg.needsQuoting("MixedCase"))
        XCTAssertTrue(pg.needsQuoting("select"))
        XCTAssertTrue(pg.needsQuoting("has space"))
        XCTAssertEqual(pg.quoteIfNeeded("plain_name"), "plain_name")
        XCTAssertEqual(pg.quoteIfNeeded("MixedCase"), "\"MixedCase\"")
    }

    func testMySQLFamilyAndSQLiteKeepBareMixedCase() {
        for kind in [DatabaseKind.mysql, .mariadb, .sqlite] {
            let dialect = kind.dialect
            XCTAssertFalse(dialect.needsQuoting("MixedCase"), "\(kind)")
            XCTAssertTrue(dialect.needsQuoting("has-dash"), "\(kind)")
            XCTAssertTrue(dialect.needsQuoting("select"), "\(kind)")
        }
    }

    // MARK: Statement shapes

    func testEmptyInsertPerEngine() {
        XCTAssertEqual(DatabaseKind.postgres.dialect.emptyInsert(table: "\"t\""),
                       "INSERT INTO \"t\" DEFAULT VALUES;")
        XCTAssertEqual(DatabaseKind.mysql.dialect.emptyInsert(table: "`t`"),
                       "INSERT INTO `t` () VALUES ();")
        XCTAssertEqual(DatabaseKind.mariadb.dialect.emptyInsert(table: "`t`"),
                       "INSERT INTO `t` () VALUES ();")
        // SQLite supports DEFAULT VALUES since 3.0 — same shape as Postgres.
        XCTAssertEqual(DatabaseKind.sqlite.dialect.emptyInsert(table: "\"t\""),
                       "INSERT INTO \"t\" DEFAULT VALUES;")
    }

    func testExplainPrefixes() {
        let pg = DatabaseKind.postgres.dialect
        XCTAssertEqual(pg.explainPrefix(analyze: false).prefix, "EXPLAIN ")
        XCTAssertFalse(pg.explainPrefix(analyze: false).executes)
        XCTAssertEqual(pg.explainPrefix(analyze: true).prefix, "EXPLAIN ANALYZE ")
        XCTAssertTrue(pg.explainPrefix(analyze: true).executes)

        // MariaDB has no EXPLAIN ANALYZE; ANALYZE <stmt> is its executing form.
        let maria = DatabaseKind.mariadb.dialect
        XCTAssertEqual(maria.explainPrefix(analyze: true).prefix, "ANALYZE ")
        XCTAssertTrue(maria.explainPrefix(analyze: true).executes)
        XCTAssertEqual(maria.explainPrefix(analyze: false).prefix, "EXPLAIN ")

        // SQLite has a single, never-executing plan form — the app derives
        // "no separate Analyze menu item" from the two prefixes being equal.
        let sqlite = DatabaseKind.sqlite.dialect
        XCTAssertEqual(sqlite.explainPrefix(analyze: true).prefix, "EXPLAIN QUERY PLAN ")
        XCTAssertEqual(sqlite.explainPrefix(analyze: false).prefix, "EXPLAIN QUERY PLAN ")
        XCTAssertFalse(sqlite.explainPrefix(analyze: true).executes)
    }

    func testOnlyServerEnginesListDatabases() {
        XCTAssertNotNil(DatabaseKind.postgres.dialect.listDatabasesSQL)
        XCTAssertNotNil(DatabaseKind.mysql.dialect.listDatabasesSQL)
        XCTAssertNotNil(DatabaseKind.mariadb.dialect.listDatabasesSQL)
        XCTAssertNil(DatabaseKind.sqlite.dialect.listDatabasesSQL)
    }

    func testSchemaLayerOnlyOnPostgres() {
        XCTAssertTrue(DatabaseKind.postgres.dialect.hasSchemaLayer)
        XCTAssertFalse(DatabaseKind.mysql.dialect.hasSchemaLayer)
        XCTAssertFalse(DatabaseKind.mariadb.dialect.hasSchemaLayer)
        XCTAssertFalse(DatabaseKind.sqlite.dialect.hasSchemaLayer)
    }

    func testBooleanLiteralsAreReservedEverywhere() {
        for kind in [DatabaseKind.postgres, .mysql, .mariadb, .sqlite] {
            XCTAssertTrue(kind.dialect.needsQuoting("true"), "\(kind)")
            XCTAssertTrue(kind.dialect.needsQuoting("FALSE"), "\(kind)")
        }
    }

    func testReturningIsReservedOnlyWhereTheServerReservesIt() {
        XCTAssertTrue(DatabaseKind.mariadb.dialect.needsQuoting("returning"))
        XCTAssertTrue(DatabaseKind.postgres.dialect.needsQuoting("returning"))
        XCTAssertFalse(DatabaseKind.mysql.dialect.needsQuoting("returning"))
    }

    func testMariaDBCompletionExtendsMySQLWithReturning() {
        let mysql = DatabaseKind.mysql.dialect.completionKeywords
        let maria = DatabaseKind.mariadb.dialect.completionKeywords
        XCTAssertTrue(maria.contains("RETURNING"))
        XCTAssertFalse(mysql.contains("RETURNING"))
        XCTAssertTrue(Set(mysql).isSubset(of: Set(maria)))
    }
}
