import SwiftUI
import DBKit

struct ContentView: View {
    @Bindable var app: AppModel

    var body: some View {
        // Custom chrome instead of NavigationSplitView: the two sidebar panes
        // float as rounded glass cards over the window-wide gradient backdrop,
        // matching the Liquid Glass design concept.
        HStack(spacing: 0) {
            if app.columnVisibility != .detailOnly {
                sidebarColumn
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
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
        .animation(.smooth(duration: 0.25), value: app.columnVisibility)
        .coordinateSpace(name: "contentRow")
        .background { TesseraBackdrop() }
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
            .tesseraModalBackground()
        }
        .sheet(isPresented: $app.showingEditConnection) {
            if let profile = app.editingProfile {
                NewConnectionView(editing: profile, secrets: app.editingSecrets) { updated, secrets in
                    app.connections.updateConnection(updated, secrets: secrets)
                }
                .tesseraModalBackground()
            }
        }
        .sheet(isPresented: $app.showingDuplicateConnection) {
            if let profile = app.duplicatingProfile {
                NewConnectionView(editing: profile, secrets: app.duplicatingSecrets,
                                  duplicating: true) { updated, secrets in
                    app.finishDuplicate(updated, secrets: secrets)
                }
                .tesseraModalBackground()
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
                .tesseraModalBackground()
        }
        .sheet(item: $app.importTarget) { target in
            Group {
                if let context = app.importContext(for: target) {
                    ImportView(context: context, service: app.dumpService) { app.importTarget = nil }
                } else {
                    VStack(spacing: 12) {
                        Text("Cannot import into this connection.")
                        Button("Close") { app.importTarget = nil }
                    }.padding(30)
                }
            }
            .tesseraModalBackground()
        }
        .sheet(item: $app.exportTarget) { target in
            Group {
                if let context = app.exportContext(for: target) {
                    ExportView(context: context, service: app.dumpService) { app.exportTarget = nil }
                } else {
                    VStack(spacing: 12) {
                        Text("Cannot export this connection.")
                        Button("Close") { app.exportTarget = nil }
                    }.padding(30)
                }
            }
            .tesseraModalBackground()
        }
        .sheet(item: $app.pendingParameterRun) { pending in
            QueryParametersSheet(names: pending.names,
                                 initial: app.lastParameterValues,
                                 onRun: { app.runPendingParameters($0) },
                                 onCancel: { app.pendingParameterRun = nil })
                .tesseraModalBackground()
        }
        .sheet(isPresented: $app.showingMCPLog) {
            MCPAuditView(app: app)
                .tesseraModalBackground()
        }
        .sheet(isPresented: $app.showingSpotlight) {
            SpotlightView(app: app)
                .tesseraModalBackground()
        }
        .sheet(isPresented: $app.showingCommandPalette) {
            CommandPalette(app: app)
                .tesseraModalBackground()
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
            .tesseraModalBackground()
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

    /// Organizer/schema height split as a ratio of the sidebar column. Fixed
    /// 50:50 by default; only an explicit drag on the gap changes it, so
    /// window resizes scale both cards proportionally and nothing ever
    /// reflows on its own.
    @AppStorage("tessera.sidebarSplitRatio") private var sidebarSplitRatio = 0.5

    /// The sidebar column's width, persisted across launches and adjusted by the
    /// handle on its right edge.
    @AppStorage("tessera.sidebarWidth") private var sidebarWidth = 300.0
    /// Captured at drag start so the handle grabs exactly under the cursor (no jump)
    /// and stays stable as the layout reflows mid-drag.
    @State private var sidebarDragOffset: CGFloat?
    /// The width while a drag is in flight; the persisted value is written only on
    /// release, so dragging doesn't hit UserDefaults every frame.
    @State private var liveSidebarWidth: CGFloat?

    private var currentSidebarWidth: CGFloat { liveSidebarWidth ?? CGFloat(sidebarWidth) }

    private static let minSidebarWidth: CGFloat = 220
    private static let maxSidebarWidth: CGFloat = 640

    /// The organizer and schema panes as stacked floating glass cards; the
    /// gap between them is a draggable splitter.
    private var sidebarColumn: some View {
        GeometryReader { geo in
            let gap: CGFloat = 10
            let available = max(geo.size.height - gap, 200)
            let ratio = min(max(sidebarSplitRatio, 0.15), 0.85)
            VStack(spacing: 0) {
                // Each sidebar is its own `View` so it tracks only the state it
                // reads. Inlined into `body`, every observed property they touch
                // (e.g. the connection-status tick) became a dependency of the
                // whole `ContentView`, rebuilding both trees on any change.
                OrganizerSidebarColumn(app: app)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .floatingPanel()
                    .frame(height: available * ratio)
                splitter(available: available)
                SchemaSidebarColumn(app: app)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .floatingPanel()
            }
            .coordinateSpace(name: "sidebarColumn")
        }
        .frame(width: currentSidebarWidth)
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 10, trailing: 6))
        // Overlaid on the trailing edge, so the handle sits in the gap between the
        // sidebar card and the detail without consuming layout (no empty column).
        .overlay(alignment: .trailing) { sidebarResizeHandle }
    }

    /// The draggable strip on the sidebar's right edge; widens/narrows the column
    /// and persists the width. Location-based in the row's coordinate space so the
    /// value doesn't jump as the sidebar reflows under the cursor.
    private var sidebarResizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .offset(x: -3)   // nudge into the card/detail gap
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("contentRow"))
                    .onChanged { value in
                        let offset = sidebarDragOffset ?? (value.location.x - currentSidebarWidth)
                        if sidebarDragOffset == nil { sidebarDragOffset = offset }
                        liveSidebarWidth = min(max(value.location.x - offset, Self.minSidebarWidth),
                                               Self.maxSidebarWidth)
                    }
                    .onEnded { _ in
                        if let width = liveSidebarWidth { sidebarWidth = Double(width) }
                        liveSidebarWidth = nil
                        sidebarDragOffset = nil
                    })
    }

    /// The transparent gap between the cards, draggable to re-balance them.
    private func splitter(available: CGFloat) -> some View {
        Color.clear
            .frame(height: 10)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .named("sidebarColumn"))
                    .onChanged { value in
                        sidebarSplitRatio = min(max(value.location.y / available, 0.15), 0.85)
                    })
    }

}

/// The organizer tree as its own `View`, so the connection-status tick and
/// profile edits only re-render this column — not the whole `ContentView`.
private struct OrganizerSidebarColumn: View {
    @Bindable var app: AppModel

    var body: some View {
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
    }
}

/// The live schema tree as its own `View`, isolated from unrelated `ContentView`
/// state so a schema deep-hash/rebuild only runs when schema state changes.
private struct SchemaSidebarColumn: View {
    let app: AppModel

    /// Stands in for the tree's content when deciding whether the outline must
    /// rebuild: which profile, which schema generation, and live vs cached.
    private var treeIdentity: Int {
        var hasher = Hasher()
        hasher.combine(app.console.currentProfileID)
        hasher.combine(app.console.activeSession?.schemaGeneration ?? -1)
        hasher.combine(app.console.isShowingCachedSchema)
        return hasher.finalize()
    }

    var body: some View {
        SchemaSidebar(
            tree: app.console.schema,
            treeIdentity: treeIdentity,
            hiddenSchemas: app.currentHiddenSchemas,
            reveal: app.schemaReveal,
            connectionName: app.console.connectionName,
            status: app.console.status,
            isCached: app.console.isShowingCachedSchema,
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
