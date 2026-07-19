import XCTest
@testable import DBKit

final class ResultExportTests: XCTestCase {

    private func makeResult() -> QueryResult {
        QueryResult(
            columns: [ColumnDescriptor(name: "id", typeName: "INTEGER"),
                      ColumnDescriptor(name: "name", typeName: "TEXT")],
            rows: [[Cell("1"), Cell("Alice")],
                   [Cell("2"), Cell(nil)]])
    }

    func testCSVHeaderAndRows() {
        let csv = ResultExport.csv(makeResult())
        XCTAssertEqual(csv, "id,name\n1,Alice\n2,")   // NULL → empty field
    }

    func testCSVQuotesWhenNeeded() {
        let result = QueryResult(
            columns: [ColumnDescriptor(name: "note", typeName: "TEXT")],
            rows: [[Cell("a,b")], [Cell("say \"hi\"")], [Cell("line1\nline2")]])
        let lines = ResultExport.csv(result).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines[0], "note")
        XCTAssertEqual(lines[1], "\"a,b\"")
        XCTAssertEqual(lines[2], "\"say \"\"hi\"\"\"")
        XCTAssertTrue(ResultExport.csv(result).contains("\"line1\nline2\""))
    }

    func testJSONObjectsWithNulls() throws {
        let json = ResultExport.json(makeResult())
        let data = try XCTUnwrap(json.data(using: .utf8))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0]["id"] as? String, "1")
        XCTAssertEqual(parsed[0]["name"] as? String, "Alice")
        XCTAssertTrue(parsed[1]["name"] is NSNull)
    }

    func testEmptyResult() {
        let empty = QueryResult(columns: [ColumnDescriptor(name: "a", typeName: "TEXT")], rows: [])
        XCTAssertEqual(ResultExport.csv(empty), "a")
        XCTAssertEqual(ResultExport.json(empty), "[]")
    }
}
