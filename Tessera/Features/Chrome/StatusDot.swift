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
    /// Drives the connecting pulse. Flipped on when the status becomes
    /// `.connecting`; the repeating animation below does the rest.
    @State private var dimmed = false

    init(_ status: ConnectionSession.Status?, size: CGFloat = StatusDot.diameter) {
        self.status = status
        self.size = size
    }

    private var isConnecting: Bool { status == .connecting }

    var body: some View {
        Circle()
            .fill(status?.indicatorColor ?? .secondary)
            .frame(width: size, height: size)
            // Connecting is the one status that means work is under way, and a
            // still yellow dot doesn't say that — the other three are resting
            // states and stay put. The repeat is scoped to the attempt, so a
            // window full of connected tabs animates nothing.
            .opacity(dimmed ? 0.3 : 1)
            // Fade between health colours so connect/disconnect reads as a change of
            // state, not a flicker.
            .animation(.easeInOut(duration: 0.25), value: status)
            .animation(isConnecting
                       ? .easeInOut(duration: 0.65).repeatForever(autoreverses: true)
                       : .easeInOut(duration: 0.2),
                       value: dimmed)
            .onChange(of: isConnecting, initial: true) { _, connecting in
                dimmed = connecting
            }
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
