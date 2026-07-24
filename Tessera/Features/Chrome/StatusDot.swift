import SwiftUI

/// The connection health dot used across the app (tab chips, status bar, …).
/// One component so its size and the status→colour mapping live in a single place:
/// green ready, yellow connecting, red failed, grey idle/disconnected or no session.
struct StatusDot: View {
    /// The one place the status-dot diameter is defined — SwiftUI dots and the
    /// AppKit organizer-row dot both read it, so they stay the same size.
    static let diameter: CGFloat = 6

    let status: ConnectionSession.Status?
    var size: CGFloat = StatusDot.diameter

    init(_ status: ConnectionSession.Status?, size: CGFloat = StatusDot.diameter) {
        self.status = status
        self.size = size
    }

    var body: some View {
        Circle()
            .fill(status?.indicatorColor ?? .secondary)
            .frame(width: size, height: size)
    }
}

extension ConnectionSession.Status {
    /// Health colour for this status, shared by every place that shows a status dot.
    var indicatorColor: Color {
        switch self {
        case .ready: .green
        case .connecting: .yellow
        case .failed: .red
        case .idle: .secondary
        }
    }
}
