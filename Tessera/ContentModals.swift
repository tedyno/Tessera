import AppKit
import DBKit
import SwiftUI

extension View {
    /// Every sheet, alert and dialog `ContentView` puts on screen.
    ///
    /// They live here rather than inline because SwiftUI type-checks a modifier chain
    /// as one expression: past a certain length the compiler gives up on the whole
    /// body and blames whichever closure it happened to stall in, which makes adding
    /// any new modal a guessing game. One grouped modifier keeps that bounded.
    func contentModals(_ app: AppModel) -> some View {
        modifier(ContentModals(app: app))
    }
}

private struct ContentModals: ViewModifier {
    @Bindable var app: AppModel

    func body(content: Content) -> some View {
        content
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
        .batchRunConfirm(app)
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
                          onRun: { await app.runDDL($0, for: operation) },
                          onClose: { app.ddlOperation = nil })
                .tesseraModalBackground()
        }
        .sheet(item: $app.importTarget) { target in
            Group {
                if let context = app.importContext(for: target) {
                    ImportView(context: context, service: app.dumpService,
                               jobs: app.backgroundJobs) { app.importTarget = nil }
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
                    ExportView(context: context, service: app.dumpService,
                               jobs: app.backgroundJobs) { app.exportTarget = nil }
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
        // An unreadable profiles file leaves the app with no connections. Saying so
        // loudly matters: silence looks like "they're gone", and the user might
        // start recreating them over a file that is merely damaged.
        .alert(Text("Connections could not be loaded"),
               isPresented: Binding(get: { app.connections.profileStoreFailure != nil },
                                    set: { _ in }),
               presenting: app.connections.profileStoreFailure) { _ in
            Button { NSApp.terminate(nil) } label: { Text("Quit") }
        } message: { failure in
            Text(verbatim: failure)
        }
        // A refused *write*, by contrast, is recoverable: the connections are still
        // there and the file is untouched. It gets its own dismissable alert — the
        // load alert above can only quit, which would be wrong here.
        .alert(Text("Connections could not be saved"),
               isPresented: Binding(get: { app.connections.profileSaveFailure != nil },
                                    set: { if !$0 { app.connections.dismissSaveFailure() } }),
               presenting: app.connections.profileSaveFailure) { _ in
            Button { app.connections.dismissSaveFailure() } label: { Text("OK") }
        } message: { failure in
            Text(verbatim: failure)
        }
        // A changed SSH host key blocks the connect; trusting the new key must be
        // an explicit decision, so it gets a real dialog, not just an error line.
        .alert(Text("SSH host key changed"),
               isPresented: Binding(get: { app.hostKeyPrompt != nil },
                                    set: { if !$0 { app.hostKeyPrompt = nil } }),
               presenting: app.hostKeyPrompt) { prompt in
            Button(role: .destructive) {
                app.trustPresentedHostKey(prompt)
            } label: {
                Text("Trust New Key and Reconnect")
            }
            Button(role: .cancel) { app.hostKeyPrompt = nil } label: { Text("Cancel") }
        } message: { prompt in
            Text("""
            The server \(prompt.mismatch.host) now identifies with a different \
            \(prompt.mismatch.presentedAlgorithm) key.

            Expected: \(prompt.mismatch.expectedFingerprint)
            Presented: \(prompt.mismatch.presentedFingerprint)

            This can mean the server was reinstalled — or that someone is \
            intercepting the connection. Only trust the new key if you know the \
            server's key really changed.
            """)
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
        .mcpApprovalSheet(app)
    }
}
