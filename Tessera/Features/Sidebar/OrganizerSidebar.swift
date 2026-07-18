import SwiftUI
import DBKit
import DBPersistence

/// Column 1 — the user's connection organizer (Workspace → Project → Folder →
/// Connection). Phase 0: read-only tree from sample data. CRUD, rename and
/// drag & drop arrive in Phase 2b.
struct OrganizerSidebar: View {
    let document: OrganizerDocument
    let profiles: [UUID: ConnectionProfile]
    @Binding var selection: UUID?

    var body: some View {
        List(selection: $selection) {
            ForEach(document.workspaces) { workspace in
                Section(workspace.name) {
                    OutlineGroup(workspace.children, children: \.children) { node in
                        nodeLabel(node)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func nodeLabel(_ node: OrganizerNode) -> some View {
        switch node {
        case .project(let project):
            Label(project.name, systemImage: "square.stack.3d.up.fill")
        case .folder(let folder):
            Label(folder.name, systemImage: "folder.fill")
                .foregroundStyle(.tint)
        case .connection(let ref):
            let profile = profiles[ref.profileID]
            Label {
                Text(profile?.name ?? String(localized: "Connection"))
            } icon: {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(color(for: profile?.kind))
                    .frame(width: 9, height: 9)
            }
        }
    }

    private func color(for kind: DatabaseKind?) -> Color {
        switch kind {
        case .postgres: .blue
        case .mysql: .orange
        case nil: .secondary
        }
    }
}
