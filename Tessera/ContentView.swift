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
            SchemaSidebar(tree: app.console.schema) { schema, table in
                Task { await app.console.selectAll(schema: schema, table: table) }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            DetailView(model: app.console,
                       showingHistory: $app.showingHistory,
                       focusTrigger: app.editorFocusRequests)
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
    }
}
