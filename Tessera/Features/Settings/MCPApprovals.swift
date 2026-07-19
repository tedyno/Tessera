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

    private(set) var pending: Request?
    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?

    /// Seconds before an unanswered prompt is treated as a refusal.
    static let timeout: Duration = .seconds(60)

    /// Shows the prompt and waits. Returns false if the user declines, the prompt
    /// times out, or another approval is already on screen.
    func request(title: String, connection: String, detail: String) async -> Bool {
        guard pending == nil else { return false }   // never queue dialogs
        let request = Request(title: title, connection: connection, detail: detail)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.pending = request
            Task { [weak self] in
                try? await Task.sleep(for: Self.timeout)
                guard let self, self.pending?.id == request.id else { return }
                self.resolve(false)
            }
        }
    }

    func approve() { resolve(true) }
    func decline() { resolve(false) }

    private func resolve(_ approved: Bool) {
        guard let continuation else { return }   // already answered
        self.continuation = nil
        pending = nil
        continuation.resume(returning: approved)
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
