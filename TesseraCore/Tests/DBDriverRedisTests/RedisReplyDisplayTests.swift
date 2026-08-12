import XCTest
import DBKit
@testable import DBDriverRedis

/// Pure rendering of RESP replies into the grid's result shape. The focus here is
/// the value/table distinction: only a genuine scalar reply may claim
/// `isSingleValue`, because the UI renders such a result as a bare document.
final class RedisReplyDisplayTests: XCTestCase {

    private func result(_ command: [String], _ reply: RESPValue) -> QueryResult {
        RedisReplyDisplay.result(command: command, reply: reply, maxRows: nil)
    }

    func testBulkStringIsASingleValue() {
        let output = result(["GET", "k"], .bulkString(#"{"a":1}"#))
        XCTAssertTrue(output.isSingleValue)
        XCTAssertEqual(output.columns.map(\.name), ["value"])
        XCTAssertEqual(output.rows.first?.first?.text, #"{"a":1}"#)
    }

    func testSimpleStringAndIntegerAreSingleValues() {
        XCTAssertTrue(result(["SET", "k", "v"], .simpleString("OK")).isSingleValue)
        XCTAssertTrue(result(["DBSIZE"], .integer(7)).isSingleValue)
    }

    func testNilBulkStringIsASingleValue() {
        let output = result(["GET", "missing"], .bulkString(nil))
        XCTAssertTrue(output.isSingleValue)
        XCTAssertNil(output.rows.first?.first?.text)
    }

    func testOneElementArrayIsNotASingleValue() {
        // LRANGE over a list holding one JSON element: one row, one column — the
        // same shape as a GET, and it must not be mistaken for one.
        let output = result(["LRANGE", "k", "0", "499"], .array([.bulkString(#"{"a":1}"#)]))
        XCTAssertFalse(output.isSingleValue)
        XCTAssertEqual(output.rows.count, 1)
        XCTAssertEqual(output.columns.count, 1)
    }

    func testEmptyArrayRepliesAreNotSingleValues() {
        XCTAssertFalse(result(["SMEMBERS", "k"], .array([])).isSingleValue)
        XCTAssertFalse(result(["HGETALL", "k"], .array([.bulkString("f"), .bulkString("v")])).isSingleValue)
    }

    func testNullArrayFallsBackToASingleNullValue() {
        // A RESP null array (`*-1`) has no rows to show — it renders as one empty
        // value, which is what it is.
        let output = result(["EXEC"], .array(nil))
        XCTAssertTrue(output.isSingleValue)
        XCTAssertNil(output.rows.first?.first?.text)
    }
}
