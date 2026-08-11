import XCTest
import DBKit
import MySQLNIO
@testable import DBDriverMySQL

/// Pins the driver's wire-type → information_schema-name mapping. The names must
/// stay in the exact spellings `SQLTypes.isNumeric` recognises — a silent drift
/// here loses numeric alignment, sorting and unquoted export for MySQL results.
final class MySQLTypeNameTests: XCTestCase {

    func testNumericWireTypesMapToRecognisedNames() {
        let numeric: [(MySQLProtocol.DataType, String)] = [
            (.tiny, "tinyint"), (.short, "smallint"), (.long, "int"),
            (.int24, "mediumint"), (.longlong, "bigint"), (.float, "float"),
            (.double, "double"), (.decimal, "decimal"), (.newdecimal, "decimal"),
            (.year, "year"),
        ]
        for (wire, expected) in numeric {
            XCTAssertEqual(MySQLDriver.typeName(for: wire), expected)
            XCTAssertTrue(SQLTypes.isNumeric(expected),
                          "\(expected) must count as numeric")
        }
    }

    func testTextualWireTypesMapToFriendlyNonNumericNames() {
        let textual: [(MySQLProtocol.DataType, String)] = [
            (.varchar, "varchar"), (.varString, "varchar"), (.string, "char"),
            (.blob, "blob"), (.json, "json"), (.datetime, "datetime"),
            (.timestamp, "timestamp"), (.date, "date"), (.time, "time"),
            (.enum, "enum"), (.set, "set"), (.bit, "bit"),
        ]
        for (wire, expected) in textual {
            XCTAssertEqual(MySQLDriver.typeName(for: wire), expected)
            XCTAssertFalse(SQLTypes.isNumeric(expected),
                           "\(expected) must not count as numeric")
        }
    }
}
