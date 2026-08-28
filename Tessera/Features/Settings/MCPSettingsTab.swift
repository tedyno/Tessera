import AppKit
import DBKit
import SwiftUI

/// MCP server preferences: the master switch, port, and client-config helpers.
/// Persistence lives in `MCPSettings`; every change posts `.mcpSettingsChanged`
/// so the app restarts the server.
struct MCPSettingsTab: View {
    @State private var mcpEnabled = MCPSettings.isEnabled
    @State private var mcpPort = MCPSettings.port
    @State private var client: MCPClientConfig.Client = .claudeCode

    /// Why the snippet is more than a server entry: a client decides on its own
    /// whether to stop and ask, and it does not learn that from Tessera's settings.
    private var clientHint: LocalizedStringKey {
        switch client {
        case .claudeCode:
            """
            Copies the command that adds the server. Then allow the rule \
            “mcp__tessera” in /permissions, so the safe tools run without a prompt — \
            importing a dump, deleting or editing a connection still asks every time.
            """
        case .codex:
            """
            Adds the server in approval mode “writes”: reads and exports run \
            unattended, anything that can change data asks first.
            """
        case .generic:
            """
            The server entry only. Your client decides for itself which tools it runs \
            without asking.
            """
        }
    }

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
                            Picker("", selection: $client) {
                                ForEach(MCPClientConfig.Client.allCases) { option in
                                    Text(verbatim: option.label).tag(option)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 160)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    MCPSettings.clientConfigSnippet(for: client), forType: .string)
                            }
                            Button("New token") {
                                MCPSettings.regenerateToken()
                                NotificationCenter.default.post(name: .mcpSettingsChanged, object: nil)
                            }
                        }
                    }
                    Text(clientHint)
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Generating a new token invalidates the old one.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Assistant notes") {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(MCPClientConfig.assistantBriefing,
                                                           forType: .string)
                        }
                    }
                    Text("""
                        Paste these to your assistant if it keeps asking for approval, or \
                        thinks a hidden connection is broken. They explain that its own \
                        client gates tool calls separately from Tessera, and what to change.
                        """)
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
