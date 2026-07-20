import SwiftUI
import AppKit

/// The colours a connection or folder can be tagged with. One list so the sidebar
/// dots, the tab chips, and the connection form can never drift apart.
enum ConnectionPalette {
    /// Stored names — these go into `ConnectionProfile.color`, so don't rename them.
    static let names = ["red", "orange", "yellow", "green", "blue", "purple", "gray"]

    static func nsColor(_ name: String?) -> NSColor? {
        switch name {
        case "red": .systemRed
        case "orange": .systemOrange
        case "yellow": .systemYellow
        case "green": .systemGreen
        case "blue": .systemBlue
        case "purple": .systemPurple
        case "gray": .systemGray
        default: nil
        }
    }

    static func color(_ name: String?) -> Color? {
        nsColor(name).map(Color.init(nsColor:))
    }
}
