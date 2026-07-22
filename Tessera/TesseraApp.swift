import SwiftUI
import Sparkle

@main
struct TesseraApp: App {
    @State private var app = AppModel()
    /// The user's light/dark override; `nil` follows the system. Applied to both
    /// scenes so the Settings window matches the main window.
    @AppStorage(AppTheme.key) private var themeRaw = AppTheme.system.rawValue
    /// Drives Sparkle auto-updates (checks the appcast, downloads, installs).
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    private var preferredScheme: ColorScheme? {
        (AppTheme(rawValue: themeRaw) ?? .system).colorScheme
    }

    var body: some Scene {
        WindowGroup {
            ContentView(app: app)
                .preferredColorScheme(preferredScheme)
        }
        // Frameless chrome: the gradient backdrop and floating cards own the
        // window; the traffic lights float over the top-left card area.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 760)
        .commands {
            TesseraCommands(app: app)
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updaterController.updater.checkForUpdates() }
            }
        }

        Settings {
            SettingsView()
                .preferredColorScheme(preferredScheme)
        }
    }
}

/// Menu-bar commands and their keyboard shortcuts.
struct TesseraCommands: Commands {
    let app: AppModel

    var body: some Commands {
        // The GPL asks a program with a user interface to show its legal notices.
        CommandGroup(replacing: .appInfo) {
            Button("About Tessera") { Self.showAbout() }
        }

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
            Button("Command Palette…") { app.showingCommandPalette = true }
                .keyboardShortcut("k", modifiers: .command)
            Button("Search Everywhere…") { app.showingSpotlight = true }
                .keyboardShortcut("o", modifiers: [.shift, .command])

            Divider()

            Button("Run") { app.runActiveQuery() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!app.canRun)
            Button("Stop") { app.stopActiveQuery() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!app.isRunning)
            Button("Explain") { app.explainActiveQuery(analyze: false) }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!app.canExplain)
            Button("Explain Analyze") { app.explainActiveQuery(analyze: true) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!app.canExplainAnalyze)

            Divider()

            Button("New Query Tab") { app.newTab() }
                .keyboardShortcut("t")
            Button("Close Tab") { app.closeActiveTab() }
                .keyboardShortcut("w")

            Button("Export Result as CSV…") { app.exportResult(format: .csv) }
                .disabled(!app.canExportResult)
            Button("Export Result as Excel…") { app.exportResult(format: .xlsx) }
                .disabled(!app.canExportResult)
            Button("Export Result as JSON…") { app.exportResult(format: .json) }
                .disabled(!app.canExportResult)
            Button("Export Result as SQL INSERT…") { app.exportResult(format: .sql) }
                .disabled(!app.canExportResult)

            Divider()

            Button("Open SQL File…") { app.openSQLFile() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Run SQL File…") { app.runSQLFile() }
                .keyboardShortcut("r", modifiers: [.shift, .command])
                .disabled(!app.isConnected)

            Button("Add Row") { app.addRowToActiveTab() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!app.canEditRows)
            Button("Find in Results") { app.findInResults() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!app.canFindInResults)

            Divider()

            Button("Focus Editor") { app.focusEditor() }
                .keyboardShortcut("l")
            Button("Refresh Schema") { app.refreshSchema() }
                .keyboardShortcut("r")
                .disabled(!app.isConnected)
            Button("Query History") { app.showHistory() }
                .keyboardShortcut("y")
            Button("MCP Activity…") { app.showingMCPLog = true }

            Divider()

            ForEach(1...9, id: \.self) { index in
                Button("Tab \(index)") { app.selectTab(index - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
            }
        }
    }

    /// The standard About panel, with the copyright and licence terms in the credits.
    private static func showAbout() {
        let notice = String(localized: """
            A native database client for PostgreSQL, MySQL, MariaDB and SQLite.

            Copyright © 2026 David Vaníček

            Tessera is free software under the GNU General Public License, version 3. \
            You may redistribute and modify it under those terms. It comes with \
            absolutely no warranty.

            Includes third-party open-source components (MIT and Apache-2.0 licensed); \
            their notices are in THIRD-PARTY-LICENSES.md alongside the source.
            """)
        let credits = NSAttributedString(
            string: notice,
            attributes: [.font: NSFont.preferredFont(forTextStyle: .callout),
                         .foregroundColor: NSColor.labelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
