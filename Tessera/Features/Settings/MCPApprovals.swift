import SwiftUI

/// Blocks an MCP request until the user approves it in the app. A request that is
/// never answered times out rather than pinning the connection open forever.
@MainActor
@Observable
final class MCPApprovals {
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let connection: String
        /// The exact SQL or file involved — shown verbatim so nothing is hidden.
        let detail: String
    }

    /// Why a request finished the way it did — a prompt the user never saw must not
    /// be reported to the client as a refusal.
    enum Outcome {
        case approved
        case declined
        /// Another approval was already on screen; this one was never shown.
        case busy
        case timedOut

        var isApproved: Bool { self == .approved }

        /// Short label for the audit log.
        var auditLabel: String {
            switch self {
            case .approved: "approved"
            case .declined: "declined"
            case .busy: "not shown — another approval was open"
            case .timedOut: "timed out"
            }
        }

        /// Explanation for the MCP client, which should retry on `.busy`.
        func message(_ action: String) -> String {
            switch self {
            case .approved: "Approved."
            case .declined: "The user declined the \(action)."
            case .busy: "Another approval is already on screen — retry the \(action) shortly."
            case .timedOut: "The \(action) prompt timed out without an answer."
            }
        }
    }

    private(set) var pending: Request?
    @ObservationIgnored private var continuation: CheckedContinuation<Outcome, Never>?

    /// Seconds before an unanswered prompt is treated as a refusal.
    static let timeout: Duration = .seconds(60)

    /// Shows the prompt and waits for the user, a timeout, or nothing at all if a
    /// prompt is already up — the caller needs to tell those apart.
    func request(title: String, connection: String, detail: String) async -> Outcome {
        guard pending == nil else { return .busy }   // never queue dialogs
        let request = Request(title: title, connection: connection, detail: detail)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.pending = request
            Task { [weak self] in
                try? await Task.sleep(for: Self.timeout)
                guard let self, self.pending?.id == request.id else { return }
                self.resolve(.timedOut)
            }
        }
    }

    func approve() { resolve(.approved) }
    func decline() { resolve(.declined) }

    private func resolve(_ outcome: Outcome) {
        guard let continuation else { return }   // already answered
        self.continuation = nil
        pending = nil
        continuation.resume(returning: outcome)
    }
}

/// A rolling record of what MCP did, so the server is never a black box.
@MainActor
@Observable
final class MCPAuditLog {
    struct Entry: Identifiable {
        let id = UUID()
        let date = Date()
        let tool: String
        let connection: String
        let detail: String
        let outcome: String
    }

    private(set) var entries: [Entry] = []
    private let limit = 200

    func record(tool: String, connection: String, detail: String, outcome: String) {
        entries.insert(Entry(tool: tool, connection: connection, detail: detail, outcome: outcome), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    func clear() { entries.removeAll() }
}
