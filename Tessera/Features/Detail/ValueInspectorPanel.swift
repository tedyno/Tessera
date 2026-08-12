import SwiftUI
import AppKit
import DBKit

/// The value inspector below the results grid: shows the selected cell's full
/// value, pretty-printing JSON when it parses.
struct ValueInspectorPanel: View {
    var tab: QueryTab

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let cell = tab.inspected {
                HStack(spacing: 6) {
                    Text(cell.column).font(.caption.bold())
                    if !cell.typeName.isEmpty {
                        Text(cell.typeName).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let value = cell.value {
                        Text("\(value.count) chars").font(.caption2).foregroundStyle(.tertiary)
                        Button { copyToPasteboard(value) } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy value")
                    }
                }
                Divider()
                ScrollView {
                    Group {
                        if let value = cell.value {
                            JSONInspectorView(value: value, fallback: inspectorText(value))
                        } else {
                            Text("NULL").font(.callout.monospaced().italic()).foregroundStyle(.secondary)
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Select a single cell to inspect its value.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(10)
        .frame(height: 150)
        .background(.ultraThinMaterial)
    }

    /// Pretty-prints a value that is valid JSON; otherwise returns it unchanged.
    /// The whitespace-only formatter first, so key order and number spelling stay
    /// as stored. It declines above `JSONText.sizeLimit` — and so does the tree —
    /// which is exactly where an unformatted single line is least readable, so a
    /// huge document still falls back to `JSONSerialization` (reordered keys, but
    /// indented) rather than to one endless line.
    private func inspectorText(_ raw: String) -> String {
        if let pretty = JSONText.prettyPrinted(raw) { return pretty }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[",
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: pretty, encoding: .utf8) else { return raw }
        return string
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
