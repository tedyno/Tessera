import Foundation

/// Flags statements that can destroy a lot of data, so the UI can confirm first.
public enum SQLSafety {
    public enum Risk: String, Sendable, Equatable {
        case deleteWithoutWhere
        case updateWithoutWhere
        case drop
        case truncate
        /// Redis FLUSHDB/FLUSHALL — wipes the whole keyspace.
        case flush

        /// A short, user-facing description of what the statement will do.
        public var explanation: String {
            switch self {
            case .deleteWithoutWhere: "DELETE without WHERE — removes every row in the table."
            case .updateWithoutWhere: "UPDATE without WHERE — rewrites every row in the table."
            case .drop: "DROP — permanently removes the object and its data."
            case .truncate: "TRUNCATE — empties the table."
            case .flush: "FLUSH — removes every key in the database."
            }
        }
    }

    public struct Warning: Sendable, Equatable, Identifiable {
        public let risk: Risk
        public let statement: String
        public var id: String { "\(risk.rawValue)|\(statement)" }
    }

    /// Every destructive statement in `sql`. String literals and comments are ignored,
    /// so `-- DROP TABLE x` or `'delete from'` don't trigger a false alarm.
    public static func warnings(in sql: String) -> [Warning] {
        SQLScript.statements(in: sql).compactMap { statement in
            let masked = SQLText.maskLiteralsAndComments(statement)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let risk = risk(of: masked) else { return nil }
            return Warning(risk: risk, statement: statement.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func risk(of masked: String) -> Risk? {
        func matches(_ pattern: String) -> Bool {
            masked.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        if matches(#"^\s*DROP\s+(TABLE|DATABASE|SCHEMA|VIEW|INDEX|SEQUENCE)\b"#) { return .drop }
        if matches(#"^\s*TRUNCATE\b"#) { return .truncate }
        if matches(#"^\s*DELETE\s+FROM\b"#), !matches(#"\bWHERE\b"#) { return .deleteWithoutWhere }
        if matches(#"^\s*UPDATE\b"#), !matches(#"\bWHERE\b"#) { return .updateWithoutWhere }
        return nil
    }
}
