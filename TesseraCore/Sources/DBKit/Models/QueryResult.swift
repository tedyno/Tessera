import Foundation

/// Describes a single column of a query result.
public struct ColumnDescriptor: Sendable, Hashable {
    public var name: String
    /// Display name of the DB type (e.g. `int8`, `text`, `numeric`).
    public var typeName: String

    public init(name: String, typeName: String) {
        self.name = name
        self.typeName = typeName
    }
}

/// A single result cell. The value is pre-rendered to text for cheap drawing;
/// `nil` means SQL `NULL` (distinct from an empty string).
public struct Cell: Sendable, Hashable {
    public var text: String?

    public var isNull: Bool { text == nil }

    public init(_ text: String?) {
        self.text = text
    }

    public static let null = Cell(nil)
}

/// Buffered query result (MVP). A streamed variant (`QueryHandle` backed by an
/// `AsyncSequence`) arrives in Phase 8 to handle large result sets.
public struct QueryResult: Sendable {
    public var columns: [ColumnDescriptor]
    public var rows: [[Cell]]
    /// Number of affected rows for DML (INSERT/UPDATE/DELETE), otherwise `nil`.
    public var rowsAffected: Int?
    /// Client-side query execution time.
    public var elapsed: Duration?
    /// True when the driver stopped at the row limit and more rows exist on the
    /// server — the grid shows only what was fetched.
    public var isTruncated: Bool
    /// True when the statement is row-returning (a SELECT and friends), even if it
    /// matched zero rows. Distinguishes an empty SELECT — which should show the grid
    /// headers and a "No results" state — from a command (INSERT/UPDATE/DDL) that
    /// legitimately produces no result set. Some drivers (MySQL) can't report the
    /// columns of a zero-row SELECT, so this flag carries the intent even when
    /// `columns` is empty.
    public var returnsRows: Bool

    public init(
        columns: [ColumnDescriptor] = [],
        rows: [[Cell]] = [],
        rowsAffected: Int? = nil,
        elapsed: Duration? = nil,
        isTruncated: Bool = false,
        returnsRows: Bool = false
    ) {
        self.columns = columns
        self.rows = rows
        self.rowsAffected = rowsAffected
        self.elapsed = elapsed
        self.isTruncated = isTruncated
        self.returnsRows = returnsRows
    }
}
