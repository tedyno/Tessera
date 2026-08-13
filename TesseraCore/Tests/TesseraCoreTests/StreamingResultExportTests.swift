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

    // MARK: Progress

    /// One report per batch, each carrying the running totals — that is what the
    /// status bar counts up as a long export runs.
    func testProgressReportsRunningTotalsPerBatch() throws {
        let out = InMemoryByteSink()
        let exporter = StreamingResultExport(format: .csv, into: out)
        let reports = Reports()
        exporter.onProgress = { reports.append($0) }
        try feed(exporter, sample, batchSize: 2)

        // 5 rows in batches of 2 → 3 writes.
        XCTAssertEqual(reports.rows, [2, 4, 5])
        // Bytes only ever grow, and end at exactly what was written.
        XCTAssertEqual(reports.bytes.sorted(), reports.bytes)
        XCTAssertEqual(reports.bytes.last, out.data.count)
        XCTAssertEqual(exporter.byteCount, out.data.count)
    }

    /// A result with no rows never reports: there is no batch to report on.
    func testProgressStaysSilentWithoutRows() throws {
        let exporter = StreamingResultExport(format: .csv, into: InMemoryByteSink())
        let reports = Reports()
        exporter.onProgress = { reports.append($0) }
        try feed(exporter, QueryResult(columns: sample.columns, rows: []), batchSize: 4)
        XCTAssertTrue(reports.rows.isEmpty)
    }

    // MARK: Cancellation

    /// Stopping an export aborts at the next batch — the rows already formatted stay
    /// in the sink, but nothing further is written and the caller sees the error that
    /// makes `export` discard the partial file.
    func testCancellationStopsAtTheNextBatch() throws {
        let out = InMemoryByteSink()
        let exporter = StreamingResultExport(format: .csv, into: out)
        let stop = Flag()
        exporter.shouldCancel = { stop.isSet }

        try exporter.begin(columns: sample.columns)
        try exporter.write(Array(sample.rows.prefix(2)))
        let afterFirstBatch = out.data.count
        stop.set()

        XCTAssertThrowsError(try exporter.write(Array(sample.rows.suffix(3)))) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(out.data.count, afterFirstBatch, "no bytes written after the stop")
        XCTAssertEqual(exporter.rowCount, 2)
    }

    /// The check runs before formatting, so a stop set before the first batch writes
    /// no data rows at all (the header is already out from `begin`).
    func testCancellationBeforeTheFirstBatchWritesNoRows() throws {
        let exporter = StreamingResultExport(format: .csv, into: InMemoryByteSink())
        exporter.shouldCancel = { true }
        try exporter.begin(columns: sample.columns)
        XCTAssertThrowsError(try exporter.write(sample.rows))
        XCTAssertEqual(exporter.rowCount, 0)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    /// Collects progress callbacks; the exporter calls them from whatever executor
    /// the driver streams on, so the storage is lock-protected.
    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var summaries: [StreamingResultExport.Summary] = []
        func append(_ summary: StreamingResultExport.Summary) {
            lock.withLock { summaries.append(summary) }
        }
        var rows: [Int] { lock.withLock { summaries.map(\.rows) } }
        var bytes: [Int] { lock.withLock { summaries.map(\.bytes) } }
    }
}
