import Foundation

/// Pure text helpers for the SQL editor and data-view filter, kept in the core so
/// they can be unit-tested (the AppKit editors that use them can't be).
public enum SQLText {
    /// True when the end of `prefix` sits inside an unclosed single-quoted string
    /// literal (odd number of `'`). Used to suppress autocomplete inside values,
    /// so typing `'Li%'` isn't turned into `LIKE`.
    public static func isInsideStringLiteral(_ prefix: String) -> Bool {
        prefix.reduce(0) { $1 == "'" ? $0 + 1 : $0 } % 2 == 1
    }

    /// True when `replacement` differs from `existing` only by letter case — the
    /// signature of automatic capitalization/autocorrect, which we reject so typed
    /// SQL isn't "corrected" (`li` → `Li`).
    public static func isCaseOnlyChange(from existing: String, to replacement: String) -> Bool {
        existing != replacement && existing.lowercased() == replacement.lowercased()
    }

    /// Candidates in `pool` that continue `partial` (case-insensitive prefix),
    /// excluding an exact match. Input order is preserved.
    public static func completions(for partial: String, in pool: [String]) -> [String] {
        let lower = partial.lowercased()
        guard !lower.isEmpty else { return [] }
        return pool.filter { $0.lowercased().hasPrefix(lower) && $0.lowercased() != lower }
    }
}
