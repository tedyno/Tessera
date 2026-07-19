import Foundation

/// Classifies SQL arriving from an MCP client (i.e. an LLM) as read-only or writing.
/// Reads run straight through; writes need explicit human approval, and are refused
/// outright on a connection the user marked read-only.
///
/// Read-only is decided by a **whitelist** — only known read shapes with no writing
/// keywords qualify. Anything else counts as a write, so an unfamiliar or obfuscated
/// statement errs towards asking the user rather than silently running.
public enum MCPSQLPolicy {
    public enum Access: Equatable, Sendable {
        case readOnly
        /// Writes, DDL, or anything not provably read-only.
        case write
    }

    public struct Rejection: Error, Equatable, Sendable {
        public let reason: String
        public init(_ reason: String) { self.reason = reason }
    }

    /// Statement kinds that only read.
    private static let readOnlyStarts = [
        "SELECT", "WITH", "EXPLAIN", "SHOW", "TABLE", "VALUES", "DESCRIBE", "DESC",
    ]

    /// Keywords that mean the statement writes, changes structure, or escapes to the
    /// filesystem (`SELECT … INTO OUTFILE`, `COPY … TO PROGRAM`).
    private static let writeKeywords = [
        "INSERT", "UPDATE", "DELETE", "MERGE", "UPSERT", "REPLACE",
        "DROP", "CREATE", "ALTER", "TRUNCATE", "RENAME",
        "GRANT", "REVOKE", "COPY", "INTO", "CALL", "EXECUTE", "PREPARE",
        "LOCK", "VACUUM", "REINDEX", "REFRESH", "ATTACH", "LOAD", "HANDLER",
    ]

    /// The single statement plus how it must be treated. Multiple statements are
    /// refused so `SELECT 1; DROP TABLE t` can't hide a write behind a read.
    public static func classify(_ sql: String) throws -> (statement: String, access: Access) {
        let statements = SQLScript.statements(in: sql)
        guard !statements.isEmpty else { throw Rejection("The query is empty.") }
        guard statements.count == 1 else {
            throw Rejection("Only a single statement is allowed (got \(statements.count)).")
        }
        let statement = statements[0]
        // Match against a copy with strings/comments blanked, so keywords hidden in
        // literals neither trigger nor evade the checks.
        let masked = SQLText.maskLiteralsAndComments(statement)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let startsRead = readOnlyStarts.contains {
            masked.range(of: "^\\s*\($0)\\b", options: [.regularExpression, .caseInsensitive]) != nil
        }
        let mentionsWrite = writeKeywords.contains {
            masked.range(of: "\\b\($0)\\b", options: [.regularExpression, .caseInsensitive]) != nil
        }
        return (statement, startsRead && !mentionsWrite ? .readOnly : .write)
    }

    public static func isReadOnly(_ sql: String) -> Bool {
        (try? classify(sql))?.access == .readOnly
    }
}
