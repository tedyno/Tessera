import Foundation

/// Classification of SQL column types, shared by the results grid and the MCP
/// server so both agree on what counts as a number.
public enum SQLTypes {
    /// Column types whose values read as numbers. Exact matches only, so `interval`,
    /// `inet`, or `text` are never caught by a prefix.
    private static let numeric: Set<String> = [
        // PostgreSQL
        "int2", "int4", "int8", "smallint", "integer", "bigint",
        "serial", "bigserial", "smallserial", "serial2", "serial4", "serial8",
        "numeric", "decimal", "real", "double precision", "float4", "float8", "money", "oid",
        // MySQL wire-protocol names (what the driver reports on query results)
        "tiny", "short", "int24", "long", "longlong", "float", "double", "newdecimal", "year",
        // MySQL information_schema names (what introspection reports — used when an
        // empty result falls back to schema-derived columns). `bit` is deliberately
        // absent: its values render as binary strings, not bare numbers.
        "int", "tinyint", "mediumint",
    ]

    public static func isNumeric(_ typeName: String) -> Bool {
        numeric.contains(typeName.lowercased())
    }

    /// A SQL literal for a cell value: `NULL`, an unquoted number for numeric columns,
    /// or a single-quoted, quote-escaped string. Used for generated filters and for
    /// "Copy as SQL INSERT".
    public static func literal(_ value: String?, typeName: String) -> String {
        guard let value else { return "NULL" }
        if isNumeric(typeName) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
