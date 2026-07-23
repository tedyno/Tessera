import XCTest
import DBKit
@testable import DBDriverSQLite

/// Real end-to-end streaming against a temp-file database — no server needed.
final class SQLiteStreamTests: XCTestCase {
    private var driver: SQLiteDriver!
    private var path: String!

    override func setUp() async throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-stream-\(UUID().uuidString).sqlite").path
        driver = SQLiteDriver()
        try await driver.connect(
            profile: ConnectionProfile(name: "t", kind: .sqlite, host: "", port: 0,
                                       database: path, username: ""),
            secrets: Secrets(), endpoint: NetworkEndpoint(host: "", port: 0))
        _ = try await driver.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
    }

    override func tearDown() async throws {
        await driver.close()
        try? FileManager.default.removeItem(atPath: path)
    }

    private func seed(_ count: Int) async throws {
        var values: [String] = []
        for i in 1...count { values.append("(\(i), 'name-\(i)')") }
        _ = try await driver.execute("INSERT INTO t (id, name) VALUES \(values.joined(separator: ","))")
    }

    /// Collects everything the sink receives, so a test can reassemble the full
    /// result and diff it against `execute`.
    private final class CollectingSink: RowSink, @unchecked Sendable {
        var columns: [ColumnDescriptor] = []
        var rows: [[Cell]] = []
        var batches = 0
        func begin(columns: [ColumnDescriptor]) throws { self.columns = columns }
        func write(_ rows: [[Cell]]) throws { self.rows.append(contentsOf: rows); batches += 1 }
        func finish() throws {}
    }

    func testStreamMatchesExecuteAndBatches() async throws {
        try await seed(2500)
        let sink = CollectingSink()
        try await driver.stream("SELECT id, name FROM t ORDER BY id", batchSize: 1000, into: sink)

        let buffered = try await driver.execute("SELECT id, name FROM t ORDER BY id", maxRows: nil)
        XCTAssertEqual(sink.columns.map(\.name), buffered.columns.map(\.name))
        XCTAssertEqual(sink.rows.count, 2500)
        XCTAssertEqual(sink.rows.map { $0[0].text }, buffered.rows.map { $0[0].text })
        // 2500 rows at batchSize 1000 → 3 batches (1000 + 1000 + 500).
        XCTAssertEqual(sink.batches, 3)
    }

    func testStreamEmptyResultStillDeliversHeader() async throws {
        let sink = CollectingSink()
        try await driver.stream("SELECT id, name FROM t WHERE id < 0", batchSize: 100, into: sink)
        XCTAssertEqual(sink.columns.map(\.name), ["id", "name"])
        XCTAssertTrue(sink.rows.isEmpty)
        XCTAssertEqual(sink.batches, 0)
    }

    func testStreamCSVExportEndToEnd() async throws {
        try await seed(5)
        let out = InMemoryByteSink()
        let exporter = StreamingResultExport(format: .csv, into: out)
        try await driver.stream("SELECT id, name FROM t ORDER BY id", batchSize: 2, into: exporter)

        let buffered = try await driver.execute("SELECT id, name FROM t ORDER BY id", maxRows: nil)
        XCTAssertEqual(out.string, ResultExport.csv(buffered))
    }

    func testExportToFileMatchesBufferedAndReportsSummary() async throws {
        try await seed(1200)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-export-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try await StreamingResultExport.export(
            "SELECT id, name FROM t ORDER BY id", from: driver, format: .csv, to: url, batchSize: 250)

        let buffered = try await driver.execute("SELECT id, name FROM t ORDER BY id", maxRows: nil)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, ResultExport.csv(buffered))
        XCTAssertEqual(summary.rows, 1200)
        XCTAssertEqual(summary.bytes, Data(written.utf8).count)
    }

    func testExportAtomicallyReplacesExistingFile() async throws {
        try await seed(3)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-export-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try "stale contents".write(to: url, atomically: true, encoding: .utf8)

        _ = try await StreamingResultExport.export(
            "SELECT id, name FROM t ORDER BY id", from: driver, format: .sql, table: "t", to: url)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(written.hasPrefix("INSERT INTO t"))
        XCTAssertFalse(written.contains("stale"))
    }
}
