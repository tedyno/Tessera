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
        /// One statement may cover several rows (same change-set → one
        /// `WHERE pk IN (…)`); discarding reverts them together.
        case update(rows: [Int])
        case delete(rows: [Int])
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
    /// A tab is a SQL console (editor + result), a data view opened from the
    /// schema tree (grid + filter + pagination, no SQL editor), or an ER
    /// diagram of one schema (canvas, no SQL at all).
    enum Kind: Equatable { case console, data, diagram }

    /// Increment for infinite scroll / "Load more" — how many extra rows each
    /// auto-fetch pulls.
    static let pageSize = 200
    /// Safety ceiling on a data view's Limit, so an accidental huge value can't
    /// pull enough rows to exhaust memory. Explicit limits below this are honored.
    static let maxPageLimit = 1_000_000
    /// The starting Limit for a freshly opened data view: the "Default row limit"
    /// setting, clamped to the ceiling. The setting's `0` means "no console cap" —
    /// a table view can't show zero rows, so it falls back to a sensible page and
    /// relies on infinite scroll for the rest.
    static var defaultPageLimit: Int {
        let setting = ExportSettings.maxRows
        return setting > 0 ? min(setting, maxPageLimit) : pageSize * 5
    }
    /// Clamps a user-entered Limit to `1...maxPageLimit`.
    static func clampedPageLimit(_ value: Int) -> Int { min(max(1, value), maxPageLimit) }

    let id = UUID()
    var title: String
    var sql: String

    /// The live connection this tab runs against. Tabs from different connections
    /// coexist, each querying its own database.
    var session: ConnectionSession?

    var kind: Kind = .console
    /// ER-diagram state (only used when `kind == .diagram`).
    var diagram: DiagramModel?
    /// Data-view source table and paging state (only used when `kind == .data`).
    var dataSchema: String?
    var dataTable: String?
    var filterWhere = ""
    var pageLimit = QueryTab.defaultPageLimit
    /// Total row count for the current filter (`SELECT count(*)`), if known.
    var totalRows: Int?
    var result: QueryResult?
    /// Bumped whenever a fresh result replaces the old one (new query, sort, filter,
    /// page). Lets the grid reset cell selection only on genuinely new data, not on
    /// the re-renders that follow an in-place cell edit.
    var resultVersion = 0
    var elapsedMS: Int?
    var isRunning = false
    /// Whether more rows exist beyond what's loaded — drives "Load more" and the
    /// infinite-scroll auto-fetch. Set from the last fetch's truncation.
    var hasMoreRows = false
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

    /// True when a result with columns is on screen but can't be edited in place
    /// because it isn't a single-table SELECT (a join/aggregate). Drives the
    /// status-bar hint that explains why editing is unavailable — otherwise a
    /// double-click that does nothing looks like a bug. A DML result (no columns)
    /// has no grid to edit.
    var resultIsReadOnly: Bool {
        guard let result else { return false }
        return editSource == nil && !result.columns.isEmpty
    }

    /// One undoable step of the grid's pending-change state. Row indices inside are
    /// only valid against the result they were captured on, so the history is
    /// cleared whenever a fresh result replaces it.
    private struct GridEditState {
        var edits: [Int: [String: String?]]
        var pendingDeletes: Set<Int>
        var pendingInserts: [PendingInsert]
    }
    private var undoStack: [GridEditState] = []
    private var redoStack: [GridEditState] = []

    var canUndoEdits: Bool { !undoStack.isEmpty }
    var canRedoEdits: Bool { !redoStack.isEmpty }

    /// Call before any mutation of edits/deletes/inserts.
    func captureEditSnapshot() {
        undoStack.append(GridEditState(edits: edits, pendingDeletes: pendingDeletes,
                                       pendingInserts: pendingInserts))
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undoEdits() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(GridEditState(edits: edits, pendingDeletes: pendingDeletes,
                                       pendingInserts: pendingInserts))
        apply(previous)
    }

    func redoEdits() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(GridEditState(edits: edits, pendingDeletes: pendingDeletes,
                                       pendingInserts: pendingInserts))
        apply(next)
    }

    func clearEditHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// Rolls back to the last snapshot without pushing the current state onto the
    /// redo stack — for cancelling a live-preview session, whose half-typed state
    /// must not be resurrectable via redo.
    func revertLastSnapshot() {
        guard let previous = undoStack.popLast() else { return }
        apply(previous)
    }

    private func apply(_ state: GridEditState) {
        edits = state.edits
        pendingDeletes = state.pendingDeletes
        pendingInserts = state.pendingInserts
    }

    /// One column of a multi-column server-side sort.
    struct SortKey: Equatable, Hashable, Sendable {
        var column: String
        var ascending: Bool
    }

    /// Active header sort on a full-table view (empty = unsorted), in priority
    /// order: the first key is the primary sort, the next breaks its ties, and so
    /// on. Clicking a header cycles that column ascending → descending → off, and a
    /// column not yet in the list is appended as the next-lowest priority.
    var sortOrder: [SortKey] = []

    /// Client-side header sort of an arbitrary query result: a display-order
    /// permutation of the fetched rows, no re-query. Column index into
    /// `result.columns`; the same click cycle as the server-side sort.
    var localSortColumn: Int?
    var localSortAscending = true

    /// Local per-column value filters (header right-click): column name →
    /// allowed raw values (nil = NULL). Rows are hidden client-side; empty
    /// dictionary means no filtering.
    var localValueFilters: [String: Set<String?>] = [:]

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

    /// The explain request a result should be interpreted against. Armed by
    /// `explainActiveQuery` before dispatching; `run()` promotes it to
    /// `currentPlan` only when the executed SQL matches exactly, so a cancelled
    /// destructive-confirm or an interleaved normal run can never mislabel an
    /// ordinary result as a plan.
    struct PlanExpectation: Equatable {
        var sql: String
        var format: ExplainPlanFormat
        var analyze: Bool
    }
    var expectedPlan: PlanExpectation?
    var currentPlan: PlanExpectation?
    /// User flipped the plan view's Tree/Raw toggle to the raw server output.
    var showRawPlan = false

    /// Caret offset in the editor, used to run the statement under the cursor.
    var cursorPosition = 0
    /// Set to scroll the results grid to a column by name after a query runs.
    var scrollToColumn: String?

    /// The single selected cell mirrored for the value inspector (nil = no single
    /// selection). Set by the grid, read by the inspector panel.
    var inspected: InspectedCell?

    /// A cell opened in the multiline value-editor sheet — long JSON/text values
    /// are unwieldy in the single-line in-cell field. Set by the grid (⇧↩,
    /// context menu, or double-clicking a multiline value); presented by the
    /// detail view.
    var valueEditor: ValueEditorTarget?

    /// Seconds between automatic re-runs of this tab (nil = off).
    var autoRefreshInterval: TimeInterval?
    @ObservationIgnored var autoRefreshTask: Task<Void, Never>?

    /// True while a grid cell is being edited — auto-refresh must not replace the
    /// result mid-session, or the edit would commit against shifted row indices.
    var isEditingCell = false

    /// The in-flight run, so a Stop button can cancel it.
    @ObservationIgnored var task: Task<Void, Never>?

    init(title: String, sql: String = "") {
        self.title = title
        self.sql = sql
    }

    /// Writes one value into one cell by data-row index (nil = SQL NULL),
    /// mirroring how the grid records a manual edit: insert rows update their
    /// pending values, fetched rows record an edit — dropped again when the
    /// value matches the fetched original.
    func setValue(_ value: String?, row: Int, columnName: String) {
        guard let result else { return }
        guard editSource?.autoIncrementColumns.contains(columnName) != true else { return }
        let fetchedCount = result.rows.count
        if row >= fetchedCount {
            let index = row - fetchedCount
            guard index < pendingInserts.count else { return }
            pendingInserts[index].values[columnName] = value   // nil → column omitted
            return
        }
        guard row >= 0, row < fetchedCount,
              let col = result.columns.firstIndex(where: { $0.name == columnName }) else { return }
        let cells = result.rows[row]
        let original = col < cells.count ? cells[col].text : nil
        if let value {
            if original != nil, value == original {
                edits[row]?[columnName] = nil
                if edits[row]?.isEmpty == true { edits[row] = nil }
            } else {
                edits[row, default: [:]][columnName] = value
            }
        } else if original == nil {
            // Already NULL — drop any pending edit instead of recording a no-op.
            edits[row]?[columnName] = nil
            if edits[row]?.isEmpty == true { edits[row] = nil }
        } else {
            edits[row, default: [:]].updateValue(nil, forKey: columnName)
        }
    }
}

/// A cell opened in the multiline value editor (`QueryTab.valueEditor`).
struct ValueEditorTarget: Identifiable, Equatable {
    let id = UUID()
    /// Data-row index (insert rows continue past the fetched rows).
    var row: Int
    var columnName: String
    var typeName: String
    /// Current value with pending edits applied; "" when NULL (`isNull` marks it).
    var text: String
    var isNull: Bool
    /// False on a read-only result — the sheet then only views the value.
    var isEditable: Bool
    /// On a pending-insert row an unset column means "database default", not
    /// NULL — the sheet labels the empty state accordingly.
    var isInsertRow: Bool
    /// The tab's `resultVersion` at open time; a save against a replaced result
    /// would target the wrong row and is dropped.
    var resultVersion: Int
}
