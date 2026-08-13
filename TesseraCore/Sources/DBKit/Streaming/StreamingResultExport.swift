import Foundation

/// A `RowSink` that formats streamed rows into CSV or SQL `INSERT` bytes as they
/// arrive, so exporting a huge result stays at constant memory. The output is
/// byte-for-byte identical to the buffered `ResultExport` for the same rows, so a
/// result exports the same whether it fit in memory or had to be streamed.
///
/// JSON is intentionally not offered here: the buffered path pretty-prints via
/// `JSONSerialization`, whose exact whitespace can't be reproduced incrementally.
public final class StreamingResultExport: RowSink, @unchecked Sendable {
    public enum Format: Sendable { case csv, sql }

    private let format: Format
    private let sink: ByteSink
    private let table: String

    private var columns: [ColumnDescriptor] = []
    private var columnList = ""     // precomputed `INSERT` column list
    private var skip = false        // SQL with no columns emits nothing
    private var wroteFirstRow = false
    /// Number of data rows written, for callers that report an export summary.
    public private(set) var rowCount = 0
    /// Bytes handed to the sink so far. Counted here rather than read back off the
    /// sink so progress works for any `ByteSink`, not just the file one.
    public private(set) var byteCount = 0
    /// Called after each batch reaches the sink, so a caller can show how far a long
    /// export has got. Runs on whatever executor the driver streams from — a UI
    /// observer has to hop to its own actor.
    public var onProgress: (@Sendable (Summary) -> Void)?
    /// Consulted before each batch is formatted; returning true aborts the export
    /// with `CancellationError`. Checked here rather than left to the driver so a
    /// stopped export unwinds the same way on every engine — and `export` then
    /// removes the partial file on its way out.
    public var shouldCancel: (@Sendable () -> Bool)?

    /// `table` names the target of generated `INSERT` statements (ignored for CSV).
    public init(format: Format, into sink: ByteSink, table: String = "table") {
        self.format = format
        self.sink = sink
        self.table = table
    }

    public func begin(columns: [ColumnDescriptor]) throws {
        self.columns = columns
        switch format {
        case .csv:
            // Header row, no trailing newline — rows prepend their own separator.
            let header = columns.map { ResultExport.escapeCSV($0.name) }.joined(separator: ",")
            try emit(header)
        case .sql:
            // Mirror `ResultExport.inserts`: an empty column set produces nothing.
            skip = columns.isEmpty
            columnList = columns.map(\.name).joined(separator: ", ")
        }
    }

    public func write(_ rows: [[Cell]]) throws {
        if shouldCancel?() == true { throw CancellationError() }
        guard !skip else { return }
        rowCount += rows.count
        for row in rows {
            switch format {
            case .csv:
                let fields = columns.indices.map { index -> String in
                    let text = index < row.count ? row[index].text : nil
                    return ResultExport.escapeCSV(text ?? "")
                }.joined(separator: ",")
                try emit("\n" + fields)   // every data row follows the header/prior row
            case .sql:
                let values = columns.enumerated().map { index, column -> String in
                    let text = index < row.count ? row[index].text : nil
                    return SQLTypes.literal(text, typeName: column.typeName)
                }.joined(separator: ", ")
                let statement = "INSERT INTO \(table) (\(columnList)) VALUES (\(values));"
                try emit(wroteFirstRow ? "\n" + statement : statement)
                wroteFirstRow = true
            }
        }
        onProgress?(Summary(rows: rowCount, bytes: byteCount))
    }

    public func finish() throws {}

    private func emit(_ text: String) throws {
        let data = Data(text.utf8)
        byteCount += data.count
        try sink.write(data)
    }
}

public extension StreamingResultExport {
    /// Summary of a completed streaming export.
    struct Summary: Sendable { public let rows: Int; public let bytes: Int }

    /// Streams `sql` through `driver` into a file at `url`, formatting incrementally
    /// so an arbitrarily large result never has to be held in memory. Writes to a
    /// sibling temp file and atomically replaces `url` on success, so a failed or
    /// cancelled export never leaves a truncated file behind.
    /// `onProgress` fires once per batch with the running totals, so a caller can
    /// report how far a long export has got; `shouldCancel` is polled just as often
    /// and aborts the export, leaving the destination file untouched.
    static func export(_ sql: String, from driver: DatabaseDriver, format: Format,
                       table: String = "table", to url: URL,
                       batchSize: Int = 1000,
                       onProgress: (@Sendable (Summary) -> Void)? = nil,
                       shouldCancel: (@Sendable () -> Bool)? = nil) async throws -> Summary {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).partial")
        try? FileManager.default.removeItem(at: temp)   // clear a stale partial
        let sink = try FileByteSink(creatingAt: temp)
        let exporter = StreamingResultExport(format: format, into: sink, table: table)
        exporter.onProgress = onProgress
        exporter.shouldCancel = shouldCancel
        do {
            try await driver.stream(sql, batchSize: batchSize, into: exporter)
            try sink.close()
        } catch {
            try? sink.close()
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
        return Summary(rows: exporter.rowCount, bytes: sink.bytesWritten)
    }
}
