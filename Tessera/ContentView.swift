import SwiftUI
import DBKit

struct ContentView: View {
    @Bindable var app: AppModel

    var body: some View {
        NavigationSplitView(columnVisibility: $app.columnVisibility) {
            GeometryReader { geo in
            VSplitView {
                OrganizerSidebar(
                    model: app.connections,
                    selection: $app.selection,
                    onNewConnection: { parent in
                        app.newConnectionParent = parent
                        app.showingNewConnection = true
                    },
                    onEditConnection: { app.editConnection(nodeID: $0) },
                    onConnectProfile: { app.connectProfile(profileID: $0) },
                    onDisconnect: { app.disconnect(profileID: $0) },
                    onReconnect: { app.reconnect(profileID: $0) },
                    onIntrospect: { app.introspect(profileID: $0) },
                    onExport: { app.exportConnection(profileID: $0) },
                    onImport: { app.importConnection(profileID: $0) },
                    connectionDot: { app.connectionDot(profileID: $0) },
                    statusVersion: app.sessionStatusVersion)
                .frame(minHeight: 80, idealHeight: geo.size.height / 2, maxHeight: .infinity)

                SchemaSidebar(
                    tree: app.console.schema,
                    hiddenSchemas: app.currentHiddenSchemas,
                    reveal: app.schemaReveal,
                    onToggleSchema: { app.toggleSchema($0) },
                    onOpenTable: { schema, table in
                        Task { await app.console.openTable(schema: schema, table: table) }
                    },
                    onOpenColumn: { schema, table, column in
                        Task {
                            await app.console.openTable(schema: schema, table: table)
                            app.console.activeTab?.scrollToColumn = column
                        }
                    },
                    onDumpTable: { schema, table in
                        if let profileID = app.console.currentProfileID {
                            app.exportTable(profileID: profileID, schema: schema, table: table)
                        }
                    },
                    onDumpSchema: { schema in
                        if let profileID = app.console.currentProfileID {
                            app.exportSchema(profileID: profileID, schema: schema)
                        }
                    },
                    onDumpDatabase: {
                        if let profileID = app.console.currentProfileID {
                            app.exportConnection(profileID: profileID)
                        }
                    },
                    onDDL: { app.startDDL($0) })
                .frame(minHeight: 80, idealHeight: geo.size.height / 2, maxHeight: .infinity)
            }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 420)
        } detail: {
            DetailView(model: app.console,
                       showingHistory: $app.showingHistory,
                       focusTrigger: app.editorFocusRequests,
                       cursor: cursorBinding,
                       isReadOnly: app.currentIsReadOnly,
                       onRun: { app.runActiveQuery() },
                       onExportResult: { app.exportResult(format: $0) },
                       onRunSQL: { app.runResolved($0) })
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
        .sheet(isPresented: $app.showingEditConnection) {
            if let profile = app.editingProfile {
                NewConnectionView(editing: profile, secrets: app.editingSecrets) { updated, secrets in
                    app.connections.updateConnection(updated, secrets: secrets)
                }
            }
        }
        .confirmationDialog("Run which query?", isPresented: $app.showingRunChoice, presenting: app.pendingRun) { choice in
            Button("Run Subselect") { app.runResolved(choice.subselect) }
            Button("Run Full Statement") { app.runResolved(choice.statement) }
            Button("Cancel", role: .cancel) { app.pendingRun = nil }
        } message: { _ in
            Text("The cursor is inside a subselect.")
        }
        .confirmationDialog("Run this destructive statement?",
                            isPresented: $app.showingDestructiveConfirm, titleVisibility: .visible) {
            Button("Run Anyway", role: .destructive) { app.confirmDestructiveRun() }
            Button("Cancel", role: .cancel) { app.cancelDestructiveRun() }
        } message: {
            Text(app.destructiveSummary)
        }
        .sheet(item: $app.ddlOperation) { operation in
            DDLEditorView(operation: operation,
                          engine: app.currentEngine,
                          onRun: { await app.runDDL($0) },
                          onClose: { app.ddlOperation = nil })
        }
        .sheet(item: $app.importTarget) { target in
            if let context = app.importContext(for: target) {
                ImportView(context: context, service: app.dumpService) { app.importTarget = nil }
            } else {
                VStack(spacing: 12) {
                    Text("Cannot import into this connection.")
                    Button("Close") { app.importTarget = nil }
                }.padding(30)
            }
        }
        .sheet(item: $app.exportTarget) { target in
            if let context = app.exportContext(for: target) {
                ExportView(context: context, service: app.dumpService) { app.exportTarget = nil }
            } else {
                VStack(spacing: 12) {
                    Text("Cannot export this connection.")
                    Button("Close") { app.exportTarget = nil }
                }.padding(30)
            }
        }
        .sheet(isPresented: $app.showingSpotlight) {
            SpotlightView(app: app)
        }
        .confirmationDialog("This connection is read-only",
                            isPresented: $app.showingReadOnlyConfirm) {
            Button("Write Anyway", role: .destructive) { app.confirmReadOnlyCommit() }
            Button("Cancel", role: .cancel) { app.cancelReadOnlyCommit() }
        } message: {
            Text("You marked this connection read-only. Save the edited rows to the database?")
        }
        .onAppear { app.installShiftMonitor() }
    }

    private var cursorBinding: Binding<Int> {
        Binding(get: { app.console.activeTab?.cursorPosition ?? 0 },
                set: { app.console.activeTab?.cursorPosition = $0 })
    }
}
