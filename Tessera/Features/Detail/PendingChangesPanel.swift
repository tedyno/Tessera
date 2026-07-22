import SwiftUI

/// Persistent list of the exact statements ⌘↩ will run — each with its own
/// discard (×) button, plus a Discard-All shortcut.
struct PendingChangesPanel: View {
    @Bindable var model: QueryConsoleModel
    var tab: QueryTab

    var body: some View {
        let changes = model.pendingChanges(tab)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Pending changes", systemImage: "pencil.and.list.clipboard")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) {
                    model.discardPending(tab)
                } label: {
                    Label("Discard All", systemImage: "trash")
                }
                .controlSize(.small)
                Text("⌘↩ to commit").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(changes) { change in
                        HStack(spacing: 6) {
                            Button {
                                model.revert(tab, change.target)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Discard this change")

                            Circle().fill(color(for: change.target)).frame(width: 6, height: 6)
                            // Newlines inside a value literal would end the one-line
                            // preview at the first line — collapse them visibly; a
                            // long statement scrolls horizontally instead of being
                            // truncated, and the tooltip carries the exact SQL.
                            ScrollView(.horizontal) {
                                Text(change.statement.replacingOccurrences(of: "\n", with: " ⏎ "))
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                            }
                            .scrollIndicators(.hidden)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(change.statement)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .frame(height: 120)
        .background(.quaternary.opacity(0.4))
    }

    /// Dot color matching the row highlight: red delete, orange update, green insert.
    private func color(for target: PendingChange.Target) -> Color {
        switch target {
        case .delete: .red
        case .update: .orange
        case .insert: .green
        }
    }
}
