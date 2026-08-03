import XCTest
@testable import DBKit

/// Unit tests for the pure results-grid display transforms (⌘F filter, value
/// filters, column sort).
final class GridDisplayTests: XCTestCase {

    private func result(_ columns: [String], _ rows: [[String?]]) -> QueryResult {
        QueryResult(columns: columns.map { ColumnDescriptor(name: $0, typeName: "text") },
                    rows: rows.map { $0.map { Cell($0) } })
    }

    private func rows(_ r: [[String?]]) -> [[Cell]] { r.map { $0.map { Cell($0) } } }

    // MARK: Search filter

    func testSearchMatchesCellsCaseInsensitively() {
        let data = rows([["Alice", "NYC"], ["bob", "LA"], ["Carol", "alicante"]])
        XCTAssertEqual(GridDisplay.searchMatches(rows: data, query: "ali", edits: [:]), [0, 2])
    }

    func testSearchAlsoMatchesPendingEdits() {
        let data = rows([["Alice"], ["Bob"]])
        // Row 1's fetched value doesn't match, but its pending edit does.
        let matches = GridDisplay.searchMatches(rows: data, query: "zed", edits: [1: ["name": "Zed"]])
        XCTAssertEqual(matches, [1])
    }

    // MARK: Value filters

    func testValueFilterKeepsAllowedValuesIncludingNull() {
        let res = result(["status"], [["active"], [nil], ["archived"], ["active"]])
        let filtered = GridDisplay.valueFiltered(Array(0..<4), rows: res.rows, columns: res.columns,
                                                 filters: ["status": ["active", nil]])
        XCTAssertEqual(filtered, [0, 1, 3])
    }

    func testEmptyFilterReturnsBaseUnchanged() {
        let res = result(["a"], [["1"], ["2"]])
        XCTAssertEqual(GridDisplay.valueFiltered([0, 1], rows: res.rows, columns: res.columns, filters: [:]), [0, 1])
    }

    // MARK: Sort

    func testNumericSortParsesNumbersNotStrings() {
        let data = rows([["2"], ["10"], ["1"]])
        // As strings "10" < "2"; as numbers 1 < 2 < 10.
        XCTAssertEqual(GridDisplay.sorted([0, 1, 2], rows: data, column: 0, ascending: true, numeric: true), [2, 0, 1])
    }

    func testTextSortIsCaseInsensitiveAndStable() {
        let data = rows([["banana"], ["Apple"], ["cherry"]])
        XCTAssertEqual(GridDisplay.sorted([0, 1, 2], rows: data, column: 0, ascending: true, numeric: false), [1, 0, 2])
    }

    func testNullsSinkToEndRegardlessOfDirection() {
        let data = rows([["b"], [nil], ["a"]])
        XCTAssertEqual(GridDisplay.sorted([0, 1, 2], rows: data, column: 0, ascending: true, numeric: false), [2, 0, 1])
        XCTAssertEqual(GridDisplay.sorted([0, 1, 2], rows: data, column: 0, ascending: false, numeric: false), [0, 2, 1])
    }
}
