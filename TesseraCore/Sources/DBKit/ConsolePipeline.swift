import Foundation

/// Everything about how an engine's console turns editor text into runnable
/// commands — one strategy object instead of engine checks scattered through
/// the run pipeline. SQL engines share `SQLConsolePipeline`; Redis runs
/// line-based commands and skips every SQL-only scan. Routing each step
/// through here means a non-SQL engine can never silently inherit a step that
/// misreads its syntax (a `:` in a Redis key is not a parameter placeholder).
public protocol ConsolePipeline: Sendable {
    /// The run unit at the cursor (⌘↩): a `;`-delimited statement for SQL, the
    /// current line for Redis.
    func runTarget(in text: String, cursor: Int) -> SQLRunTarget
    /// A whole script's run units, in order.
    func scriptStatements(in text: String) -> [String]
    /// Client-side placeholders whose values must be collected before running.
    func parameterNames(in statement: String) -> [String]
    /// Substitutes collected placeholder values as literals.
    func substituteParameters(in statement: String, values: [String: String]) -> String
    /// Destructive-statement warnings that need explicit confirmation.
    func safetyWarnings(in statement: String) -> [SQLSafety.Warning]
    /// Final rewrite before execution — bare-value auto-quoting for SQL, a
    /// passthrough for engines whose commands must run exactly as typed.
    func rewriteForRun(_ statement: String, completion: SQLCompletionEngine?) -> String
    /// Whether the engine produces query plans (drives the Explain UI).
    var supportsExplain: Bool { get }
}

/// The SQL engines' console behavior. `backslashEscapes` mirrors MySQL's
/// string-literal escaping for parameter scanning and substitution.
public struct SQLConsolePipeline: ConsolePipeline {
    let backslashEscapes: Bool

    public init(backslashEscapes: Bool) {
        self.backslashEscapes = backslashEscapes
    }

    public func runTarget(in text: String, cursor: Int) -> SQLRunTarget {
        SQLStatements.resolve(sql: text, cursor: cursor)
    }

    public func scriptStatements(in text: String) -> [String] {
        SQLScript.statements(in: text)
    }

    public func parameterNames(in statement: String) -> [String] {
        QueryParameters.names(in: statement, backslashEscapes: backslashEscapes)
    }

    public func substituteParameters(in statement: String,
                                     values: [String: String]) -> String {
        QueryParameters.substitute(statement, values: values,
                                   backslashEscapes: backslashEscapes)
    }

    public func safetyWarnings(in statement: String) -> [SQLSafety.Warning] {
        SQLSafety.warnings(in: statement)
    }

    public func rewriteForRun(_ statement: String,
                              completion: SQLCompletionEngine?) -> String {
        guard let completion else { return statement }
        return SQLAutoQuote.quoted(statement, scope: completion.statementScope(statement))
    }

    public var supportsExplain: Bool { true }
}

/// Redis: commands are lines, run exactly as typed. No placeholders (colons
/// are key syntax), no SQL safety scan, no plans.
public struct RedisConsolePipeline: ConsolePipeline {
    public init() {}

    public func runTarget(in text: String, cursor: Int) -> SQLRunTarget {
        let line = RedisCommandLine.lineUnderCursor(in: text, cursor: cursor)
        return .statement(line.isEmpty
            ? (RedisCommandLine.scriptLines(text).first ?? "") : line)
    }

    public func scriptStatements(in text: String) -> [String] {
        RedisCommandLine.scriptLines(text)
    }

    public func parameterNames(in statement: String) -> [String] { [] }

    public func substituteParameters(in statement: String,
                                     values: [String: String]) -> String { statement }

    public func safetyWarnings(in statement: String) -> [SQLSafety.Warning] { [] }

    public func rewriteForRun(_ statement: String,
                              completion: SQLCompletionEngine?) -> String { statement }

    public var supportsExplain: Bool { false }
}

public extension DatabaseKind {
    /// The console strategy for this engine.
    var consolePipeline: any ConsolePipeline {
        isKeyValue
            ? RedisConsolePipeline()
            // `backslashEscapes` deliberately excludes MariaDB, matching the
            // long-standing app behavior (only plain MySQL got the treatment).
            : SQLConsolePipeline(backslashEscapes: self == .mysql)
    }
}
