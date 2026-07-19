import Foundation
import DBKit

/// The single source table a result maps to, enabling in-place editing.
struct EditSource: Equatable {
    var schema: String
    var table: String
    var primaryKeys: [String]
}

/// One query tab: its own editor text and result, sharing the connection's driver.
@MainActor
@Observable
final class QueryTab: Identifiable {
    let id = UUID()
    var title: String
    var sql: String
    var result: QueryResult?
    var elapsedMS: Int?
    var isRunning = false
    var errorMessage: String?

    /// Set when the result maps to a single table with a primary key; enables
    /// editing. `edits` holds pending, unsaved cell changes: row → column → value.
    var editSource: EditSource?
    var edits: [Int: [String: String]] = [:]
    /// Row indices marked for deletion (Backspace on a selected row).
    var pendingDeletes: Set<Int> = []

    var hasEdits: Bool { !edits.isEmpty || !pendingDeletes.isEmpty }
    var isEditable: Bool { editSource != nil }

    /// Caret offset in the editor, used to run the statement under the cursor.
    var cursorPosition = 0
    /// Set to scroll the results grid to a column by name after a query runs.
    var scrollToColumn: String?

    /// The in-flight run, so a Stop button can cancel it.
    @ObservationIgnored var task: Task<Void, Never>?

    init(title: String, sql: String = "") {
        self.title = title
        self.sql = sql
    }
}
