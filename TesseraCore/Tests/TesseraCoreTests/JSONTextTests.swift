import XCTest
@testable import DBKit

final class JSONTextTests: XCTestCase {
    private func lexemes(_ text: String) -> [String] {
        guard let result = JSONText.scan(text) else { return [] }
        let source = text as NSString
        return result.tokens.map { source.substring(with: $0.range) }
    }

    private func kinds(_ text: String) -> [JSONText.Token.Kind] {
        JSONText.scan(text)?.tokens.map(\.kind) ?? []
    }

    // MARK: Tokenization

    func testTokenKindsAndLexemes() {
        let text = #"{"a": 1, "b": [true, null, "x"]}"#
        let result = JSONText.scan(text)
        XCTAssertEqual(result?.isValid, true)
        XCTAssertEqual(result?.isContainer, true)
        XCTAssertEqual(kinds(text), [
            .punctuation, .objectKey, .punctuation, .number, .punctuation,
            .objectKey, .punctuation, .punctuation, .bool, .punctuation,
            .null, .punctuation, .string, .punctuation, .punctuation,
        ])
        XCTAssertEqual(lexemes(text), [
            "{", "\"a\"", ":", "1", ",", "\"b\"", ":", "[",
            "true", ",", "null", ",", "\"x\"", "]", "}",
        ])
    }

    func testKeyVersusStringValue() {
        let result = JSONText.scan(#"{"k": "v"}"#)
        let strings = result?.tokens.filter { $0.kind == .objectKey || $0.kind == .string }
        XCTAssertEqual(strings?.map(\.kind), [.objectKey, .string])
    }

    func testStringContainingStructuralCharacters() {
        let text = #"{"a": "x{y:,[z]"}"#
        XCTAssertEqual(JSONText.scan(text)?.isValid, true)
        XCTAssertTrue(lexemes(text).contains(#""x{y:,[z]""#))
    }

    // MARK: Escapes and offsets

    func testEscapes() {
        let text = #"{"a": "q\"w\\eA\n"}"#
        let result = JSONText.scan(text)
        XCTAssertEqual(result?.isValid, true)
        XCTAssertTrue(lexemes(text).contains(#""q\"w\\eA\n""#))
    }

    func testSurrogatePairEscape() {
        XCTAssertEqual(JSONText.scan(#"{"e": "😀"}"#)?.isValid, true)
        XCTAssertEqual(JSONText.scan(#"{"e": "\ud83d"}"#)?.isValid, true) // lone escape still 4 hex digits
        XCTAssertEqual(JSONText.scan(#"{"e": "\uZZ00"}"#)?.isValid, false)
    }

    func testLiteralEmojiKeepsOffsetsAligned() {
        let text = #"{"e": "😀", "n": 17}"#
        let result = JSONText.scan(text)
        XCTAssertEqual(result?.isValid, true)
        let number = result?.tokens.first { $0.kind == .number }
        XCTAssertEqual(number.map { (text as NSString).substring(with: $0.range) }, "17")
    }

    func testRawControlCharacterInStringIsInvalid() {
        XCTAssertEqual(JSONText.scan("{\"a\": \"x\ny\"}")?.isValid, false)
    }

    // MARK: Numbers as lexemes

    func testNumberLexemesSurviveFormatting() {
        let text = #"{"a": 1.00, "b": -0, "c": 1e10, "d": 0.5E+2}"#
        let pretty = JSONText.prettyPrinted(text)
        XCTAssertNotNil(pretty)
        let minified = JSONText.minified(pretty!)
        XCTAssertEqual(minified, #"{"a":1.00,"b":-0,"c":1e10,"d":0.5E+2}"#)
    }

    func testLeadingZeroIsInvalid() {
        XCTAssertEqual(JSONText.scan(#"{"a": 01}"#)?.isValid, false)
    }

    // MARK: Formatting round trips

    func testPrettyPrintedShape() {
        let text = #"{"a":1,"b":[1,2],"c":{},"d":{"e":null}}"#
        XCTAssertEqual(JSONText.prettyPrinted(text), """
        {
          "a": 1,
          "b": [
            1,
            2
          ],
          "c": {},
          "d": {
            "e": null
          }
        }
        """)
    }

    func testMinifyPrettyRoundTripIsIdentity() {
        let compact = #"{"z":1,"a":[true,{"k":"v"},[]],"m":{"x":1.50}}"#
        let pretty = JSONText.prettyPrinted(compact)
        XCTAssertNotNil(pretty)
        XCTAssertEqual(JSONText.minified(pretty!), compact)
        XCTAssertEqual(JSONText.minified(compact), compact)
    }

    func testMinifyKeepsWhitespaceInsideStrings() {
        XCTAssertEqual(JSONText.minified(#"{ "a" : "b c" }"#), #"{"a":"b c"}"#)
    }

    // MARK: haveSameTokens

    func testHaveSameTokensForWhitespaceVariants() {
        let compact = #"{"a":1}"#
        XCTAssertTrue(JSONText.haveSameTokens(compact, "{\n  \"a\": 1\n}"))
        XCTAssertTrue(JSONText.haveSameTokens(compact, JSONText.prettyPrinted(compact)!))
    }

    func testHaveSameTokensDetectsLexemeChange() {
        XCTAssertFalse(JSONText.haveSameTokens(#"{"a":1}"#, #"{"a":2}"#))
        XCTAssertFalse(JSONText.haveSameTokens(#"{"a":1}"#, #"{"a":1.0}"#))
        XCTAssertFalse(JSONText.haveSameTokens(#"{"a":1}"#, #"{"b":1}"#))
        XCTAssertFalse(JSONText.haveSameTokens(#"{"a":1}"#, #"{"a":1,"b":2}"#))
    }

    func testHaveSameTokensTreatsInvalidAsChanged() {
        XCTAssertFalse(JSONText.haveSameTokens(#"{"a":1}"#, #"{"a":"#))
        XCTAssertFalse(JSONText.haveSameTokens("{", "{"))
    }

    // MARK: Invalid input

    func testTruncatedInputKeepsTokensUpToError() {
        let result = JSONText.scan(#"{"a":"#)
        XCTAssertEqual(result?.isValid, false)
        XCTAssertEqual(result?.tokens.count, 3) // { "a" :
        XCTAssertEqual(result?.isContainer, true)
        XCTAssertNil(JSONText.prettyPrinted(#"{"a":"#))
    }

    func testTrailingGarbageIsInvalid() {
        XCTAssertEqual(JSONText.scan("{} x")?.isValid, false)
        XCTAssertNil(JSONText.minified("{} x"))
    }

    func testScalarIsValidButNotContainer() {
        let result = JSONText.scan(#""hi""#)
        XCTAssertEqual(result?.isValid, true)
        XCTAssertEqual(result?.isContainer, false)
        XCTAssertNil(JSONText.prettyPrinted(#""hi""#))
        XCTAssertEqual(JSONText.scan("42")?.isValid, true)
        XCTAssertNil(JSONText.prettyPrinted("42"))
    }

    func testEmptyAndNonJSONInput() {
        XCTAssertEqual(JSONText.scan("")?.isValid, false)
        XCTAssertEqual(JSONText.scan("hello world")?.isValid, false)
        XCTAssertEqual(JSONText.scan("hello world")?.isContainer, false)
    }

    func testTrailingCommaIsInvalid() {
        XCTAssertEqual(JSONText.scan(#"{"a":1,}"#)?.isValid, false)
        XCTAssertEqual(JSONText.scan("[1,]")?.isValid, false)
    }

    // MARK: Limits

    func testSizeLimitReturnsNil() {
        XCTAssertNil(JSONText.scan(String(repeating: " ", count: JSONText.sizeLimit + 1)))
    }

    func testDeepNestingDoesNotCrash() {
        let depth = 50_000
        let text = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        XCTAssertEqual(JSONText.scan(text)?.isValid, true)
    }

    func testPathologicalDepthFormattingBailsOut() {
        // Indentation is quadratic in depth; formatting must give up, not balloon.
        let depth = 40_000
        let text = String(repeating: "[", count: depth - 1) + "[1]"
            + String(repeating: "]", count: depth - 1)
        XCTAssertNil(JSONText.prettyPrinted(text))
    }

    // MARK: isInline

    func testIsInline() {
        XCTAssertTrue(JSONText.isInline(#"{"a":1}"#))
        XCTAssertFalse(JSONText.isInline("{\n  \"a\": 1\n}"))
        XCTAssertFalse(JSONText.isInline("{\r\n}")) // CRLF is one grapheme — must still count
        XCTAssertTrue(JSONText.isInline(#"{"a":"x\ny"}"#)) // escaped newline is content
    }

    // MARK: loneDocument

    /// A single-value reply (the Redis GET shape) unless told otherwise.
    private func result(_ texts: [String?], columns: Int = 1,
                        isSingleValue: Bool = true) -> QueryResult {
        QueryResult(columns: (0..<columns).map { ColumnDescriptor(name: "c\($0)", typeName: "string") },
                    rows: texts.map { text in
                        (0..<columns).map { _ in Cell(text) }
                    },
                    returnsRows: true,
                    isSingleValue: isSingleValue)
    }

    func testLoneDocumentPrettyPrintsInlineJSON() {
        let document = JSONText.loneDocument(in: result([#"{"a":1,"b":[2,3]}"#]))
        XCTAssertEqual(document, "{\n  \"a\": 1,\n  \"b\": [\n    2,\n    3\n  ]\n}")
    }

    func testLoneDocumentReindentsAlreadyFormattedText() {
        // A stored layout of its own still renders canonically — Raw is where the
        // viewer shows the stored bytes, so the two must be able to differ.
        let stored = "{\n    \"a\": 1,\n    \"b\": [1, 2]\n}"   // four-space indent, inline array
        XCTAssertEqual(JSONText.loneDocument(in: result([stored])),
                       "{\n  \"a\": 1,\n  \"b\": [\n    1,\n    2\n  ]\n}")
    }

    func testLoneDocumentOfCanonicalTextEqualsItsInput() {
        // Nothing to switch between — the viewer hides its Formatted/Raw picker.
        let stored = "{\n  \"a\": 1\n}"
        XCTAssertEqual(JSONText.loneDocument(in: result([stored])), stored)
    }

    func testLoneDocumentIgnoresNonDocuments() {
        XCTAssertNil(JSONText.loneDocument(in: result(["Ahoj světe"])))
        XCTAssertNil(JSONText.loneDocument(in: result(["42"])))          // scalar, not a container
        XCTAssertNil(JSONText.loneDocument(in: result([#""text""#])))    // scalar string
        XCTAssertNil(JSONText.loneDocument(in: result([#"{"a":1"#])))    // truncated
        XCTAssertNil(JSONText.loneDocument(in: result([nil])))           // NULL
        XCTAssertNil(JSONText.loneDocument(in: result([#"{"a":1}"#, #"{"b":2}"#])))   // two rows
        XCTAssertNil(JSONText.loneDocument(in: result([#"{"a":1}"#], columns: 2)))    // two columns
        XCTAssertNil(JSONText.loneDocument(in: result([])))              // no rows
    }

    func testLoneDocumentIgnoresOneElementCollections() {
        // A list holding one JSON element is a one-row *table*, not a value —
        // rendering it as a bare document would hide that it is a collection.
        XCTAssertNil(JSONText.loneDocument(in: result([#"{"a":1}"#], isSingleValue: false)))
    }

    func testLoneDocumentIgnoresOversizedDocument() {
        let huge = "[" + Array(repeating: "1", count: JSONText.sizeLimit / 2).joined(separator: ",") + "]"
        XCTAssertNil(JSONText.loneDocument(in: result([huge])))
    }

    func testLoneDocumentPreservesNumberSpellingAndKeyOrder() {
        let document = JSONText.loneDocument(in: result([#"{"z":1.00,"a":2}"#]))
        XCTAssertEqual(document, "{\n  \"z\": 1.00,\n  \"a\": 2\n}")
    }
}
