import Foundation

/// Clipboard formatting for the results grid's "Copy" / "Copy as" actions.
/// Pure text generation over materialized cell values (nil = SQL NULL), so the
/// escaping rules are tested here rather than living in the AppKit coordinator.
public enum GridClipboard {
    public enum Format: Sendable { case tsv, csv, json, insert }

    /// The clipboard text for a copied selection.
    ///
    /// `matrix` holds the selected values row by row. TSV honours the exact
    /// (possibly ragged) selection; the structured formats expect rectangular
    /// rows parallel to `columns`, which supply CSV headers, JSON keys/typing
    /// and INSERT column names. `table` names the INSERT target.
    /// Returns nil only when a format cannot represent the input (JSON encoding
    /// failure).
    public static func text(format: Format, columns: [ColumnDescriptor],
                            matrix: [[String?]], table: String) -> String? {
        switch format {
        case .tsv:
            return matrix.map { row in
                row.map { $0 ?? "" }.joined(separator: "\t")
            }.joined(separator: "\n")
        case .csv:
            let header = columns.map { csvField($0.name) }.joined(separator: ",")
            let body = matrix.map { row in
                row.map { csvField($0) }.joined(separator: ",")
            }
            return ([header] + body).joined(separator: "\n")
        case .json:
            let objects = matrix.map { row -> [String: Any] in
                var object: [String: Any] = [:]
                for (index, column) in columns.enumerated() where index < row.count {
                    object[column.name] = jsonValue(row[index], typeName: column.typeName)
                }
                return object
            }
            guard let data = try? JSONSerialization.data(withJSONObject: objects,
                                                         options: [.prettyPrinted, .sortedKeys]),
                  let string = String(data: data, encoding: .utf8) else { return nil }
            return string
        case .insert:
            let columnList = columns.map(\.name).joined(separator: ", ")
            return matrix.map { row in
                let values = columns.enumerated().map { index, column in
                    SQLTypes.literal(index < row.count ? row[index] : nil,
                                     typeName: column.typeName)
                }.joined(separator: ", ")
                return "INSERT INTO \(table) (\(columnList)) VALUES (\(values));"
            }.joined(separator: "\n")
        }
    }

    /// A JSON value for a cell: `null`, a real number for numeric columns (via
    /// `NSDecimalNumber`, so large int8/numeric keep full precision), else a string.
    static func jsonValue(_ value: String?, typeName: String) -> Any {
        guard let value else { return NSNull() }
        guard SQLTypes.isNumeric(typeName) else { return value }
        if let integer = Int(value) { return integer }
        // POSIX locale so the decimal separator is always ".", not the user's.
        let decimal = NSDecimalNumber(string: value, locale: Locale(identifier: "en_US_POSIX"))
        return decimal == NSDecimalNumber.notANumber ? value : decimal
    }

    static func csvField(_ value: String?) -> String {
        guard let value else { return "" }
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
        else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
