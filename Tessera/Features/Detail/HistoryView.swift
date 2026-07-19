import SwiftUI
import AppKit
import DBPersistence

/// Searchable list of previously executed queries. Tapping one loads it into the
/// active tab.
struct HistoryView: View {
    let history: [QueryHistoryEntry]
    /// Loads the entry into a tab bound to its original connection (no run).
    var onPick: (QueryHistoryEntry) -> Void
    /// Loads and runs the entry against its original connection.
    var onRun: (QueryHistoryEntry) -> Void = { _ in }
    var onClear: () -> Void = { }

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var confirmingClear = false

    private var filtered: [QueryHistoryEntry] {
        guard !search.isEmpty else { return history }
        return history.filter {
            $0.sql.localizedCaseInsensitiveContains(search)
                || $0.connectionName.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Query History").font(.headline)
                Spacer()
                Button(role: .destructive) { confirmingClear = true } label: { Text("Clear") }
                    .disabled(history.isEmpty)
                Button("Done") { dismiss() }
            }
            .padding()
            .confirmationDialog("Clear the entire query history?",
                                isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear History", role: .destructive) { onClear() }
                Button("Cancel", role: .cancel) { }
            }

            TextField("Search queries…", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 8)

            Divider()

            if filtered.isEmpty {
                ContentUnavailableView("No history", systemImage: "clock",
                                       description: Text("Executed queries will appear here."))
                    .frame(maxHeight: .infinity)
            } else {
                List(filtered) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.sql)
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(2)
                            HStack(spacing: 10) {
                                Text(entry.connectionName)
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
        }
        .frame(width: 560, height: 480)
    }
}
