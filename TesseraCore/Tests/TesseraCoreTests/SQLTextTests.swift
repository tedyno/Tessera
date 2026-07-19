import XCTest
@testable import DBKit

final class SQLTextTests: XCTestCase {

    // MARK: Inside string literal (suppresses autocomplete inside values)

    func testOutsideStringLiteral() {
        XCTAssertFalse(SQLText.isInsideStringLiteral("name LIKE "))
        XCTAssertFalse(SQLText.isInsideStringLiteral("id = 5 AND status"))
        XCTAssertFalse(SQLText.isInsideStringLiteral("name = 'done' AND x"))   // closed string
    }

    func testInsideStringLiteral() {
        XCTAssertTrue(SQLText.isInsideStringLiteral("name LIKE 'Li"))          // open quote
        XCTAssertTrue(SQLText.isInsideStringLiteral("a = 'foo' OR b = 'ba"))   // second open quote
    }

    // MARK: Case-only change (rejects auto-capitalization)

    func testRejectsCaseOnlyCapitalization() {
        // "li" auto-corrected to "Li" must be flagged as a case-only change.
        XCTAssertTrue(SQLText.isCaseOnlyChange(from: "li", to: "Li"))
        XCTAssertTrue(SQLText.isCaseOnlyChange(from: "l", to: "L"))
        XCTAssertTrue(SQLText.isCaseOnlyChange(from: "select", to: "SELECT"))
    }

    func testAllowsRealEdits() {
        XCTAssertFalse(SQLText.isCaseOnlyChange(from: "li", to: "like"))   // different letters
        XCTAssertFalse(SQLText.isCaseOnlyChange(from: "li", to: "li"))     // unchanged
        XCTAssertFalse(SQLText.isCaseOnlyChange(from: "", to: "L"))        // fresh insertion
        XCTAssertFalse(SQLText.isCaseOnlyChange(from: "abc", to: "abcd"))  // added char
    }

    // MARK: Completion matching

    func testIdentifierRange() {
        // "SELECT na|" → the word "na" ending at the caret.
        let text = "SELECT na"
        let range = SQLText.identifierRange(in: text, caret: text.count)
        XCTAssertEqual((text as NSString).substring(with: range), "na")

        // Caret right after a dot → empty (nothing to replace yet).
        let dotted = "public."
        XCTAssertEqual(SQLText.identifierRange(in: dotted, caret: dotted.count).length, 0)

        // Caret after a space → empty.
        XCTAssertEqual(SQLText.identifierRange(in: "a ", caret: 2).length, 0)
    }

    func testCompletions() {
        let pool = ["id", "name", "created_at", "LIKE", "IN"]
        XCTAssertEqual(SQLText.completions(for: "na", in: pool), ["name"])
        XCTAssertEqual(SQLText.completions(for: "i", in: pool), ["id", "IN"])
        XCTAssertEqual(SQLText.completions(for: "", in: pool), [])         // no partial → nothing
        XCTAssertEqual(SQLText.completions(for: "name", in: pool), [])     // exact match excluded
    }
}
