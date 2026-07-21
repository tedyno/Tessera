import SwiftUI
import DBKit

struct ContentView: View {
    @Bindable var app: AppModel

    var body: some View {
        NavigationSplitView(columnVisibility: $app.columnVisibility) {
            // No GeometryReader here on purpose: deriving the panes' ideal height from
            // the container made VSplitView re-apply it on every layout pass, snapping
            // the divider back and fighting the drag. A constant ideal stays put.
            VSplitView {
                OrganizerSidebar(
                    model: app.connections,
                    selection: $app.selection,
                    onNewConnection: { parent in
                        app.newConnectionParent = parent
                        app.showingNewConnection = true
                    },
                    onEditConnection: { app.editConnection(nodeID: $0) },
                    onDuplicateConnection: { app.duplicateConnection(nodeID: $0) },
                    onConnectProfile: { app.connectProfile(profileID: $0) },
                    onDisconnect: { app.disconnect(profileID: $0) },
                    onReconnect: { app.reconnect(profileID: $0) },
                    onIntrospect: { app.introspect(profileID: $0) },
                    onExport: { app.exportConnection(profileID: $0) },
                    onImport: { app.importConnection(profileID: $0) },
                    onNewQueryTab: { app.newQueryTab(profileID: $0) },
                    connectionDot: { app.connectionDot(profileID: $0) },
                    statusVersion: app.sessionStatusVersion,
                    onDisconnectAll: { app.disconnectAll() },
                    hasActiveConnections: app.hasActiveConnections)
                .frame(minHeight: 120, idealHeight: 320, maxHeight: .infinity)

                schemaSidebar
                    .frame(minHeight: 120, maxHeight: .infinity)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 420)
        } detail: {
            DetailView(model: app.console,
                       showingHistory: $app.showingHistory,
                       focusTrigger: app.editorFocusRequests,
                       cursor: cursorBinding,
                       isReadOnly: app.currentIsReadOnly,
                       onRun: { app.runActiveQuery() },
                       onExplain: { app.explainActiveQuery(analyze: $0) },
                       onExportResult: { app.exportResult(format: $0) },
                       onPickHistory: { app.loadHistoryEntry($0) },
                       onRunHistory: { app.runHistoryEntry($0) },
                       connectionOptions: app.connectionOptions,
                       onSelectConnection: { app.selectConnection($0) },
                       onNewConnection: { app.newConnection() })
        }
        // Nothing connects on launch — no Keychain access until the user actually
        // connects something (double-click / ⌘↩ in the organizer). A plain click
        // only switches the schema sidebar to that connection's session.
        .onChange(of: app.selection) { _, newValue in
            app.viewConnection(nodeID: newValue)
        }
        .sheet(isPresented: $app.showingNewConnection) {
            NewConnectionView { profile, secrets in
                let nodeID = app.connections.addConnection(profile, secrets: secrets, into: app.newConnectionParent)
                app.selection = nodeID
                app.connect(nodeID: nodeID)
            }
        }
        .sheet(isPresented: $app.showingEditConnection) {
            if let profile = app.editingProfile {
                NewConnectionView(editing: profile, secrets: app.editingSecrets) { updated, secrets in
                    app.connections.updateConnection(updated, secrets: secrets)
                }
            }
        }
        .sheet(isPresented: $app.showingDuplicateConnection) {
            if let profile = app.duplicatingProfile {
                NewConnectionView(editing: profile, secrets: app.duplicatingSecrets,
                                  duplicating: true) { updated, secrets in
                    app.finishDuplicate(updated, secrets: secrets)
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
        .sheet(isPresented: $app.showingMCPLog) {
            MCPAuditView(app: app)
        }
        .sheet(isPresented: $app.showingSpotlight) {
            SpotlightView(app: app)
        }
        .sheet(isPresented: $app.showingCommandPalette) {
            CommandPalette(app: app)
        }
        .confirmationDialog("This connection is read-only",
                            isPresented: $app.showingReadOnlyConfirm) {
            Button("Write Anyway", role: .destructive) { app.confirmReadOnlyCommit() }
            Button("Cancel", role: .cancel) { app.cancelReadOnlyCommit() }
        } message: {
            Text("You marked this connection read-only. Save the edited rows to the database?")
        }
        .sheet(item: Binding(get: { app.mcpApprovals.pending }, set: { if $0 == nil { app.mcpApprovals.decline() } })) { request in
            VStack(alignment: .leading, spacing: 14) {
                Label(request.title, systemImage: "sparkles")
                    .font(.headline)
                Text("Requested over MCP. Review it before allowing.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(request.detail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 110)
                .padding(8)
                .background(.quaternary.opacity(0.4))
                HStack {
                    if app.mcpApprovals.queuedCount > 0 {
                        Text("^[\(app.mcpApprovals.queuedCount) more request](inflect: true) waiting")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Decline") { app.mcpApprovals.decline() }
                        .keyboardShortcut(.cancelAction)
                    Button("Allow for 5 min") { app.mcpApprovals.approveForAWhile() }
                        .help("Stop asking for this connection for the next 5 minutes")
                    Button("Allow") { app.mcpApprovals.approve() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 520)
        }
        .onAppear {
            app.installShiftMonitor()
            app.syncMCPServer()
        }
    }

    private var cursorBinding: Binding<Int> {
        Binding(get: { app.console.activeTab?.cursorPosition ?? 0 },
                set: { app.console.activeTab?.cursorPosition = $0 })
    }

    // Pulled out of `body`: with this many parameters/closures inline, the whole
    // NavigationSplitView expression stopped type-checking in reasonable time.
    private var schemaSidebar: some View {
        SchemaSidebar(
            tree: app.console.schema,
            hiddenSchemas: app.currentHiddenSchemas,
            reveal: app.schemaReveal,
            connectionName: app.console.connectionName,
            status: app.console.status,
            engine: app.console.activeSession?.engine,
            onRevealDatabaseFile: {
                if let path = app.console.activeSession?.database, !path.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            },
            onRevealHandled: { app.schemaReveal = nil },
            databases: app.console.activeSession?.databases ?? [],
            onSwitchDatabase: { database in
                if let profileID = app.console.currentProfileID {
                    app.switchDatabase(profileID: profileID, to: database)
                }
            },
            onNewQueryTab: { app.newQueryTabForCurrentConnection() },
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
            onOpenDiagram: { schema in
                app.console.openDiagram(schema: schema)
            },
            onShowTableInDiagram: { schema, table in
                app.console.openDiagram(schema: schema, scope: .table(table))
            },
            onDDL: { app.startDDL($0) },
            onOpenTables: { tables in
                // One sequential Task, not one per table — looping the plain
                // per-table open() would spawn independent unstructured Tasks
                // whose activate() calls could land out of order.
                Task {
                    for (schema, table) in tables {
                        await app.console.openTable(schema: schema, table: table)
                    }
                }
            },
            onDumpTables: { schema, tables in
                if let profileID = app.console.currentProfileID {
                    app.exportTables(profileID: profileID, schema: schema, tables: tables)
                }
            },
            onDumpSchemas: { schemas in
                if let profileID = app.console.currentProfileID {
                    app.exportSchemas(profileID: profileID, schemas: schemas)
                }
            })
    }
}
