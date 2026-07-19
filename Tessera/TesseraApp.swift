import SwiftUI

@main
struct TesseraApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(app: app)
        }
        .defaultSize(width: 1240, height: 760)
        .commands {
            TesseraCommands(app: app)
        }
    }
}

/// Menu-bar commands and their keyboard shortcuts.
struct TesseraCommands: Commands {
    let app: AppModel

    var body: some Commands {
        // Replace the default "New Window" (⌘N) — a single-window DB client doesn't
        // need it. ⌘N goes to "Add Row" (Query menu); New Connection moves to ⇧⌘N.
        CommandGroup(replacing: .newItem) {
            Button("New Connection…") { app.newConnection() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .sidebar) {
            Button("Toggle Sidebar") { app.toggleSidebar() }
                .keyboardShortcut("s", modifiers: .command)
        }

        CommandMenu("Query") {
            Button("Search Everywhere…") { app.showingSpotlight = true }
                .keyboardShortcut("o", modifiers: [.shift, .command])

            Divider()

            Button("Run") { app.runActiveQuery() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!app.canRun)
            Button("Stop") { app.stopActiveQuery() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!app.isRunning)

            Divider()

            Button("New Query Tab") { app.newTab() }
                .keyboardShortcut("t")
            Button("Close Tab") { app.closeActiveTab() }
                .keyboardShortcut("w")

            Button("Open SQL File…") { app.openSQLFile() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Run SQL File…") { app.runSQLFile() }
                .keyboardShortcut("r", modifiers: [.shift, .command])
                .disabled(!app.isConnected)

            Button("Add Row") { app.addRowToActiveTab() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!app.canEditRows)

            Divider()

            Button("Focus Editor") { app.focusEditor() }
                .keyboardShortcut("l")
            Button("Refresh Schema") { app.refreshSchema() }
                .keyboardShortcut("r")
                .disabled(!app.isConnected)
            Button("Query History") { app.showHistory() }
                .keyboardShortcut("y")

            Divider()

            ForEach(1...9, id: \.self) { index in
                Button("Tab \(index)") { app.selectTab(index - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
            }
        }
    }
}
