import Foundation

/// Serializes a `QueryResult` for saving to a file. Pure, so it can be unit-tested.
public enum ResultExport {
    public enum Format: String, Sendable, CaseIterable {
        case csv, json

        public var fileExtension: String { rawValue }
    }

    public static func string(from result: QueryResult, format: Format) -> String {
        switch format {
        case .csv: csv(result)
        case .json: json(result)
        }
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

    private static func escapeCSV(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r")
        else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
