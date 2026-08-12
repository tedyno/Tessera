import Foundation
import DBKit

/// Renders a RESP reply into the grid's `QueryResult` shape. Pure and
/// command-aware: pair-producing commands (HGETALL, CONFIG GET) show two
/// columns, WITHSCORES ranges show member/score, everything else lists values.
public enum RedisReplyDisplay {
    /// Commands whose flat array reply alternates field, value.
    private static let pairCommands: Set<String> = [
        "HGETALL", "CONFIG", "XPENDING",
    ]

    public static func result(command: [String], reply: RESPValue,
                              maxRows: Int?) -> QueryResult {
        let name = command.first?.uppercased() ?? ""
        switch reply {
        case .array(let elements):
            guard let elements else {
                return scalar(name: "value", text: nil)
            }
            return arrayResult(command: command, name: name,
                               elements: elements, maxRows: maxRows)
        case .simpleString(let text):
            return scalar(name: "reply", text: text)
        case .integer(let value):
            return scalar(name: "integer", text: String(value))
        case .bulkString(let text):
            return scalar(name: "value", text: text)
        case .error(let message):
            // Callers throw on .error before rendering; kept total for safety.
            return scalar(name: "error", text: message)
        }
    }

    /// A non-array reply: one value, flagged as such so the UI can render it as a
    /// document instead of a one-row table (a one-element array reply must not
    /// pass for the same thing).
    private static func scalar(name: String, text: String?) -> QueryResult {
        QueryResult(columns: [ColumnDescriptor(name: name, typeName: "string")],
                    rows: [[Cell(text)]],
                    returnsRows: true,
                    isSingleValue: true)
    }

    private static func arrayResult(command: [String], name: String,
                                    elements: [RESPValue], maxRows: Int?) -> QueryResult {
        let wantsPairs = pairCommands.contains(name)
            || command.contains { $0.uppercased() == "WITHSCORES" }
        let isNested = elements.contains { if case .array = $0 { true } else { false } }

        var columns: [ColumnDescriptor]
        var rows: [[Cell]]

        if isNested {
            // Array of arrays (XRANGE, GEOPOS, …): one row per element, columns
            // sized to the widest row.
            let unpacked = elements.map { element -> [Cell] in
                if case .array(let inner) = element, let inner {
                    return inner.map { Cell(flatten($0)) }
                }
                return [Cell(element.displayText)]
            }
            let width = max(1, unpacked.map(\.count).max() ?? 1)
            columns = (0..<width).map { ColumnDescriptor(name: "v\($0 + 1)", typeName: "string") }
            rows = unpacked.map { row in
                row + Array(repeating: Cell(nil), count: width - row.count)
            }
        } else if wantsPairs, elements.count.isMultiple(of: 2) {
            let isScores = command.contains { $0.uppercased() == "WITHSCORES" }
            columns = [
                ColumnDescriptor(name: isScores ? "member" : "field", typeName: "string"),
                ColumnDescriptor(name: isScores ? "score" : "value", typeName: "string"),
            ]
            rows = stride(from: 0, to: elements.count, by: 2).map {
                [Cell(elements[$0].displayText), Cell(elements[$0 + 1].displayText)]
            }
        } else {
            columns = [ColumnDescriptor(name: "value", typeName: "string")]
            rows = elements.map { [Cell($0.displayText ?? flatten($0))] }
        }

        var truncated = false
        if let maxRows, rows.count > maxRows {
            rows = Array(rows.prefix(maxRows))
            truncated = true
        }
        return QueryResult(columns: columns, rows: rows,
                           isTruncated: truncated, returnsRows: true)
    }

    /// A one-line rendering for a nested value that has to fit a single cell.
    private static func flatten(_ value: RESPValue) -> String {
        switch value {
        case .array(let inner):
            guard let inner else { return "(nil)" }
            return inner.map { $0.displayText ?? flatten($0) }.joined(separator: " ")
        default:
            return value.displayText ?? "(nil)"
        }
    }
}
