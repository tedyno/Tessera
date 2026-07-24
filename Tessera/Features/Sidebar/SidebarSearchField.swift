import SwiftUI

/// Speed-search state shared by both sidebars: the search text, the current match
/// position/total, and the ↑/↓/Return relay tokens the AppKit outline watches. One
/// type so the state and its relay logic aren't duplicated per panel.
@Observable
final class SpeedSearchState {
    var searchText = ""
    var matchPosition = 0
    var matchCount = 0
    /// Direction of the last ↑/↓, paired with a token the outline observes as a
    /// one-shot signal.
    var keyboardStep = 0
    var keyboardStepToken = 0
    var keyboardCommitToken = 0

    /// ↑/↓ relay: remember the direction and bump the token the outline watches.
    func step(_ direction: Int) {
        keyboardStep = direction
        keyboardStepToken += 1
    }

    /// Return relay: open the row the search/arrows landed on.
    func commit() { keyboardCommitToken += 1 }

    /// The outline reports its current match here.
    func update(term: String, position: Int, count: Int) {
        if searchText != term { searchText = term }
        matchPosition = position
        matchCount = count
    }
}

/// The speed-search field shared by the schema and organizer sidebars: a
/// magnifying glass, a plain text field that relays ↑/↓ and Return to the outline,
/// a `position/total` match counter (red when nothing matches), and a clear button.
struct SidebarSearchField: View {
    @Bindable var speed: SpeedSearchState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            TextField("Search", text: $speed.searchText)
                .textFieldStyle(.plain)
                .font(.caption)
                // The field drives the tree: ↑/↓ walk the matches and Return opens
                // the picked row — connect → type → arrows → Enter, no mouse needed.
                .onKeyPress(.downArrow) { speed.step(1); return .handled }
                .onKeyPress(.upArrow) { speed.step(-1); return .handled }
                .onSubmit { speed.commit() }
            if !speed.searchText.isEmpty {
                Text(verbatim: "\(speed.matchPosition)/\(speed.matchCount)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(speed.matchCount == 0 ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                Button { speed.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// The shared footer chrome for both sidebars: the speed-search field stacked over
/// a panel-specific trailing row (filter/count for the schema tree, add/disconnect
/// for the organizer), on a faint translucent background.
struct SidebarFooter<Trailing: View>: View {
    @Bindable var speed: SpeedSearchState
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 6) {
            SidebarSearchField(speed: speed)
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // A faint translucent footer, not an opaque grey material — the themed
        // glass card keeps glowing through.
        .background(.primary.opacity(0.05))
    }
}
