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
        // need it — with New Connection.
        CommandGroup(replacing: .newItem) {
            Button("New Connection…") { app.newConnection() }
                .keyboardShortcut("n")
        }

        CommandMenu("Query") {
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
