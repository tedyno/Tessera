import XCTest
@testable import DBKit

final class SQLTemporalTests: XCTestCase {

    // MARK: Type classification

    func testTemporalTypeDetection() {
        for type in ["timestamp", "timestamptz", "timestamp with time zone",
                     "datetime", "datetime2", "date", "time", "timetz"] {
            XCTAssertTrue(SQLTemporal.isTemporalType(type), type)
        }
        for type in ["text", "integer", "interval", "varchar", "json"] {
            XCTAssertFalse(SQLTemporal.isTemporalType(type), type)
        }
    }

    // MARK: Parse ↔ format round trips

    private func utc(_ year: Int, _ month: Int, _ day: Int,
                     _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute; components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    func testParsesSQLTimestamp() {
        XCTAssertEqual(SQLTemporal.parse("2026-08-11 14:30:00"), utc(2026, 8, 11, 14, 30))
        XCTAssertEqual(SQLTemporal.parse("2026-08-11 14:30"), utc(2026, 8, 11, 14, 30))
        XCTAssertEqual(SQLTemporal.parse("2026-08-11"), utc(2026, 8, 11))
    }

    func testParsesISO8601() {
        XCTAssertEqual(SQLTemporal.parse("2026-08-11T14:30:00Z"), utc(2026, 8, 11, 14, 30))
        XCTAssertEqual(SQLTemporal.parse("2026-08-11T14:30:00.500Z"),
                       utc(2026, 8, 11, 14, 30).addingTimeInterval(0.5))
    }

    func testParsesOffsetTimestamp() {
        // +02:00 must shift to UTC, not be read naively.
        XCTAssertEqual(SQLTemporal.parse("2026-08-11 14:30:00+02:00"), utc(2026, 8, 11, 12, 30))
    }

    func testRejectsNonDates() {
        XCTAssertNil(SQLTemporal.parse(""))
        XCTAssertNil(SQLTemporal.parse("   "))
        XCTAssertNil(SQLTemporal.parse("not a date"))
    }

    func testFormatVariants() {
        let date = utc(2026, 8, 11, 14, 30, 5)
        XCTAssertEqual(SQLTemporal.format(date, dateParts: true, timeParts: true, iso: false),
                       "2026-08-11 14:30:05")
        XCTAssertEqual(SQLTemporal.format(date, dateParts: true, timeParts: true, iso: true),
                       "2026-08-11T14:30:05Z")
        XCTAssertEqual(SQLTemporal.format(date, dateParts: true, timeParts: false, iso: false),
                       "2026-08-11")
        XCTAssertEqual(SQLTemporal.format(date, dateParts: false, timeParts: true, iso: false),
                       "14:30:05")
    }

    func testRoundTripSQLTimestamp() {
        // What the picker writes must parse back to the same instant.
        let texts = ["2026-08-11 14:30:05", "2026-08-11", "2026-08-11T14:30:05Z"]
        for text in texts {
            guard let parsed = SQLTemporal.parse(text) else {
                return XCTFail("did not parse: \(text)")
            }
            let formatted = SQLTemporal.format(
                parsed, dateParts: true, timeParts: text.count > 10, iso: text.contains("T"))
            XCTAssertEqual(formatted, text)
        }
    }
}
