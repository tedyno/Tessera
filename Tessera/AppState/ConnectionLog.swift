import Foundation
import Observation

/// A rolling diagnostic log of what happened while connecting. The status bar only
/// has room for one line, and `DatabaseError` messages are often the least
/// interesting part of a failure — this keeps the full text, the stage it came
/// from, and the parameters in play, so a failure can actually be investigated.
@MainActor
@Observable
final class ConnectionLog {
    enum Stage: String, CaseIterable {
        case tunnel = "SSH tunnel"
        case connect = "Connect"
        case introspect = "Schema"
        case query = "Query"
        case disconnect = "Disconnect"
    }

    struct Entry: Identifiable {
        let id = UUID()
        let date = Date()
        let connection: String
        let stage: Stage
        let message: String
        let isError: Bool
        /// Everything worth seeing: the raw error and the settings it was using.
        let detail: String?

        /// One block of text for "Copy", so a report can be pasted somewhere useful.
        var plainText: String {
            let stamp = Entry.stampFormatter.string(from: date)
            var text = "[\(stamp)] \(connection) · \(stage.rawValue)\(isError ? " · FAILED" : "")\n\(message)"
            if let detail, !detail.isEmpty { text += "\n\(detail)" }
            return text
        }

        private static let stampFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            return formatter
        }()
    }

    private(set) var entries: [Entry] = []
    private let limit = 500

    /// True when the newest entry is a failure, so the status bar can flag it.
    var hasRecentFailure: Bool { entries.first?.isError ?? false }

    func record(_ connection: String, _ stage: Stage, _ message: String,
                isError: Bool = false, detail: String? = nil) {
        entries.insert(Entry(connection: connection, stage: stage, message: message,
                             isError: isError, detail: detail), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    func clear() { entries.removeAll() }

    /// The whole log, newest last, for copying out.
    var plainText: String {
        entries.reversed().map(\.plainText).joined(separator: "\n\n")
    }
}
