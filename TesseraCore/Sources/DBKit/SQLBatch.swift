import Foundation

/// One statement of a selection run, with whatever came back for it. Steps are
/// built before anything executes, so the list the user confirms is exactly the
/// list that runs.
/// Not `Equatable`: it carries a `QueryResult`, whose cells are not comparable and
/// would be pointless to compare anyway — steps are identified by `number`.
public struct SQLBatchStep: Identifiable, Sendable {
    /// Position in the batch, 1-based — this is what the user sees in the list.
    public let number: Int
    public let sql: String
    public var result: QueryResult?
    public var elapsedMS: Int?
    public var errorMessage: String?
    /// False until the runner reaches it, so a batch stopped by an error shows
    /// plainly which statements never ran.
    public var didRun = false

    public var id: Int { number }

    public init(number: Int, sql: String) {
        self.number = number
        self.sql = sql
    }

    /// Leading keyword plus a condensed one-line preview, for the batch list.
    public var label: String { SQLBatch.label(for: sql) }

    /// What the row shows on the right: rows returned, or rows affected.
    public var outcome: Outcome {
        if let errorMessage { return .failed(errorMessage) }
        guard didRun else { return .pending }
        guard let result else { return .ok }
        if result.returnsRows { return .rows(result.rows.count) }
        return .affected(result.rowsAffected ?? 0)
    }

    public enum Outcome: Equatable, Sendable {
        case pending
        case ok
        case rows(Int)
        case affected(Int)
        case failed(String)
    }
}

/// Turns an editor selection into the list of statements it covers.
public enum SQLBatch {

    /// Statements fully or partly covered by `selection`, in order.
    ///
    /// The selection is taken literally — whatever the user highlighted is what
    /// runs, split on statement boundaries. A selection that lands inside a single
    /// statement yields that one fragment, which keeps "select a bit and run it"
    /// working exactly as it does today.
    public static func statements(in sql: String, selectedUTF16Range range: NSRange) -> [String] {
        guard range.length > 0, let swiftRange = Range(range, in: sql) else { return [] }
        return statements(inSelection: String(sql[swiftRange]))
    }

    /// Split of an already-extracted selection. Blank fragments — what a trailing
    /// `;` or a stray comment leaves behind — are dropped, so a tidy script does not
    /// produce a phantom final step.
    public static func statements(inSelection text: String) -> [String] {
        SQLScript.statements(in: text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !isBlank($0) }
    }

    /// Numbered steps for a selection, ready to confirm and run.
    public static func steps(in sql: String, selectedUTF16Range range: NSRange) -> [SQLBatchStep] {
        statements(in: sql, selectedUTF16Range: range).enumerated().map {
            SQLBatchStep(number: $0.offset + 1, sql: $0.element)
        }
    }

    /// A statement that is only whitespace or comments would run as an empty
    /// command; masking the comments first is what distinguishes `-- note` from a
    /// real statement that merely starts with one.
    static func isBlank(_ statement: String) -> Bool {
        let bare = SQLText.maskLiteralsAndComments(statement)
            .replacingOccurrences(of: ";", with: "")
        return bare.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One condensed line for the batch list: runs of whitespace collapsed, so a
    /// statement formatted across ten lines still reads as a single row.
    public static func label(for sql: String, limit: Int = 60) -> String {
        let flat = sql.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }
}
