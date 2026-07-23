import XCTest
@testable import DBKit

/// The streaming exporter must produce byte-for-byte the same output as the
/// buffered `ResultExport`, so a result exports identically whether it fit in
/// memory or had to be streamed — checked across batch sizes and edge cases.
final class StreamingResultExportTests: XCTestCase {

    /// Drives a `RowSink` the way a driver would: begin, then `write` in chunks of
    /// `batchSize`, then finish.
    private func feed(_ sink: RowSink, _ result: QueryResult, batchSize: Int) throws {
        try sink.begin(columns: result.columns)
        var start = 0
        while start < result.rows.count {
            let end = min(start + batchSize, result.rows.count)
            try sink.write(Array(result.rows[start..<end]))
            start = end
        }
        try sink.finish()
    }

    private func streamedCSV(_ result: QueryResult, batchSize: Int) throws -> String {
        let out = InMemoryByteSink()
        try feed(StreamingResultExport(format: .csv, into: out), result, batchSize: batchSize)
        return out.string
    }

    private func streamedSQL(_ result: QueryResult, batchSize: Int, table: String) throws -> String {
        let out = InMemoryByteSink()
        try feed(StreamingResultExport(format: .sql, into: out, table: table), result, batchSize: batchSize)
        return out.string
    }

    private let sample = QueryResult(
        columns: [ColumnDescriptor(name: "id", typeName: "integer"),
                  ColumnDescriptor(name: "name", typeName: "text")],
        rows: [[Cell("1"), Cell("Alice")],
               [Cell("2"), Cell(nil)],
               [Cell("3"), Cell("a,b")],
               [Cell("4"), Cell("say \"hi\"")],
               [Cell("5"), Cell("line1\nline2")]])

    func testStreamedCSVMatchesBufferedAcrossBatchSizes() throws {
        let expected = ResultExport.csv(sample)
        for batchSize in [1, 2, 3, 5, 100] {
            XCTAssertEqual(try streamedCSV(sample, batchSize: batchSize), expected,
                           "CSV mismatch at batchSize \(batchSize)")
        }
    }

    func testStreamedSQLMatchesBufferedAcrossBatchSizes() throws {
        let expected = ResultExport.inserts(sample, table: "t")
        for batchSize in [1, 2, 3, 5, 100] {
            XCTAssertEqual(try streamedSQL(sample, batchSize: batchSize, table: "t"), expected,
                           "SQL mismatch at batchSize \(batchSize)")
        }
    }

    func testEmptyResultMatchesBuffered() throws {
        // Header but no rows: CSV keeps the header, SQL still emits inserts.
        let headerOnly = QueryResult(columns: sample.columns, rows: [])
        XCTAssertEqual(try streamedCSV(headerOnly, batchSize: 4), ResultExport.csv(headerOnly))
        XCTAssertEqual(try streamedSQL(headerOnly, batchSize: 4, table: "t"),
                       ResultExport.inserts(headerOnly, table: "t"))
    }

    func testNoColumnsMatchesBuffered() throws {
        // A statement with no result set (e.g. DML) — both paths emit essentially
        // nothing, and must agree.
        let empty = QueryResult(columns: [], rows: [])
        XCTAssertEqual(try streamedCSV(empty, batchSize: 4), ResultExport.csv(empty))
        XCTAssertEqual(try streamedSQL(empty, batchSize: 4, table: "t"),
                       ResultExport.inserts(empty, table: "t"))
    }

    func testSingleRow() throws {
        let one = QueryResult(columns: sample.columns, rows: [[Cell("1"), Cell("only")]])
        XCTAssertEqual(try streamedCSV(one, batchSize: 1), ResultExport.csv(one))
        XCTAssertEqual(try streamedSQL(one, batchSize: 1, table: "t"),
                       ResultExport.inserts(one, table: "t"))
    }
}
