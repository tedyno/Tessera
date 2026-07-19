import SwiftUI

/// One entry in the ⌘K command palette: a runnable action with its menu shortcut
/// shown alongside, so the palette doubles as a keyboard-shortcut cheat sheet.
struct PaletteCommand: Identifiable {
    let id: String
    /// Already-localized display text (also what the search box matches against).
    let title: String
    let shortcut: String?
    let systemImage: String
    let enabled: Bool
    let action: () -> Void
}

/// A searchable ⌘K palette of app commands. Type to filter, ↑/↓ to move, ↩ to run.
struct CommandPalette: View {
    @Bindable var app: AppModel
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var commands: [PaletteCommand] {
        let all = app.paletteCommands()
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { $0.title.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command").foregroundStyle(.secondary)
                TextField("Type a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { runSelected() }
                    .onChange(of: query) { _, _ in selection = 0 }
            }
            .padding(12)
            Divider()
            list
        }
        .frame(width: 540, height: 430)
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { app.showingCommandPalette = false; return .handled }
        .onAppear { focused = true }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if commands.isEmpty {
                        Text("No matching commands")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        row(command, selected: index == selection)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { run(command) }
                    }
                }
            }
            .onChange(of: selection) { _, new in
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    private func row(_ command: PaletteCommand, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: command.systemImage)
                .frame(width: 18)
                .foregroundStyle(command.enabled ? .secondary : .tertiary)
            Text(command.title)
                .foregroundStyle(command.enabled ? .primary : .secondary)
            Spacer(minLength: 12)
            if let shortcut = command.shortcut {
                Text(shortcut).font(.callout.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
    }

    private func move(_ delta: Int) {
        guard !commands.isEmpty else { return }
        selection = min(max(selection + delta, 0), commands.count - 1)
    }

    private func runSelected() {
        guard commands.indices.contains(selection) else { return }
        run(commands[selection])
    }

    private func run(_ command: PaletteCommand) {
        guard command.enabled else { return }
        app.showingCommandPalette = false
        // Run after this sheet has dismissed: SwiftUI can't close one sheet and open
        // another (Spotlight, New Connection, a run dialog…) in the same update.
        DispatchQueue.main.async { command.action() }
    }
}
