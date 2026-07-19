import SwiftUI
import AppKit
import DBKit
import UniformTypeIdentifiers

/// What the user asked to export.
struct ExportTarget: Identifiable {
    let id = UUID()
    let profileID: UUID
    var scope: DumpOptions.Scope
}

/// Connection details resolved for the dump, from the live session when available.
struct ExportContext {
    let kind: DatabaseKind
    let connectionName: String
    let host: String
    let port: Int
    let user: String
    let database: String
    let password: String?
    var scope: DumpOptions.Scope
}

/// Sheet that configures and runs pg_dump / mysqldump. The binary path is auto-
/// detected but can be set by hand; if missing, it shows the Homebrew install hint.
struct ExportView: View {
    let context: ExportContext
    let service: DumpService
    var onClose: () -> Void

    @State private var binaryPath = ""
    @State private var detectedVersion: String?
    @State private var includeStructure = true
    @State private var includeData = true
    @State private var outputURL: URL?
    @State private var running = false
    @State private var resultSuccess: Bool?
    @State private var resultMessage = ""

    private var binaryName: String { DumpTool.binaryName(for: context.kind) }
    private var defaultsKey: String { "tessera.dumpPath.\(context.kind.rawValue)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export \(context.connectionName)").font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Scope").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    Text(scopeDescription)
                }
                GridRow {
                    Text("Include").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        Toggle("Structure", isOn: $includeStructure)
                        Toggle("Data", isOn: $includeData)
                    }
                }
                GridRow {
                    Text(binaryName).gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("Path to \(binaryName)", text: $binaryPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                                .onChange(of: binaryPath) { _, _ in refreshVersion() }
                            Button("Browse…") { browseBinary() }
                        }
                        binaryStatus
                    }
                }
                GridRow {
                    Text("Output").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    HStack {
                        Text(outputURL?.lastPathComponent ?? "— choose a file —")
                            .foregroundStyle(outputURL == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseOutput() }
                    }
                }
            }

            if let success = resultSuccess {
                Label(resultMessage.isEmpty ? (success ? "Done" : "Failed") : resultMessage,
                      systemImage: success ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(success ? .green : .red)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                if running { ProgressView().controlSize(.small); Text("Exporting…").foregroundStyle(.secondary) }
                Spacer()
                Button("Close") { onClose() }
                Button("Export") { runExport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRun)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: setup)
    }

    // MARK: Pieces

    @ViewBuilder private var binaryStatus: some View {
        if binaryPath.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(binaryName) not found. Install it, then set the path:")
                    .font(.caption).foregroundStyle(.orange)
                Text(DumpTool.installHint(for: context.kind))
                    .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
        } else if let detectedVersion {
            Text(detectedVersion).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var scopeDescription: String {
        switch context.scope {
        case .database: "Whole database “\(context.database)”"
        case .schema(let schema): "Schema “\(schema)”"
        case .tables(let schema, let tables): "\(tables.count) table(s) in “\(schema)”: \(tables.joined(separator: ", "))"
        }
    }

    private var canRun: Bool {
        !binaryPath.isEmpty && outputURL != nil && (includeStructure || includeData) && !running
    }

    // MARK: Actions

    private func setup() {
        let saved = UserDefaults.standard.string(forKey: defaultsKey)
        binaryPath = service.locate(kind: context.kind, override: saved) ?? ""
        refreshVersion()
    }

    private func refreshVersion() {
        UserDefaults.standard.set(binaryPath, forKey: defaultsKey)
        guard !binaryPath.isEmpty else { detectedVersion = nil; return }
        let path = binaryPath
        Task { detectedVersion = await service.version(binaryPath: path) }
    }

    private func browseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { binaryPath = url.path }
    }

    private func chooseOutput() {
        let panel = NSSavePanel()
        if let sql = UTType(filenameExtension: "sql") { panel.allowedContentTypes = [sql] }
        panel.nameFieldStringValue = defaultFileName
        if panel.runModal() == .OK { outputURL = panel.url }
    }

    private var defaultFileName: String {
        let base: String
        switch context.scope {
        case .database, .schema: base = context.database
        case .tables(_, let tables): base = tables.first ?? context.database
        }
        return "\(base).sql"
    }

    private func runExport() {
        guard let outputURL else { return }
        running = true
        resultSuccess = nil
        let options = DumpOptions(scope: context.scope,
                                  includeStructure: includeStructure, includeData: includeData)
        Task {
            let result = await service.dump(
                kind: context.kind, binaryPath: binaryPath,
                host: context.host, port: context.port, user: context.user,
                database: context.database, password: context.password,
                options: options, outputURL: outputURL)
            running = false
            resultSuccess = result.success
            resultMessage = result.success
                ? "Saved to \(outputURL.path)"
                : result.message
        }
    }
}
