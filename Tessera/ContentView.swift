import SwiftUI

struct ContentView: View {
    @Bindable var app: AppModel

    var body: some View {
        NavigationSplitView {
            OrganizerSidebar(model: app.connections, selection: $app.selection) { parent in
                app.newConnectionParent = parent
                app.showingNewConnection = true
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 320)
        } content: {
            SchemaSidebar(
                tree: app.console.schema,
                onOpenTable: { schema, table in
                    Task { await app.console.selectAll(schema: schema, table: table) }
                },
                onOpenColumn: { schema, table, column in
                    Task {
                        await app.console.selectAll(schema: schema, table: table)
                        app.console.activeTab?.scrollToColumn = column
                    }
                })
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            DetailView(model: app.console,
                       showingHistory: $app.showingHistory,
                       focusTrigger: app.editorFocusRequests,
                       cursor: cursorBinding,
                       onRun: { app.runActiveQuery() })
                .navigationSplitViewColumnWidth(min: 480, ideal: 760)
        }
        .task {
            if app.selection == nil { app.selection = app.connections.firstConnectionNodeID }
        }
        .onChange(of: app.selection) { _, newValue in
            app.connect(nodeID: newValue)
        }
        .sheet(isPresented: $app.showingNewConnection) {
            NewConnectionView { profile, secrets in
                let nodeID = app.connections.addConnection(profile, secrets: secrets, into: app.newConnectionParent)
                app.selection = nodeID
            }
        }
        .confirmationDialog("Run which query?", isPresented: $app.showingRunChoice, presenting: app.pendingRun) { choice in
            Button("Run Subselect") { app.runResolved(choice.subselect) }
            Button("Run Full Statement") { app.runResolved(choice.statement) }
            Button("Cancel", role: .cancel) { app.pendingRun = nil }
        } message: { _ in
            Text("The cursor is inside a subselect.")
        }
    }

    private var cursorBinding: Binding<Int> {
        Binding(get: { app.console.activeTab?.cursorPosition ?? 0 },
                set: { app.console.activeTab?.cursorPosition = $0 })
    }
}
