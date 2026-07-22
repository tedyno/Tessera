import SwiftUI
import AppKit

/// MCP server preferences: the master switch, port, and client-config helpers.
/// Persistence lives in `MCPSettings`; every change posts `.mcpSettingsChanged`
/// so the app restarts the server.
struct MCPSettingsTab: View {
    @State private var mcpEnabled = MCPSettings.isEnabled
    @State private var mcpPort = MCPSettings.port

    var body: some View {
        Form {
            Section("MCP server") {
                Toggle("Enable the MCP server", isOn: $mcpEnabled)
                    .onChange(of: mcpEnabled) { _, newValue in
                        MCPSettings.isEnabled = newValue
                        NotificationCenter.default.post(name: .mcpSettingsChanged, object: nil)
                    }
                if mcpEnabled {
                    LabeledContent("Port") {
                        TextField("", value: $mcpPort, format: .number.grouping(.never))
                            .frame(width: 90)
                            .onSubmit {
                                MCPSettings.port = mcpPort
                                NotificationCenter.default.post(name: .mcpSettingsChanged, object: nil)
                            }
                    }
                    LabeledContent("Client config") {
                        HStack {
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(MCPSettings.clientConfigSnippet,
                                                               forType: .string)
                            }
                            Button("New token") {
                                MCPSettings.regenerateToken()
                                NotificationCenter.default.post(name: .mcpSettingsChanged, object: nil)
                            }
                        }
                    }
                    Text("Paste the copied JSON into your MCP client. Generating a new token "
                         + "invalidates the old one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Off by default. When on, Tessera listens on 127.0.0.1 so an MCP client "
                     + "such as Claude Code or Codex can query it — but only connections that individually "
                     + "allow MCP access are exposed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
