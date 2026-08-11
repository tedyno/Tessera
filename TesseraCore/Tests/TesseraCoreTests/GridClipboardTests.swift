import XCTest
@testable import DBKit

final class GridClipboardTests: XCTestCase {

    private let columns = [
        ColumnDescriptor(name: "id", typeName: "integer"),
        ColumnDescriptor(name: "name", typeName: "text"),
    ]

    func testTSVJoinsRaggedRowsAndBlanksNulls() {
        let text = GridClipboard.text(format: .tsv, columns: columns,
                                      matrix: [["1", "Alice"], [nil]], table: "t")
        XCTAssertEqual(text, "1\tAlice\n")
    }

    func testCSVEscapesDelimitersQuotesAndNewlines() {
        let text = GridClipboard.text(
            format: .csv, columns: columns,
            matrix: [["1", "a,b"], ["2", "say \"hi\""], ["3", "two\nlines"], ["4", nil]],
            table: "t")
        XCTAssertEqual(text, #"""
        id,name
        1,"a,b"
        2,"say ""hi"""
        3,"two
        lines"
        4,
        """#)
    }

    func testJSONTypesNumbersAndNulls() throws {
        let text = try XCTUnwrap(GridClipboard.text(
            format: .json, columns: columns,
            matrix: [["1", "Alice"], ["2", nil]], table: "t"))
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(text.utf8)) as? [[String: Any]])
        XCTAssertEqual(objects.count, 2)
        XCTAssertEqual(objects[0]["id"] as? Int, 1)
        XCTAssertEqual(objects[0]["name"] as? String, "Alice")
        XCTAssertTrue(objects[1]["name"] is NSNull)
    }

    func testJSONKeepsLargeDecimalPrecision() {
        let value = GridClipboard.jsonValue("12345678901234567890.5",
                                            typeName: "numeric")
        XCTAssertEqual(value as? NSDecimalNumber,
                       NSDecimalNumber(string: "12345678901234567890.5"))
    }

    func testInsertQuotesByColumnTypeAndEscapes() {
        let text = GridClipboard.text(
            format: .insert, columns: columns,
            matrix: [["1", "O'Brien"], ["2", nil]], table: "public.users")
        XCTAssertEqual(text, """
        INSERT INTO public.users (id, name) VALUES (1, 'O''Brien');
        INSERT INTO public.users (id, name) VALUES (2, NULL);
        """)
    }
}
