import Foundation
import DBKit

/// The single source table a result maps to, enabling in-place editing.
struct EditSource: Equatable {
    var schema: String
    var table: String
    var primaryKeys: [String]
    /// Columns the database fills itself (serial/identity/AUTO_INCREMENT); inserts
    /// omit them and the grid shows a "(generated)" placeholder.
    var autoIncrementColumns: [String]
}

/// The cell shown in the value inspector when exactly one cell is selected.
struct InspectedCell: Equatable {
    var column: String
    var typeName: String
    /// nil means SQL NULL (distinct from an empty string).
    var value: String?
}

/// A new row queued for insertion. `values` holds only the columns the user set;
/// unset (and auto-increment) columns are left to the database.
struct PendingInsert: Identifiable, Equatable {
    let id = UUID()
    var values: [String: String] = [:]
}

/// One revertible entry shown in the pending-changes panel (one per row).
struct PendingChange: Identifiable {
    enum Target: Equatable {
        case update(row: Int)
        case delete(row: Int)
        case insert(id: UUID)
    }
    let id: String
    let target: Target
    let statement: String
}

/// One query tab: its own editor text and result, sharing the connection's driver.
@MainActor
@Observable
final class QueryTab: Identifiable {
    /// A tab is either a SQL console (editor + result) or a data view opened from
    /// the schema tree (grid + filter + pagination, no SQL editor).
    enum Kind: Equatable { case console, data }

    /// Default page size for data views; "Load more" grows the LIMIT by this.
    static let pageSize = 200

    let id = UUID()
    var title: String
    var sql: String

    /// The live connection this tab runs against. Tabs from different connections
    /// coexist, each querying its own database.
    var session: ConnectionSession?

    var kind: Kind = .console
    /// Data-view source table and paging state (only used when `kind == .data`).
    var dataSchema: String?
    var dataTable: String?
    var filterWhere = ""
    var pageLimit = QueryTab.pageSize
    /// Total row count for the current filter (`SELECT count(*)`), if known.
    var totalRows: Int?
    var result: QueryResult?
    /// Bumped whenever a fresh result replaces the old one (new query, sort, filter,
    /// page). Lets the grid reset cell selection only on genuinely new data, not on
    /// the re-renders that follow an in-place cell edit.
    var resultVersion = 0
    var elapsedMS: Int?
    var isRunning = false
    var errorMessage: String?
    /// Summary after running a multi-statement script (e.g. "Executed 12 statements").
    var scriptSummary: String?

    /// Set when the result maps to a single table with a primary key; enables
    /// editing. `edits` holds pending, unsaved cell changes: row → column → value,
    /// where an inner `nil` value means "set to SQL NULL" (distinct from removing
    /// the entry, which reverts the cell — use `updateValue(nil,…)` to set NULL,
    /// since plain subscript assignment of nil removes the key).
    var editSource: EditSource?
    var edits: [Int: [String: String?]] = [:]
    /// Row indices marked for deletion (Backspace on a selected row).
    var pendingDeletes: Set<Int> = []
    /// New rows queued for insertion, rendered below the fetched rows.
    var pendingInserts: [PendingInsert] = []

    var hasEdits: Bool { !edits.isEmpty || !pendingDeletes.isEmpty || !pendingInserts.isEmpty }
    var isEditable: Bool { editSource != nil }

    /// Active header sort on a full-table view (nil = unsorted). Clicking a header
    /// cycles ascending → descending → off.
    var sortColumn: String?
    var sortAscending = true

    /// ⌘F row filter over the current result: hides non-matching rows client-side,
    /// without re-running the query. Empty = no filter. Escape clears it.
    var searchQuery = ""
    var isSearchBarVisible = false

    /// Data-row indices matching `searchQuery` (checked case-insensitively against
    /// fetched cells and any pending edit); nil when there's no active filter.
    func matchingRowIndices() -> [Int]? {
        guard !searchQuery.isEmpty, let result else { return nil }
        return result.rows.indices.filter { index in
            if result.rows[index].contains(where: { $0.text?.localizedCaseInsensitiveContains(searchQuery) == true }) {
                return true
            }
            return edits[index]?.values.contains(where: { $0?.localizedCaseInsensitiveContains(searchQuery) == true }) == true
        }
    }

    func clearSearch() {
        searchQuery = ""
        isSearchBarVisible = false
    }

    /// Caret offset in the editor, used to run the statement under the cursor.
    var cursorPosition = 0
    /// Set to scroll the results grid to a column by name after a query runs.
    var scrollToColumn: String?

    /// The single selected cell mirrored for the value inspector (nil = no single
    /// selection). Set by the grid, read by the inspector panel.
    var inspected: InspectedCell?

    /// Seconds between automatic re-runs of this tab (nil = off).
    var autoRefreshInterval: TimeInterval?
    @ObservationIgnored var autoRefreshTask: Task<Void, Never>?

    /// The in-flight run, so a Stop button can cancel it.
    @ObservationIgnored var task: Task<Void, Never>?

    init(title: String, sql: String = "") {
        self.title = title
        self.sql = sql
    }
}
