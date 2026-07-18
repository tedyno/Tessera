import SwiftUI
import UniformTypeIdentifiers
import DBKit
import DBPersistence

extension UTType {
    static let tesseraOrganizerNode = UTType(exportedAs: "io.github.tedyno.tessera.organizer-node")
}

/// Lightweight drag payload carrying a tree node's id for reordering.
struct DraggedNode: Codable, Transferable {
    let id: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .tesseraOrganizerNode)
    }
}

/// Column 1 — the connection organizer tree (Workspace → Project → Folder →
/// Connection) with CRUD via context menus and a bottom "+" menu. Drag & drop
/// reordering is the remaining Phase 2b step.
struct OrganizerSidebar: View {
    let model: ConnectionsModel
    @Binding var selection: UUID?
    /// Opens the New Connection sheet targeting the given parent container.
    var onNewConnection: (UUID?) -> Void

    private enum PendingEdit {
        case rename(id: UUID, current: String)
        case newFolder(parent: UUID)
        case newProject(workspace: UUID)
        case newWorkspace
    }
    @State private var pending: PendingEdit?
    @State private var editText = ""

    var body: some View {
        List(selection: $selection) {
            ForEach(model.organizer.workspaces) { workspace in
                Section {
                    OutlineGroup(workspace.children, children: \.children) { node in
                        rowView(node)
                    }
                } header: {
                    HStack {
                        Text(workspace.name)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .contextMenu { workspaceMenu(workspace) }
                    .dropDestination(for: DraggedNode.self) { items, _ in
                        guard let dragged = items.first else { return false }
                        return model.move(nodeID: dragged.id, toParent: workspace.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .alert(alertTitle, isPresented: pendingBinding) {
            TextField("Name", text: $editText)
            Button("OK", action: commit)
            Button("Cancel", role: .cancel) { pending = nil }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func rowView(_ node: OrganizerNode) -> some View {
        let row = nodeLabel(node)
            .contextMenu { nodeMenu(node) }
            .draggable(DraggedNode(id: node.id))
        if node.isContainer {
            row.dropDestination(for: DraggedNode.self) { items, _ in
                guard let dragged = items.first else { return false }
                return model.move(nodeID: dragged.id, toParent: node.id)
            }
        } else {
            row
        }
    }

    @ViewBuilder
    private func nodeLabel(_ node: OrganizerNode) -> some View {
        switch node {
        case .project(let project):
            Label(project.name, systemImage: "square.stack.3d.up.fill")
        case .folder(let folder):
            Label(folder.name, systemImage: "folder.fill").foregroundStyle(.tint)
        case .connection(let ref):
            let profile = model.profile(id: ref.profileID)
            Label {
                Text(profile?.name ?? "Connection")
            } icon: {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(color(for: profile?.kind))
                    .frame(width: 9, height: 9)
            }
        }
    }

    // MARK: Menus

    @ViewBuilder
    private func nodeMenu(_ node: OrganizerNode) -> some View {
        if node.isContainer {
            Button("New Connection") { onNewConnection(node.id) }
            Button("New Folder") { startNewFolder(parent: node.id) }
            Divider()
            Button("Rename") { startRename(id: node.id, current: node.displayName ?? "") }
        } else {
            Button("Connect") { selection = node.id }
        }
        moveMenu(node)
        Button("Delete", role: .destructive) { model.deleteNode(node.id) }
    }

    @ViewBuilder
    private func moveMenu(_ node: OrganizerNode) -> some View {
        Menu("Move to") {
            ForEach(model.organizer.workspaces) { workspace in
                Button(workspace.name) { model.move(nodeID: node.id, toParent: workspace.id) }
            }
        }
    }

    @ViewBuilder
    private func workspaceMenu(_ workspace: Workspace) -> some View {
        Button("New Connection") { onNewConnection(workspace.id) }
        Button("New Folder") { startNewFolder(parent: workspace.id) }
        Button("New Project") { startNewProject(workspace: workspace.id) }
        Divider()
        Button("Rename") { startRename(id: workspace.id, current: workspace.name) }
        Button("Delete Workspace", role: .destructive) { model.deleteWorkspace(workspace.id) }
    }

    private var bottomBar: some View {
        HStack {
            Menu {
                Button("New Connection") { onNewConnection(model.organizer.workspaces.first?.id) }
                Button("New Folder") { startNewFolder(parent: model.organizer.workspaces.first?.id) }
                Divider()
                Button("New Workspace") { pending = .newWorkspace; editText = "" }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Add")
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
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
        case .rename(let id, _): model.rename(id, to: editText)
        case .newFolder(let parent): model.addFolder(name: editText, into: parent)
        case .newProject(let workspace): model.addProject(name: editText, into: workspace)
        case .newWorkspace: model.addWorkspace(name: editText)
        case nil: break
        }
        pending = nil
    }

    private func startRename(id: UUID, current: String) {
        editText = current
        pending = .rename(id: id, current: current)
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

    private func color(for kind: DatabaseKind?) -> Color {
        switch kind {
        case .postgres: .blue
        case .mysql: .orange
        case nil: .secondary
        }
    }
}
