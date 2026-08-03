import Foundation

/// Pure client-side display transforms for the results grid: the ⌘F row filter,
/// header value filters, and column sort. Operates on the buffered `[[Cell]]` and
/// returns data-row indices in display order, so it is unit-testable without any UI.
public enum GridDisplay {

    /// Data-row indices whose fetched cells (or pending edits) contain `query`,
    /// case-insensitively. `query` is assumed non-empty.
    public static func searchMatches(rows: [[Cell]], query: String,
                                     edits: [Int: [String: String?]]) -> [Int] {
        rows.indices.filter { index in
            if rows[index].contains(where: { $0.text?.localizedCaseInsensitiveContains(query) == true }) {
                return true
            }
            return edits[index]?.values.contains(where: { $0?.localizedCaseInsensitiveContains(query) == true }) == true
        }
    }

    /// Keeps only the `base` rows whose value in each filtered column is in that
    /// column's allowed set (nil = SQL NULL). An empty `filters` returns `base`.
    public static func valueFiltered(_ base: [Int], rows: [[Cell]], columns: [ColumnDescriptor],
                                     filters: [String: Set<String?>]) -> [Int] {
        guard !filters.isEmpty else { return base }
        // Resolve each filtered column to an index once, not per row.
        let columnIndex = Dictionary(columns.enumerated().map { ($0.element.name, $0.offset) },
                                     uniquingKeysWith: { first, _ in first })
        return base.filter { row in
            filters.allSatisfy { column, allowed in
                guard let index = columnIndex[column] else { return true }
                let value = index < rows[row].count ? rows[row][index].text : nil
                return allowed.contains(value)
            }
        }
    }

    /// Sorts `base` by `column`. Numeric columns compare as numbers when both cells
    /// parse (falling back to text otherwise); ties break on the original row index,
    /// so the sort is stable. Cells decorate once, so there are no per-comparison
    /// re-parses.
    public static func sorted(_ base: [Int], rows: [[Cell]], column: Int,
                              ascending: Bool, numeric: Bool) -> [Int] {
        struct Key { let row: Int; let text: String?; let number: Double? }
        let decorated = base.map { row -> Key in
            let text = column < rows[row].count ? rows[row][column].text : nil
            return Key(row: row, text: text, number: numeric ? text.flatMap(Double.init) : nil)
        }
        return decorated.sorted { a, b in
            switch (a.text, b.text) {
            case (nil, nil): return a.row < b.row
            case (nil, _): return false
            case (_, nil): return true
            case (let x?, let y?):
                let ordered: Bool
                if numeric, let dx = a.number, let dy = b.number {
                    if dx == dy { return a.row < b.row }
                    ordered = dx < dy
                } else {
                    let comparison = x.localizedStandardCompare(y)
                    if comparison == .orderedSame { return a.row < b.row }
                    ordered = comparison == .orderedAscending
                }
                return ascending ? ordered : !ordered
            }
        }.map(\.row)
    }
}
