import XCTest
@testable import DBKit

final class SpotlightSearchTests: XCTestCase {
    private let profile = UUID()

    private func entry(_ kind: SpotlightEntry.Kind, _ title: String) -> SpotlightEntry {
        SpotlightEntry(kind: kind, profileID: profile, connectionName: kind == .connection ? title : "prod",
                       path: ["Work"],
                       schema: kind == .schema ? title : "public",
                       table: kind == .table || kind == .column || kind == .index ? (kind == .table ? title : "orders") : nil,
                       column: kind == .column ? title : nil,
                       indexName: kind == .index ? title : nil,
                       lowerTitle: title.lowercased())
    }

    func testMatchesAreSubstringsOfTheTitle() {
        let entries = [entry(.table, "orders"), entry(.table, "customers"), entry(.column, "order_id")]
        let hits = SpotlightSearch.matches(in: entries, needle: "order").map(\.title)
        XCTAssertEqual(Set(hits), ["orders", "order_id"])
    }

    func testEmptyNeedleMatchesNothing() {
        XCTAssertTrue(SpotlightSearch.matches(in: [entry(.table, "orders")], needle: "").isEmpty)
    }

    /// The point of the ranking: typing a full table name must not bury it under
    /// columns that merely contain it.
    func testExactMatchOutranksPrefixOutranksContains() {
        let entries = [entry(.column, "customer_orders"), entry(.table, "orders_archive"), entry(.table, "orders")]
        XCTAssertEqual(SpotlightSearch.matches(in: entries, needle: "orders").map(\.title),
                       ["orders", "orders_archive", "customer_orders"])
    }

    func testEqualRankKeepsKindOrderThenName() {
        // All three merely contain the needle, so kind decides: schema, table, column.
        let entries = [entry(.column, "x_id_col"), entry(.schema, "x_id_schema"), entry(.table, "x_id_table")]
        XCTAssertEqual(SpotlightSearch.matches(in: entries, needle: "x_id").map(\.kind),
                       [.schema, .table, .column])
    }

    func testResultsAreCapped() {
        let entries = (0..<200).map { entry(.table, "orders_\($0)") }
        XCTAssertEqual(SpotlightSearch.matches(in: entries, needle: "orders", limit: 80).count, 80)
    }

    func testNormalizeTrimsAndFolds() {
        XCTAssertEqual(SpotlightSearch.normalize("  Orders  "), "orders")
    }

    /// Matching reads `lowerTitle`, which is folded once when the index is built —
    /// so a mixed-case query still has to find a lowercase entry.
    func testMatchingIsCaseInsensitiveThroughNormalize() {
        let entries = [entry(.table, "Orders")]
        XCTAssertEqual(SpotlightSearch.matches(in: entries, needle: SpotlightSearch.normalize("ORD")).count, 1)
    }
}
