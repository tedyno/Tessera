import SwiftUI

/// The approval Tessera shows before an MCP client writes, imports or exports.
///
/// Lives in its own file rather than inline in `ContentView`: that view's modifier
/// chain is long enough that one more multi-line closure stops the type checker from
/// finishing in reasonable time.
struct MCPApprovalSheet: View {
    @Bindable var app: AppModel
    let request: MCPApprovals.Request

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(request.title, systemImage: "sparkles")
                .font(.headline)
            Text("Requested over MCP. Review it before allowing.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(request.detail)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 110)
            .padding(8)
            .background(.quaternary.opacity(0.4))
            HStack {
                if app.mcpApprovals.queuedCount > 0 {
                    Text("^[\(app.mcpApprovals.queuedCount) more request](inflect: true) waiting")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Decline") { app.mcpApprovals.decline() }
                    .keyboardShortcut(.cancelAction)
                Button("Allow for 5 min") { app.mcpApprovals.approveForAWhile() }
                    .help("Stop asking for this connection for the next 5 minutes")
                Button("Allow") { app.mcpApprovals.approve() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .tesseraModalBackground()
    }
}

extension View {
    func mcpApprovalSheet(_ app: AppModel) -> some View {
        modifier(MCPApprovalSheetModifier(app: app))
    }
}

private struct MCPApprovalSheetModifier: ViewModifier {
    @Bindable var app: AppModel

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { app.mcpApprovals.pending },
                                    set: { if $0 == nil { app.mcpApprovals.decline() } })) { request in
            MCPApprovalSheet(app: app, request: request)
        }
    }
}
