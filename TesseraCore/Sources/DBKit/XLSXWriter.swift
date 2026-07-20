import Foundation

/// Writes a minimal but valid `.xlsx` workbook: a ZIP holding the handful of XML
/// parts Excel needs. Entries are stored uncompressed, so the only binary work is a
/// CRC — no third-party dependency for a format we write in exactly one shape.
public enum XLSXWriter {

    /// A plain ZIP addresses offsets and sizes with 32 bits; past that the file would
    /// need ZIP64, which we don't emit. Refusing beats writing a corrupt workbook.
    public struct TooLarge: Error, CustomStringConvertible {
        public var description: String {
            "The result is too large for an .xlsx file (over 4 GB). "
            + "Export it as CSV, or lower “Max rows per query”."
        }
    }

    public static func workbook(from result: QueryResult,
                                sheetName: String = "Results") throws -> Data {
        var zip = ZipBuilder()
        zip.add(path: "[Content_Types].xml", contents: contentTypes)
        zip.add(path: "_rels/.rels", contents: rootRelationships)
        zip.add(path: "xl/workbook.xml", contents: workbookXML(sheetName: sheetName))
        zip.add(path: "xl/_rels/workbook.xml.rels", contents: workbookRelationships)
        zip.add(path: "xl/worksheets/sheet1.xml", contents: sheetXML(result))
        return try zip.finish()
    }

    // MARK: Sheet

    private static func sheetXML(_ result: QueryResult) -> String {
        var xml = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
            """
        xml += "<row r=\"1\">"
        for (index, column) in result.columns.enumerated() {
            xml += cell(reference: "\(columnLetters(index))1", text: column.name)
        }
        xml += "</row>"

        let numeric = result.columns.map { SQLTypes.isNumeric($0.typeName) }
        for (rowIndex, row) in result.rows.enumerated() {
            let rowNumber = rowIndex + 2   // row 1 is the header
            xml += "<row r=\"\(rowNumber)\">"
            for columnIndex in result.columns.indices {
                let value = columnIndex < row.count ? row[columnIndex].text : nil
                // A SQL NULL leaves the cell genuinely empty rather than writing "NULL".
                guard let value else { continue }
                let reference = "\(columnLetters(columnIndex))\(rowNumber)"
                if numeric[columnIndex], let number = spreadsheetNumber(value) {
                    xml += "<c r=\"\(reference)\"><v>\(number)</v></c>"
                } else {
                    xml += cell(reference: reference, text: value)
                }
            }
            xml += "</row>"
        }
        return xml + "</sheetData></worksheet>"
    }

    /// An inline string cell — avoids maintaining a shared-strings table.
    private static func cell(reference: String, text: String) -> String {
        "<c r=\"\(reference)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escape(text))</t></is></c>"
    }

    /// The value to write as a real number, or nil to keep it as text. Excel stores
    /// numbers as doubles, so anything that wouldn't survive that is left as a string
    /// rather than silently rounded (big `int8`, high-precision `numeric`).
    static func spreadsheetNumber(_ text: String) -> String? {
        if let integer = Int(text), abs(integer) <= (1 << 53) { return String(integer) }
        if let double = Double(text), double.isFinite, String(double) == text { return text }
        return nil
    }

    /// Spreadsheet column letters: 0 → A, 25 → Z, 26 → AA.
    static func columnLetters(_ index: Int) -> String {
        var remaining = index
        var letters = ""
        repeat {
            letters = String(UnicodeScalar(UInt8(65 + remaining % 26))) + letters
            remaining = remaining / 26 - 1
        } while remaining >= 0
        return letters
    }

    /// XML-escapes, and drops control characters that would make the file unreadable.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text.unicodeScalars {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\n", "\r", "\t": out.unicodeScalars.append(character)
            default:
                if character.value < 0x20 { continue }   // illegal in XML 1.0
                out.unicodeScalars.append(character)
            }
        }
        return out
    }

    // MARK: Fixed parts

    private static let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
        </Types>
        """

    private static let rootRelationships = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
        </Relationships>
        """

    private static let workbookRelationships = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
        </Relationships>
        """

    private static func workbookXML(sheetName: String) -> String {
        // Excel rejects these characters in a sheet name, and caps it at 31 chars.
        let cleaned = sheetName.filter { !"[]:*?/\\".contains($0) }
        let name = cleaned.isEmpty ? "Results" : String(cleaned.prefix(31))
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            <sheets><sheet name="\(escape(name))" sheetId="1" r:id="rId1"/></sheets></workbook>
            """
    }
}

/// Builds a ZIP archive with stored (uncompressed) entries — everything `.xlsx`
/// requires, without pulling in a compression dependency.
struct ZipBuilder {
    private struct Entry {
        let path: String
        let data: Data
        let crc: UInt32
        let offset: UInt32
    }

    private var payload = Data()
    private var entries: [Entry] = []
    /// Set once anything overflows 32 bits, so `finish()` can refuse rather than
    /// truncate an offset and hand back a corrupt archive.
    private var overflowed = false

    mutating func add(path: String, contents: String) {
        let data = Data(contents.utf8)
        guard let offset = UInt32(exactly: payload.count),
              UInt32(exactly: data.count) != nil else {
            overflowed = true
            return
        }
        let entry = Entry(path: path, data: data, crc: CRC32.checksum(data), offset: offset)
        payload.append(localHeader(for: entry))
        payload.append(data)
        entries.append(entry)
    }

    func finish() throws -> Data {
        var directory = Data()
        for entry in entries { directory.append(centralHeader(for: entry)) }

        var archive = payload
        guard !overflowed, let directoryOffset = UInt32(exactly: archive.count),
              UInt32(exactly: directory.count) != nil else { throw XLSXWriter.TooLarge() }
        archive.append(directory)
        archive.append(UInt32(0x0605_4b50).littleEndianData)   // end of central directory
        archive.append(UInt16(0).littleEndianData)             // this disk
        archive.append(UInt16(0).littleEndianData)             // disk with directory
        archive.append(UInt16(entries.count).littleEndianData)
        archive.append(UInt16(entries.count).littleEndianData)
        archive.append(UInt32(directory.count).littleEndianData)
        archive.append(directoryOffset.littleEndianData)
        archive.append(UInt16(0).littleEndianData)             // comment length
        return archive
    }

    private func localHeader(for entry: Entry) -> Data {
        var header = Data()
        header.append(UInt32(0x0403_4b50).littleEndianData)
        header.append(UInt16(20).littleEndianData)   // version needed
        header.append(UInt16(0).littleEndianData)    // flags
        header.append(UInt16(0).littleEndianData)    // method: stored
        header.append(UInt16(0).littleEndianData)    // time
        header.append(UInt16(0).littleEndianData)    // date
        header.append(entry.crc.littleEndianData)
        header.append(UInt32(entry.data.count).littleEndianData)
        header.append(UInt32(entry.data.count).littleEndianData)
        header.append(UInt16(entry.path.utf8.count).littleEndianData)
        header.append(UInt16(0).littleEndianData)    // extra length
        header.append(Data(entry.path.utf8))
        return header
    }

    private func centralHeader(for entry: Entry) -> Data {
        var header = Data()
        header.append(UInt32(0x0201_4b50).littleEndianData)
        header.append(UInt16(20).littleEndianData)   // version made by
        header.append(UInt16(20).littleEndianData)   // version needed
        header.append(UInt16(0).littleEndianData)    // flags
        header.append(UInt16(0).littleEndianData)    // method: stored
        header.append(UInt16(0).littleEndianData)    // time
        header.append(UInt16(0).littleEndianData)    // date
        header.append(entry.crc.littleEndianData)
        header.append(UInt32(entry.data.count).littleEndianData)
        header.append(UInt32(entry.data.count).littleEndianData)
        header.append(UInt16(entry.path.utf8.count).littleEndianData)
        header.append(UInt16(0).littleEndianData)    // extra
        header.append(UInt16(0).littleEndianData)    // comment
        header.append(UInt16(0).littleEndianData)    // disk number start
        header.append(UInt16(0).littleEndianData)    // internal attributes
        header.append(UInt32(0).littleEndianData)    // external attributes
        header.append(entry.offset.littleEndianData)
        header.append(Data(entry.path.utf8))
        return header
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension FixedWidthInteger {
    var littleEndianData: Data { withUnsafeBytes(of: littleEndian) { Data($0) } }
}
