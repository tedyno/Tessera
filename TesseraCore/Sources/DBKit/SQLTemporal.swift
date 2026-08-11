import Foundation

/// Date/time text handling for temporal columns: classification, parsing what a
/// user typed, and formatting a picked date back to SQL-friendly text. The grid's
/// date editor writes these values into the user's database, so the round-trip
/// lives in Core where it is tested — not in the AppKit coordinator.
public enum SQLTemporal {

    /// Whether a column's declared type holds dates/times (routes the cell editor
    /// through the date picker).
    public static func isTemporalType(_ typeName: String) -> Bool {
        let type = typeName.lowercased()
        return type.contains("timestamp") || type.contains("datetime")
            || type == "date" || type.hasPrefix("time")
    }

    /// Parses user-typed date/time text: ISO-8601 (with or without fractional
    /// seconds), then the common SQL spellings, date-only and time-only forms.
    /// Naive values are read as UTC so formatting them back is lossless.
    public static func parse(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }
        for pattern in ["yyyy-MM-dd HH:mm:ss.SSSZZZZZ", "yyyy-MM-dd HH:mm:ssZZZZZ",
                        "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss",
                        "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
                        "HH:mm:ss.SSS", "HH:mm:ss", "HH:mm"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = pattern
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    /// Formats a picked date for a temporal cell, in UTC. `dateParts`/`timeParts`
    /// mirror which picker elements are shown; `iso` selects the `T…Z` spelling
    /// over the SQL `yyyy-MM-dd HH:mm:ss` one for full timestamps.
    public static func format(_ date: Date, dateParts: Bool, timeParts: Bool,
                              iso: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        if dateParts, timeParts {
            formatter.dateFormat = iso ? "yyyy-MM-dd'T'HH:mm:ss'Z'" : "yyyy-MM-dd HH:mm:ss"
        } else if dateParts {
            formatter.dateFormat = "yyyy-MM-dd"
        } else {
            formatter.dateFormat = "HH:mm:ss"
        }
        return formatter.string(from: date)
    }
}
