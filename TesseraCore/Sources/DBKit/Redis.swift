import Foundation

/// One key in a SCAN page: name, type and remaining TTL.
public struct RedisKeyInfo: Sendable, Equatable {
    public var key: String
    /// Redis TYPE reply: string, list, set, zset, hash, stream, …
    public var type: String
    /// Seconds until expiry; nil when the key has no TTL.
    public var ttlSeconds: Int?

    public init(key: String, type: String, ttlSeconds: Int? = nil) {
        self.key = key
        self.type = type
        self.ttlSeconds = ttlSeconds
    }
}

/// The key-value side of a Redis connection — what the key browser needs beyond
/// the plain command console.
public protocol KeyValueDriver: Sendable {
    /// One SCAN page: keys matching `pattern` from `cursor` ("0" starts), each
    /// enriched with TYPE and TTL. The returned cursor is "0" when done.
    func scanKeys(matching pattern: String, cursor: String,
                  count: Int) async throws -> (cursor: String, keys: [RedisKeyInfo])
    /// Deletes the keys; returns how many existed.
    func deleteKeys(_ keys: [String]) async throws -> Int
}

/// Pure helpers for the Redis console and key browser: command-line tokenizing,
/// key quoting, and the read command each key type opens with. No I/O — all of
/// this is unit-tested.
public enum RedisCommandLine {
    /// Splits a typed command line into arguments, redis-cli style: whitespace
    /// separates, double quotes group (with \\, \", \n, \r, \t escapes), single
    /// quotes group literally. Nil for an unbalanced quote — the caller should
    /// show an error rather than guess.
    public static func tokenize(_ line: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var started = false
        var iterator = line.makeIterator()
        var pending: Character? = nil

        func next() -> Character? {
            if let c = pending { pending = nil; return c }
            return iterator.next()
        }

        while let c = next() {
            if c.isWhitespace {
                if started { tokens.append(current); current = ""; started = false }
                continue
            }
            started = true
            switch c {
            case "\"":
                var closed = false
                while let inner = next() {
                    if inner == "\"" { closed = true; break }
                    if inner == "\\" {
                        guard let escaped = next() else { return nil }
                        switch escaped {
                        case "n": current.append("\n")
                        case "r": current.append("\r")
                        case "t": current.append("\t")
                        default: current.append(escaped)
                        }
                    } else {
                        current.append(inner)
                    }
                }
                guard closed else { return nil }
            case "'":
                var closed = false
                while let inner = next() {
                    if inner == "'" { closed = true; break }
                    current.append(inner)
                }
                guard closed else { return nil }
            default:
                current.append(c)
            }
        }
        if started { tokens.append(current) }
        return tokens
    }

    /// The command line the cursor sits on — the console's run unit for Redis,
    /// which has no semicolon-separated statements. `cursor` is a UTF-16 offset
    /// (what the editor reports), clamped into bounds.
    public static func lineUnderCursor(in text: String, cursor: Int) -> String {
        let ns = text as NSString
        let clamped = min(max(cursor, 0), ns.length)
        let range = ns.lineRange(for: NSRange(location: clamped, length: 0))
        return ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A script's run units: one command per non-empty line.
    public static func scriptLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Quotes a key for use in a typed command line when it needs it.
    public static func quoteKey(_ key: String) -> String {
        guard key.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" }) || key.isEmpty
        else { return key }
        return "\"" + key
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The command a key of `type` opens with in a console tab — bounded reads
    /// for the collection types so a huge value can't flood the grid.
    public static func readCommand(key: String, type: String, limit: Int = 500) -> String {
        let quoted = quoteKey(key)
        switch type.lowercased() {
        case "string": return "GET \(quoted)"
        case "list": return "LRANGE \(quoted) 0 \(limit - 1)"
        case "hash": return "HGETALL \(quoted)"
        case "set": return "SMEMBERS \(quoted)"
        case "zset": return "ZRANGE \(quoted) 0 \(limit - 1) WITHSCORES"
        case "stream": return "XRANGE \(quoted) - + COUNT \(limit)"
        default: return "TYPE \(quoted)"
        }
    }
}

/// Renders Redis data into the grid's `QueryResult` shape — pure and tested,
/// like the SQL-side display helpers.
public enum RedisGridDisplay {
    /// The key browser's page: key / type / TTL columns.
    public static func keyListResult(_ keys: [RedisKeyInfo], truncated: Bool) -> QueryResult {
        QueryResult(
            columns: [
                ColumnDescriptor(name: "key", typeName: "string"),
                ColumnDescriptor(name: "type", typeName: "string"),
                ColumnDescriptor(name: "ttl", typeName: "int"),
            ],
            rows: keys.map {
                [Cell($0.key), Cell($0.type), Cell($0.ttlSeconds.map(String.init))]
            },
            isTruncated: truncated,
            returnsRows: true)
    }
}
