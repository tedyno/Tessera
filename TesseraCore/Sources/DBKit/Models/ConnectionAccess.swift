import Foundation

extension ConnectionProfile {
    /// A copy with the read-only guard flipped.
    ///
    /// Turning it on revokes MCP write access outright rather than leaving a flag
    /// that `allowsMCPWrite` would ignore: the organizer's menu shows read-only and
    /// the MCP level side by side, so a stale grant would read as write access the
    /// connection does not actually have.
    public func settingReadOnly(_ readOnly: Bool) -> ConnectionProfile {
        var copy = self
        copy.readOnly = readOnly ? true : nil
        if readOnly {
            copy.mcpWrite = nil
            copy.mcpWriteWithoutApproval = nil
        }
        return copy
    }
}
