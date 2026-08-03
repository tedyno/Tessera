import XCTest
@testable import DBKit

final class JSONTreeTests: XCTestCase {

    func testNonContainerReturnsNil() {
        XCTAssertNil(JSONTreeNode.parse("42"))
        XCTAssertNil(JSONTreeNode.parse("\"hello\""))
        XCTAssertNil(JSONTreeNode.parse("not json"))
        XCTAssertNil(JSONTreeNode.parse(""))
    }

    func testObjectKeysAreSortedAndTyped() {
        let node = JSONTreeNode.parse(#"{"b": 1, "a": "x", "c": true, "d": null}"#)
        XCTAssertEqual(node?.value, .object(count: 4))
        XCTAssertEqual(node?.children.map(\.key), ["a", "b", "c", "d"])
        XCTAssertEqual(node?.children.map(\.value),
                       [.string("x"), .number("1"), .bool(true), .null])
    }

    func testArrayChildrenAreIndexed() {
        let node = JSONTreeNode.parse(#"[10, "two", false]"#)
        XCTAssertEqual(node?.value, .array(count: 3))
        XCTAssertEqual(node?.children.map(\.key), ["[0]", "[1]", "[2]"])
        XCTAssertEqual(node?.children.map(\.value), [.number("10"), .string("two"), .bool(false)])
    }

    func testBooleanIsNotMistakenForNumber() {
        let node = JSONTreeNode.parse(#"{"flag": true}"#)
        XCTAssertEqual(node?.children.first?.value, .bool(true))
    }

    func testOverSizedInputIsRejected() {
        let big = "[" + Array(repeating: "1", count: 200_000).joined(separator: ",") + "]"
        XCTAssertNil(JSONTreeNode.parse(big))   // over the 256 KB cap
    }
}
