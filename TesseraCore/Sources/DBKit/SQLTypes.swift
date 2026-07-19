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
        // MySQL
        "tiny", "short", "int24", "long", "longlong", "float", "double", "newdecimal", "year",
    ]

    public static func isNumeric(_ typeName: String) -> Bool {
        numeric.contains(typeName.lowercased())
    }
}
