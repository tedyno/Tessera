import SwiftUI
import AppKit
import DBPersistence

/// Searchable list of previously executed queries. Tapping one loads it into the
/// active tab. Scoped to the connection in focus by default — history is kept per
/// connection, so the list opens showing only what ran against this database.
struct HistoryView: View {
    /// Every recorded entry, across all connections; the scope picker filters it.
    let history: [QueryHistoryEntry]
    /// The connection in focus, or `nil` when none is (then only "all" is offered).
    var activeProfileID: UUID?
    var activeConnectionName: String?
    /// Loads the entry into a tab bound to its original connection (no run).
    var onPick: (QueryHistoryEntry) -> Void
    /// Loads and runs the entry against its original connection.
    var onRun: (QueryHistoryEntry) -> Void = { _ in }
    /// Clears one connection's history, or all of it when the id is `nil`.
    var onClear: (UUID?) -> Void = { _ in }

    private enum Scope: Hashable { case connection, all }

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var scope: Scope = .connection
    @State private var confirmingClear = false

    /// The picked scope, forced to `.all` when there is no connection to scope to.
    private var effectiveScope: Scope { activeProfileID == nil ? .all : scope }
    private var isScoped: Bool { effectiveScope == .connection }

    private var scoped: [QueryHistoryEntry] {
        QueryHistoryStore.entries(history, for: isScoped ? activeProfileID : nil)
    }

    private func matching(_ entries: [QueryHistoryEntry]) -> [QueryHistoryEntry] {
        guard !search.isEmpty else { return entries }
        return entries.filter {
            $0.sql.localizedCaseInsensitiveContains(search)
                || $0.connectionName.localizedCaseInsensitiveContains(search)
        }
    }

    private var clearTitle: Text {
        if isScoped, let name = activeConnectionName {
            return Text("Clear the query history for “\(name)”?")
        }
        return Text("Clear the entire query history?")
    }

    var body: some View {
        // Scope- and search-filter the history once per render — the Clear button,
        // the empty check, and the list all read the same computed result.
        let scopedEntries = scoped
        let filtered = matching(scopedEntries)
        return VStack(spacing: 0) {
            HStack {
                Text("Query History").font(.headline)
                Spacer()
                Button(role: .destructive) { confirmingClear = true } label: { Text("Clear") }
                    .disabled(scopedEntries.isEmpty)
                Button("Done") { dismiss() }
            }
            .padding(.horizontal)
            .padding(.top)
            .confirmationDialog(clearTitle, isPresented: $confirmingClear,
                                titleVisibility: .visible) {
                Button("Clear History", role: .destructive) {
                    onClear(isScoped ? activeProfileID : nil)
                }
                Button("Cancel", role: .cancel) { }
            }

            if activeProfileID != nil {
                Picker("Scope", selection: $scope) {
                    Text("This Connection").tag(Scope.connection)
                    Text("All Connections").tag(Scope.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal)
                .padding(.top, 8)
            }

            TextField("Search queries…", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.vertical, 8)

            Divider()

            if filtered.isEmpty {
                emptyState.frame(maxHeight: .infinity)
            } else {
                List(filtered) { entry in
                    row(entry)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 560, height: 480)
    }

    @ViewBuilder
    private var emptyState: some View {
        if isScoped {
            ContentUnavailableView {
                Label("No history for this connection", systemImage: "clock")
            } description: {
                Text("Queries run on this connection will appear here.")
            } actions: {
                Button("Show All Connections") { scope = .all }
            }
        } else {
            ContentUnavailableView("No history", systemImage: "clock",
                                   description: Text("Executed queries will appear here."))
        }
    }

    private func row(_ entry: QueryHistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.isTableView ? "tablecells" : "terminal")
                .font(.system(size: 12))
                .foregroundStyle(entry.isTableView ? Color.teal : Color.secondary)
                .frame(width: 16)
                .padding(.top, 2)
                .help(entry.isTableView ? "Table view" : "Query")
            VStack(alignment: .leading, spacing: 4) {
                if entry.isTableView, let schema = entry.schema, let table = entry.table {
                    Text("\(schema).\(table)").font(.callout.weight(.medium))
                    Text(entry.sql)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(entry.sql)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(2)
                }
                HStack(spacing: 10) {
                    // Redundant when every row belongs to the same connection.
                    if !isScoped { Text(entry.connectionName) }
                    Text(entry.timestamp, format: .dateTime.day().month().hour().minute())
                    if let rows = entry.rowCount { Text("\(rows) rows") }
                    if let ms = entry.elapsedMS { Text("\(ms) ms") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Run") { onRun(entry) }
                .controlSize(.small)
                .help("Run against the connection it came from")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { onPick(entry) }
        .contextMenu {
            Button("Load into Editor") { onPick(entry) }
            Button("Run") { onRun(entry) }
            Divider()
            Button("Copy SQL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.sql, forType: .string)
            }
        }
    }
}
