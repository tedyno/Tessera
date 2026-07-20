import SwiftUI
import AppKit

/// The full connection diagnostics: every stage of every attempt, with the raw
/// error and the settings it used. Reachable from the status bar, because the one
/// line there is never enough to tell why a connection failed.
struct ConnectionLogView: View {
    let log: ConnectionLog

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var failuresOnly = false
    @State private var expanded: Set<UUID> = []

    private var entries: [ConnectionLog.Entry] {
        log.entries.filter { entry in
            if failuresOnly, !entry.isError { return false }
            guard !search.isEmpty else { return true }
            return entry.message.localizedCaseInsensitiveContains(search)
                || entry.connection.localizedCaseInsensitiveContains(search)
                || (entry.detail ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connection Log").font(.headline)
                Spacer()
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.plainText, forType: .string)
                }
                .disabled(log.entries.isEmpty)
                Button(role: .destructive) { log.clear() } label: { Text("Clear") }
                    .disabled(log.entries.isEmpty)
                Button("Done") { dismiss() }
            }
            .padding()

            HStack {
                TextField("Search…", text: $search).textFieldStyle(.roundedBorder)
                Toggle("Failures only", isOn: $failuresOnly).toggleStyle(.checkbox)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            if entries.isEmpty {
                ContentUnavailableView("Nothing logged yet", systemImage: "text.alignleft",
                                       description: Text("Connection attempts appear here."))
                    .frame(maxHeight: .infinity)
            } else {
                List(entries) { entry in row(entry) }
            }
        }
        .frame(width: 680, height: 520)
    }

    private func row(_ entry: ConnectionLog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: entry.isError ? "xmark.circle.fill" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(entry.isError ? Color.red : .secondary)
                Text(entry.stage.rawValue)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Text(entry.connection).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(entry.date, format: .dateTime.hour().minute().second())
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Text(entry.message)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(entry.isError ? Color.red : .primary)
                .textSelection(.enabled)

            if let detail = entry.detail, !detail.isEmpty {
                if expanded.contains(entry.id) {
                    Text(detail)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                }
                Button(expanded.contains(entry.id) ? "Hide details" : "Show details") {
                    if expanded.contains(entry.id) { expanded.remove(entry.id) }
                    else { expanded.insert(entry.id) }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(.vertical, 3)
    }
}
