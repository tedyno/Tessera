import Foundation

/// The MCP access a connection grants, as one ordered choice rather than three
/// interdependent flags. The organizer's context menu edits connections through
/// this (one at a time or a whole selection), where a set of checkboxes would be.
public enum MCPAccessLevel: String, CaseIterable, Sendable {
    /// Invisible to MCP clients.
    case none
    /// Queries only.
    case read
    /// Queries plus writes, each one approved by the user.
    case write
    /// Queries plus writes that run unattended.
    case writeWithoutApproval

    /// The level a profile currently grants, read through the same accessors the
    /// MCP server enforces — so a stale flag under a read-only connection (or the
    /// legacy `mcpAccess`) reports the access that is actually in effect.
    public init(profile: ConnectionProfile) {
        if profile.allowsMCPWriteWithoutApproval {
            self = .writeWithoutApproval
        } else if profile.allowsMCPWrite {
            self = .write
        } else if profile.allowsMCPRead {
            self = .read
        } else {
            self = .none
        }
    }

    public var grantsRead: Bool { self != .none }
    public var grantsWrite: Bool { self == .write || self == .writeWithoutApproval }

    /// Rewrites a profile's MCP flags to grant exactly this level.
    ///
    /// Granting writes clears `readOnly`, mirroring the connection editor: read-only
    /// caps MCP at reading, so leaving it on would silently ignore the choice.
    /// Legacy `mcpAccess` is cleared too — it still feeds `allowsMCPRead`, so a
    /// profile written by an older build would keep read access after `.none`.
    public func apply(to profile: inout ConnectionProfile) {
        profile.mcpAccess = nil
        profile.mcpRead = grantsRead ? true : nil
        profile.mcpWrite = grantsWrite ? true : nil
        profile.mcpWriteWithoutApproval = self == .writeWithoutApproval ? true : nil
        if grantsWrite { profile.readOnly = nil }
    }

    public func applied(to profile: ConnectionProfile) -> ConnectionProfile {
        var copy = profile
        apply(to: &copy)
        return copy
    }
}
