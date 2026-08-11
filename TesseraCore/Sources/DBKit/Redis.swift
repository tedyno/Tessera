import Foundation

/// One key in a SCAN page: name, type, remaining TTL, and a cheap value glimpse.
public struct RedisKeyInfo: Sendable, Equatable {
    public var key: String
    /// Redis TYPE reply: string, list, set, zset, hash, stream, …
    public var type: String
    /// Seconds until expiry; nil when the key has no TTL.
    public var ttlSeconds: Int?
    /// Element count (HLEN/LLEN/SCARD/ZCARD/XLEN) or a string's byte length.
    public var size: Int?
    /// For string keys, the value's first bytes ("…"-suffixed when truncated).
    public var preview: String?

    public init(key: String, type: String, ttlSeconds: Int? = nil,
                size: Int? = nil, preview: String? = nil) {
        self.key = key
        self.type = type
        self.ttlSeconds = ttlSeconds
        self.size = size
        self.preview = preview
    }
}

/// The numeric database a Redis profile points at, held in `ConnectionProfile`
/// as text like every other engine's database field.
public enum RedisDatabaseIndex {
    /// Anything unparseable is refused rather than coerced: `Int(…) ?? 0` turned
    /// a typo — or a database *name* left over from another engine — into a
    /// silent connection to db0, where the user then browsed the wrong keyspace
    /// with nothing reported anywhere. Empty means the default, db0.
    public static func parse(_ text: String) throws -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return 0 }
        guard let index = Int(trimmed), index >= 0 else {
            throw DatabaseError.connectionFailed(
                "\"\(text)\" is not a Redis database index — use a number like 0.")
        }
        return index
    }

    /// Whether the connection form should accept the field as typed.
    public static func isValid(_ text: String) -> Bool {
        (try? parse(text)) != nil
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

public extension KeyValueDriver {
    /// A page's worth of matches, not a single SCAN.
    ///
    /// SCAN walks a slice of the keyspace per call and filters MATCH *after*
    /// picking it, so over a large keyspace a selective pattern returns empty
    /// pages for many cursors in a row. Issuing one SCAN per page therefore
    /// showed "no keys" for a filter that matches thousands, and left the user
    /// clicking "Load more" to find them.
    ///
    /// Keeps scanning until it has `target` keys or the cursor comes back to
    /// "0", but no more than `maxRounds` round trips — a pattern matching
    /// nothing at all must not stall the UI for the length of the keyspace.
    /// Stopping early just returns a non-"0" cursor, which the browser already
    /// presents as "there is more".
    func scanPage(matching pattern: String, cursor: String, target: Int,
                  maxRounds: Int = 20) async throws -> (cursor: String, keys: [RedisKeyInfo]) {
        var cursor = cursor
        var collected: [RedisKeyInfo] = []
        for _ in 0..<max(1, maxRounds) {
            let page = try await scanKeys(matching: pattern, cursor: cursor, count: target)
            collected += page.keys
            cursor = page.cursor
            if cursor == "0" || collected.count >= target { break }
        }
        return (cursor, collected)
    }
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

    /// The run unit for ⌘↩: the cursor's own line, or — on a blank line — the
    /// nearest non-empty line above (the command the user just finished
    /// typing), falling back to the first one below. Mirrors how the SQL
    /// console resolves the statement adjacent to the caret rather than
    /// jumping to the top of the buffer.
    public static func commandNearCursor(in text: String, cursor: Int) -> String {
        let line = lineUnderCursor(in: text, cursor: cursor)
        if !line.isEmpty { return line }
        let ns = text as NSString
        let clamped = min(max(cursor, 0), ns.length)
        let before = ns.substring(to: clamped)
        if let previous = scriptLines(before).last { return previous }
        return scriptLines(ns.substring(from: clamped)).first ?? ""
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
    /// The key browser's page: key / type / TTL / size / value-preview columns.
    public static func keyListResult(_ keys: [RedisKeyInfo], truncated: Bool) -> QueryResult {
        QueryResult(
            columns: [
                ColumnDescriptor(name: "key", typeName: "string"),
                ColumnDescriptor(name: "type", typeName: "string"),
                ColumnDescriptor(name: "ttl", typeName: "int"),
                ColumnDescriptor(name: "size", typeName: "int"),
                ColumnDescriptor(name: "value", typeName: "string"),
            ],
            rows: keys.map {
                [Cell($0.key), Cell($0.type), Cell($0.ttlSeconds.map(String.init)),
                 Cell($0.size.map(String.init)), Cell($0.preview)]
            },
            isTruncated: truncated,
            returnsRows: true)
    }
}
