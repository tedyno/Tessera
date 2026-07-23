import Foundation

/// Serializes a `QueryResult` for saving to a file. Pure, so it can be unit-tested.
public enum ResultExport {
    public enum Format: String, Sendable, CaseIterable {
        case csv, json, xlsx, sql

        public var fileExtension: String { rawValue }

        /// Whether the format is text; `.xlsx` is a binary package.
        public var isText: Bool { self != .xlsx }
    }

    /// The text formats, so a caller cannot ask for a `String` of a binary workbook.
    public enum TextFormat { case csv, json, sql }

    /// Bytes to write for any format. Text formats are UTF-8; `.xlsx` is a workbook.
    /// `table` names the target of generated INSERT statements.
    public static func data(from result: QueryResult, format: Format,
                            table: String? = nil) throws -> Data {
        switch format {
        case .xlsx:
            return try XLSXWriter.workbook(from: result, sheetName: table ?? "Results")
        case .csv:
            return Data(string(from: result, format: .csv, table: table).utf8)
        case .json:
            return Data(string(from: result, format: .json, table: table).utf8)
        case .sql:
            return Data(string(from: result, format: .sql, table: table).utf8)
        }
    }

    public static func string(from result: QueryResult, format: TextFormat,
                              table: String? = nil) -> String {
        switch format {
        case .csv: csv(result)
        case .json: json(result)
        case .sql: inserts(result, table: table ?? "table")
        }
    }

    /// One INSERT per row. Numeric columns stay unquoted; SQL NULL is written as NULL.
    public static func inserts(_ result: QueryResult, table: String) -> String {
        guard !result.columns.isEmpty else { return "" }
        let columnList = result.columns.map(\.name).joined(separator: ", ")
        return result.rows.map { row in
            let values = result.columns.enumerated().map { index, column -> String in
                let text = index < row.count ? row[index].text : nil
                return SQLTypes.literal(text, typeName: column.typeName)
            }.joined(separator: ", ")
            return "INSERT INTO \(table) (\(columnList)) VALUES (\(values));"
        }.joined(separator: "\n")
    }

    /// RFC 4180-style CSV: header row, fields quoted when they contain a comma,
    /// quote, or newline (embedded quotes doubled). SQL NULL becomes an empty field.
    public static func csv(_ result: QueryResult) -> String {
        var lines: [String] = [result.columns.map { escapeCSV($0.name) }.joined(separator: ",")]
        for row in result.rows {
            let fields = result.columns.indices.map { index -> String in
                let text = index < row.count ? row[index].text : nil
                return escapeCSV(text ?? "")
            }
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// An array of objects keyed by column name; SQL NULL becomes JSON null.
    public static func json(_ result: QueryResult) -> String {
        let objects: [[String: Any]] = result.rows.map { row in
            var object: [String: Any] = [:]
            for (index, column) in result.columns.enumerated() {
                let text = index < row.count ? row[index].text : nil
                object[column.name] = text ?? NSNull()
            }
            return object
        }
        guard !objects.isEmpty else { return "[]" }
        guard let data = try? JSONSerialization.data(
            withJSONObject: objects, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }

    static func escapeCSV(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r")
        else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
