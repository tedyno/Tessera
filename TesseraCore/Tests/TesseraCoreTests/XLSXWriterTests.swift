import XCTest
@testable import DBKit

final class XLSXWriterTests: XCTestCase {

    private func sample() -> QueryResult {
        QueryResult(
            columns: [ColumnDescriptor(name: "id", typeName: "int8"),
                      ColumnDescriptor(name: "name", typeName: "text"),
                      ColumnDescriptor(name: "note", typeName: "text")],
            rows: [[Cell("1"), Cell("Ava & Co <x>"), Cell(nil)],
                   [Cell("9007199254740993"), Cell("quote\"here"), Cell("ok")]])
    }

    // MARK: Cell addressing and escaping

    func testColumnLetters() {
        XCTAssertEqual(XLSXWriter.columnLetters(0), "A")
        XCTAssertEqual(XLSXWriter.columnLetters(25), "Z")
        XCTAssertEqual(XLSXWriter.columnLetters(26), "AA")
        XCTAssertEqual(XLSXWriter.columnLetters(701), "ZZ")
        XCTAssertEqual(XLSXWriter.columnLetters(702), "AAA")
    }

    func testEscapeDropsControlCharactersAndEscapesMarkup() {
        XCTAssertEqual(XLSXWriter.escape("a & b < c"), "a &amp; b &lt; c")
        XCTAssertEqual(XLSXWriter.escape("bell\u{7}here"), "bellhere")
        XCTAssertEqual(XLSXWriter.escape("keep\nnewline"), "keep\nnewline")
    }

    /// Excel holds numbers as doubles, so anything that wouldn't survive stays text.
    func testOnlyLosslessNumbersBecomeNumericCells() {
        XCTAssertEqual(XLSXWriter.spreadsheetNumber("42"), "42")
        XCTAssertEqual(XLSXWriter.spreadsheetNumber("272.5"), "272.5")
        XCTAssertNil(XLSXWriter.spreadsheetNumber("9007199254740993"))   // > 2^53
        XCTAssertNil(XLSXWriter.spreadsheetNumber("abc"))
    }

    // MARK: Archive

    func testWorkbookIsAZipHoldingTheExpectedParts() throws {
        let data = XLSXWriter.workbook(from: sample())
        XCTAssertEqual(Array(data.prefix(2)), Array("PK".utf8))

        let parts = try unzip(data)
        XCTAssertEqual(Set(parts.keys), [
            "[Content_Types].xml", "_rels/.rels", "xl/workbook.xml",
            "xl/_rels/workbook.xml.rels", "xl/worksheets/sheet1.xml",
        ])
    }

    func testSheetContentsAndTypes() throws {
        let sheet = try XCTUnwrap(try unzip(XLSXWriter.workbook(from: sample()))["xl/worksheets/sheet1.xml"])

        XCTAssertTrue(sheet.contains("<t xml:space=\"preserve\">id</t>"))   // header
        XCTAssertTrue(sheet.contains("<c r=\"A2\"><v>1</v></c>"))           // numeric cell
        XCTAssertTrue(sheet.contains("Ava &amp; Co &lt;x&gt;"))             // escaped text
        XCTAssertTrue(sheet.contains("9007199254740993"))                   // kept as text
        XCTAssertFalse(sheet.contains("C2"))                                // NULL leaves no cell
    }

    func testSheetNameIsSanitized() throws {
        let workbook = XLSXWriter.workbook(from: sample(), sheetName: "a/b*c[d]e")
        let xml = try XCTUnwrap(try unzip(workbook)["xl/workbook.xml"])
        XCTAssertTrue(xml.contains("name=\"abcde\""))
    }

    // MARK: Minimal reader for stored ZIP entries

    private func unzip(_ data: Data) throws -> [String: String] {
        var parts: [String: String] = [:]
        var offset = 0
        let bytes = [UInt8](data)
        func value(_ start: Int, _ count: Int) -> Int {
            (0..<count).reduce(0) { $0 | Int(bytes[start + $1]) << (8 * $1) }
        }
        while offset + 30 <= bytes.count, value(offset, 4) == 0x0403_4b50 {
            let size = value(offset + 18, 4)
            let nameLength = value(offset + 26, 2)
            let extraLength = value(offset + 28, 2)
            let nameStart = offset + 30
            let name = String(decoding: bytes[nameStart..<nameStart + nameLength], as: UTF8.self)
            let contentStart = nameStart + nameLength + extraLength
            parts[name] = String(decoding: bytes[contentStart..<contentStart + size], as: UTF8.self)
            offset = contentStart + size
        }
        return parts
    }
}
