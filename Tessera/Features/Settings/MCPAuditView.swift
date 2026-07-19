import SwiftUI

/// Shows what MCP clients have been doing, plus the server's current state, so the
/// integration is never a black box.
struct MCPAuditView: View {
    let app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if app.mcpAudit.entries.isEmpty {
                ContentUnavailableView("No MCP activity", systemImage: "sparkles",
                                       description: Text("Requests from MCP clients will appear here."))
                    .frame(maxHeight: .infinity)
            } else {
                List(app.mcpAudit.entries) { entry in
                    row(entry)
                }
            }
        }
        .frame(width: 640, height: 460)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("MCP Activity").font(.headline)
                status
            }
            Spacer()
            Button("Clear") { app.mcpAudit.clear() }
                .disabled(app.mcpAudit.entries.isEmpty)
            Button("Done") { dismiss() }
        }
        .padding()
    }

    @ViewBuilder private var status: some View {
        if let error = app.mcpError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.red)
        } else if app.mcpRunning {
            Label("Listening on 127.0.0.1:\(MCPSettings.port)", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption).foregroundStyle(.green)
        } else {
            Label("Server off — enable it in Settings", systemImage: "moon.zzz")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ entry: MCPAuditLog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(entry.tool)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Text(entry.connection).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(entry.date, format: .dateTime.hour().minute().second())
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Text(entry.detail)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(3)
                .textSelection(.enabled)
            Text(entry.outcome)
                .font(.caption2)
                .foregroundStyle(outcomeColor(entry.outcome))
        }
        .padding(.vertical, 3)
    }

    private func outcomeColor(_ outcome: String) -> Color {
        if outcome.hasPrefix("failed") { return .red }
        if outcome == "declined" { return .orange }
        return .secondary
    }
}
