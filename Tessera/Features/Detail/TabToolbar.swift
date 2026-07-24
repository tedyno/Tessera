import SwiftUI

/// Metrics shared by the detail chrome, so a size change lives in one place.
enum TabChrome {
    static let toolbarHeight: CGFloat = 44
    /// The bottom status bar, fixed so it doesn't grow/shrink with which buttons a
    /// tab kind happens to show.
    static let statusBarHeight: CGFloat = 28
}

/// A tab's identity at the left of its toolbar: icon + name in the diagram-header
/// style, with an optional trailing divider (omit it when a `Spacer` follows).
struct TabHeaderLabel: View {
    let name: String
    let systemImage: String
    var divider: Bool = true

    var body: some View {
        HStack(spacing: 10) {
            Label { Text(verbatim: name) } icon: { Image(systemName: systemImage) }
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
            if divider { Divider().frame(height: 16) }
        }
    }
}

/// A tab's top toolbar: the identity header on the left, then a horizontally
/// scrolling row of controls, at a height uniform across tab kinds. Reused by the
/// query, table-view, and (via `TabHeaderLabel`) diagram toolbars.
struct TabToolbar<Controls: View>: View {
    let name: String
    let systemImage: String
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        // Horizontal scroll: a narrow pane can't fit every control, and clipping
        // them with no way to reach them is worse than a scroll.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                TabHeaderLabel(name: name, systemImage: systemImage)
                controls()
            }
            .padding(6)
        }
        .frame(height: TabChrome.toolbarHeight)
    }
}
