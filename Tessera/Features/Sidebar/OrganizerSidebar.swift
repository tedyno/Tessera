import SwiftUI
import DBKit

/// Column 1 — the connection organizer. Phase 2a: a flat list of saved
/// connections with selection, add (+) and delete. Phase 2b turns this into the
/// Workspace → Project → Folder → Connection tree with drag & drop.
struct OrganizerSidebar: View {
    let connections: ConnectionsModel
    @Binding var selection: UUID?
    var onAdd: () -> Void

    var body: some View {
        List(selection: $selection) {
            Section("Connections") {
                if connections.profiles.isEmpty {
                    Text("No connections")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(connections.profiles) { profile in
                        Label {
                            Text(profile.name)
                        } icon: {
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(color(for: profile.kind))
                                .frame(width: 9, height: 9)
                        }
                        .tag(profile.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                connections.delete(profile)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New connection")
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private func color(for kind: DatabaseKind) -> Color {
        switch kind {
        case .postgres: .blue
        case .mysql: .orange
        }
    }
}
