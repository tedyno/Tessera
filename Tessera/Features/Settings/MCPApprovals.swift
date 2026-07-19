import SwiftUI
import AppKit

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

    private struct Waiter {
        let request: Request
        let continuation: CheckedContinuation<Outcome, Never>
    }

    /// FIFO of requests; the first one is the prompt currently on screen. Queuing
    /// means a second write during an open prompt waits its turn instead of failing.
    @ObservationIgnored private var waiters: [Waiter] = []
    /// Bumped whenever the queue changes, so `pending` re-reads under Observation.
    private var queueVersion = 0

    /// The prompt currently on screen, if any.
    var pending: Request? {
        _ = queueVersion
        return waiters.first?.request
    }

    /// How many requests are waiting behind the current one.
    var queuedCount: Int {
        _ = queueVersion
        return max(waiters.count - 1, 0)
    }

    /// Per-connection "allow without asking" windows the user granted explicitly.
    @ObservationIgnored private var autoApproveUntil: [String: Date] = [:]

    /// Seconds before an unanswered prompt is treated as a refusal.
    static let timeout: Duration = .seconds(60)
    /// How long "Allow for a while" suppresses further prompts on that connection.
    static let autoApproveWindow: TimeInterval = 5 * 60

    /// True while `connection` is inside a user-granted auto-approve window.
    func isAutoApproved(_ connection: String) -> Bool {
        guard let until = autoApproveUntil[connection] else { return false }
        if until > Date() { return true }
        autoApproveUntil[connection] = nil
        return false
    }

    /// Shows the prompt (queuing behind any open one) and waits for the user or a
    /// timeout. Returns immediately when the connection is inside an auto-approve
    /// window the user granted.
    func request(title: String, connection: String, detail: String) async -> Outcome {
        if isAutoApproved(connection) { return .approved }
        let request = Request(title: title, connection: connection, detail: detail)
        return await withCheckedContinuation { continuation in
            waiters.append(Waiter(request: request, continuation: continuation))
            queueVersion &+= 1
            if waiters.count == 1 { present(request) }
        }
    }

    /// Brings the app forward for the front request and arms its timeout.
    private func present(_ request: Request) {
        // The request comes from a background client, so the app is usually not
        // frontmost — bring it forward (and bounce the Dock icon) so the prompt
        // isn't left unanswered behind other windows until it times out.
        NSApp.activate()
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        NSApp.requestUserAttention(.criticalRequest)
        Task { [weak self] in
            try? await Task.sleep(for: Self.timeout)
            guard let self, self.waiters.first?.request.id == request.id else { return }
            self.resolve(.timedOut)
        }
    }

    func approve() { resolve(.approved) }
    func decline() { resolve(.declined) }

    /// Approves this request and stops asking for that connection for a few minutes.
    func approveForAWhile() {
        if let connection = waiters.first?.request.connection {
            autoApproveUntil[connection] = Date().addingTimeInterval(Self.autoApproveWindow)
        }
        resolve(.approved)
    }

    /// Cancels every auto-approve window (shown as a way back out in the audit view).
    func revokeAutoApprovals() { autoApproveUntil.removeAll() }

    private func resolve(_ outcome: Outcome) {
        guard !waiters.isEmpty else { return }   // already answered
        let waiter = waiters.removeFirst()
        queueVersion &+= 1
        waiter.continuation.resume(returning: outcome)
        // Auto-approve may have been granted meanwhile; drain those without prompting.
        while let next = waiters.first, isAutoApproved(next.request.connection) {
            waiters.removeFirst()
            queueVersion &+= 1
            next.continuation.resume(returning: .approved)
        }
        if let next = waiters.first { present(next.request) }
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
        /// Which MCP client made the call, as it identified itself.
        let client: String
    }

    private(set) var entries: [Entry] = []
    private let limit = 200

    /// Name of the connected client, stamped onto every entry.
    var client = String(localized: "An MCP client")

    func record(tool: String, connection: String, detail: String, outcome: String) {
        entries.insert(Entry(tool: tool, connection: connection, detail: detail,
                             outcome: outcome, client: client), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    func clear() { entries.removeAll() }
}
