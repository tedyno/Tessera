import SwiftUI
import DBKit
import DBPersistence

/// Column 1 — the connection organizer tree (Workspace → Project → Folder →
/// Connection), backed by NSOutlineView for reliable drag & drop. This wrapper
/// adds the bottom "+" menu and the name-entry alerts.
struct OrganizerSidebar: View {
    let model: ConnectionsModel
    /// The highlighted node, in as a value and out through `onSelect` — see
    /// `OrganizerOutlineView.selection` for why this isn't a `Binding`.
    var selection: UUID?
    var onSelect: (UUID) -> Void
    /// Opens the New Connection sheet targeting the given parent container.
    var onNewConnection: (UUID?) -> Void
    /// Opens the editor for the connection at the given tree node id.
    var onEditConnection: (UUID) -> Void = { _ in }
    var onDuplicateConnection: (UUID) -> Void = { _ in }
    var onConnectProfile: (UUID) -> Void = { _ in }
    var onDisconnect: (UUID) -> Void = { _ in }
    var onReconnect: (UUID) -> Void = { _ in }
    var onIntrospect: (UUID) -> Void = { _ in }
    var onExport: (UUID) -> Void = { _ in }
    var onImport: (UUID) -> Void = { _ in }
    var onNewQueryTab: (UUID) -> Void = { _ in }
    var connectionDot: (UUID) -> ConnectionDot = { _ in .none }
    var statusVersion: Int = 0
    /// Disconnects every live connection at once.
    var onDisconnectAll: () -> Void = { }
    var hasActiveConnections: Bool = false

    private enum PendingEdit {
        case rename(id: UUID)
        case newFolder(parent: UUID)
        case newProject(workspace: UUID)
        case newWorkspace
    }
    @State private var pending: PendingEdit?
    @State private var editText = ""
    /// The unified search: the bottom field and tree-typed characters drive
    /// one speed search (matches are jumped to and tinted, never filtered).
    @State private var speed = SpeedSearchState()

    var body: some View {
        OrganizerOutlineView(
            model: model,
            selection: selection,
            onSelect: onSelect,
            onNewConnection: onNewConnection,
            onNewFolder: { startNewFolder(parent: $0) },
            onNewProject: { startNewProject(workspace: $0) },
            onNewWorkspace: { editText = ""; pending = .newWorkspace },
            onRename: { id, current in editText = current; pending = .rename(id: id) },
            onSetColor: { id, color in model.setFolderColor(color, folderID: id) },
            onSetConnectionColor: { profileID, color in model.setProfileColor(color, profileID: profileID) },
            onEditConnection: onEditConnection,
            onDuplicateConnection: onDuplicateConnection,
            onConnectProfile: onConnectProfile,
            onDisconnect: onDisconnect,
            onReconnect: onReconnect,
            onIntrospect: onIntrospect,
            onExport: onExport,
            onImport: onImport,
            onNewQueryTab: onNewQueryTab,
            connectionDot: connectionDot,
            version: model.stateVersion,
            onSpeedSearch: { term, position, count in
                speed.update(term: term, position: position, count: count)
            },
            searchTerm: speed.searchText,
            keyboardStepToken: speed.keyboardStepToken,
            keyboardStep: speed.keyboardStep,
            keyboardCommitToken: speed.keyboardCommitToken,
            statusVersion: statusVersion)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .alert(alertTitle, isPresented: pendingBinding) {
            TextField("Name", text: $editText)
            Button("OK", action: commit)
            Button("Cancel", role: .cancel) { pending = nil }
        }
    }

    private var bottomBar: some View {
        SidebarFooter(speed: speed) {
            actionsRow
        }
    }

    private var actionsRow: some View {
        HStack {
            Menu {
                Button("New Connection") { onNewConnection(model.organizer.workspaces.first?.id) }
                Button("New Folder") { startNewFolder(parent: model.organizer.workspaces.first?.id) }
                Divider()
                Button("New Workspace") { editText = ""; pending = .newWorkspace }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Add")
            Spacer()
            Button {
                onDisconnectAll()
            } label: {
                Image(systemName: "bolt.slash")
            }
            .buttonStyle(.borderless)
            .disabled(!hasActiveConnections)
            .help("Disconnect All")
        }
    }

    // MARK: Alert plumbing

    private var pendingBinding: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    private var alertTitle: String {
        switch pending {
        case .rename: "Rename"
        case .newFolder: "New Folder"
        case .newProject: "New Project"
        case .newWorkspace: "New Workspace"
        case nil: ""
        }
    }

    private func commit() {
        switch pending {
        case .rename(let id): model.rename(id, to: editText)
        case .newFolder(let parent): model.addFolder(name: editText, into: parent)
        case .newProject(let workspace): model.addProject(name: editText, into: workspace)
        case .newWorkspace: model.addWorkspace(name: editText)
        case nil: break
        }
        pending = nil
    }

    private func startNewFolder(parent: UUID?) {
        guard let parent else { return }
        editText = ""
        pending = .newFolder(parent: parent)
    }

    private func startNewProject(workspace: UUID) {
        editText = ""
        pending = .newProject(workspace: workspace)
    }
}
