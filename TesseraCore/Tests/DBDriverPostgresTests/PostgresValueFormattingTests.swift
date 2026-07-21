import XCTest
@testable import DBDriverPostgres

/// Pure formatting tests for the binary time/timetz/interval rendering — no
/// live server needed, unlike the integration suite next door.
final class PostgresValueFormattingTests: XCTestCase {

    func testTimeOfDay() {
        XCTAssertEqual(PostgresDriver.timeOfDay(micros: 0), "00:00:00")
        XCTAssertEqual(PostgresDriver.timeOfDay(micros: (14 * 3600 + 30 * 60 + 5) * 1_000_000),
                       "14:30:05")
        XCTAssertEqual(PostgresDriver.timeOfDay(micros: 500_000), "00:00:00.5")
        XCTAssertEqual(PostgresDriver.timeOfDay(micros: 1), "00:00:00.000001")
        XCTAssertEqual(PostgresDriver.timeOfDay(micros: 86_399_999_999), "23:59:59.999999")
    }

    func testZoneOffset() {
        XCTAssertEqual(PostgresDriver.zoneOffset(seconds: 2 * 3600), "+02")
        XCTAssertEqual(PostgresDriver.zoneOffset(seconds: -(5 * 3600 + 30 * 60)), "-05:30")
        XCTAssertEqual(PostgresDriver.zoneOffset(seconds: 0), "+00")
    }

    func testIntervalText() {
        XCTAssertEqual(PostgresDriver.intervalText(micros: 0, days: 0, months: 0), "00:00:00")
        XCTAssertEqual(
            PostgresDriver.intervalText(micros: (4 * 3600 + 5 * 60 + 6) * 1_000_000,
                                        days: 0, months: 0),
            "04:05:06")
        XCTAssertEqual(PostgresDriver.intervalText(micros: 0, days: 3, months: 0), "3 days")
        XCTAssertEqual(PostgresDriver.intervalText(micros: 0, days: 1, months: 14),
                       "1 year 2 mons 1 day")
        XCTAssertEqual(
            PostgresDriver.intervalText(micros: (4 * 3600 + 5 * 60 + 6) * 1_000_000,
                                        days: 3, months: 26),
            "2 years 2 mons 3 days 04:05:06")
        // Postgres renders negative components per part.
        XCTAssertEqual(PostgresDriver.intervalText(micros: -3_600_000_000, days: 0, months: 0),
                       "-01:00:00")
        XCTAssertEqual(PostgresDriver.intervalText(micros: 0, days: -2, months: 0), "-2 days")
    }
}
