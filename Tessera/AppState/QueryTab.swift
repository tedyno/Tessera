import Foundation
import DBKit

/// One query tab: its own editor text and result, sharing the connection's driver.
@MainActor
@Observable
final class QueryTab: Identifiable {
    let id = UUID()
    var title: String
    var sql: String
    var result: QueryResult?
    var elapsedMS: Int?
    var isRunning = false
    var errorMessage: String?

    init(title: String, sql: String = "") {
        self.title = title
        self.sql = sql
    }
}
