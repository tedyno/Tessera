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

/// Buffered query result for the grid. Large result sets that must not buffer
/// (exports) go through `DatabaseDriver.stream(_:batchSize:into:)` + `RowSink`
/// instead and never build one of these.
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
    /// True when the reply *is* one value rather than a table that happens to be
    /// one cell wide — a key-value GET, not a one-element LRANGE. Only a driver
    /// whose protocol distinguishes the two sets it (Redis does: a bulk string is
    /// a different reply type than an array), so the UI can render such a value as
    /// a document without mistaking a one-row collection for it.
    public var isSingleValue: Bool

    public init(
        columns: [ColumnDescriptor] = [],
        rows: [[Cell]] = [],
        rowsAffected: Int? = nil,
        elapsed: Duration? = nil,
        isTruncated: Bool = false,
        returnsRows: Bool = false,
        isSingleValue: Bool = false
    ) {
        self.columns = columns
        self.rows = rows
        self.rowsAffected = rowsAffected
        self.elapsed = elapsed
        self.isTruncated = isTruncated
        self.returnsRows = returnsRows
        self.isSingleValue = isSingleValue
    }
}
