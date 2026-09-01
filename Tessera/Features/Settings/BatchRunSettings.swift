import Foundation

/// Whether ⌘↩ over a multi-statement selection stops to confirm first.
///
/// On by default: running several statements at once is the one keystroke in the app
/// that can change a lot of rows without the SQL ever being read back. The dialog's
/// "Don't ask again" writes `false` here, and General settings can turn it back on —
/// a checkbox with no way back is a trap.
enum BatchRunSettings {
    static let confirmsKey = "tessera.batchRun.confirms"

    static var confirms: Bool {
        get {
            // Absent means "never answered", which must read as on, not as the
            // `false` a missing Bool would otherwise give.
            UserDefaults.standard.object(forKey: confirmsKey) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: confirmsKey) }
    }
}
