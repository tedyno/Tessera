import SwiftUI
import DBPersistence

/// Searchable list of previously executed queries. Tapping one loads it into the
/// active tab.
struct HistoryView: View {
    let history: [QueryHistoryEntry]
    var onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

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
                Button("Done") { dismiss() }
            }
            .padding()

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
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture { onPick(entry.sql) }
                }
            }
        }
        .frame(width: 560, height: 480)
    }
}
