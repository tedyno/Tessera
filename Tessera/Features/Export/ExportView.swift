import SwiftUI
import AppKit
import DBKit
import UniformTypeIdentifiers

/// What the user asked to export. Empty lists mean the whole database.
struct ExportTarget: Identifiable {
    let id = UUID()
    let profileID: UUID
    var schemas: [String] = []
    var tables: [String] = []
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
    /// The live server version string (e.g. "16.2"), used to pick a matching binary.
    let serverVersion: String?
    var schemas: [String]
    var tables: [String]
}

/// Sheet that configures and runs pg_dump / mysqldump.
struct ExportView: View {
    let context: ExportContext
    let service: DumpService
    var onClose: () -> Void

    @State private var database = ""
    @State private var schemasText = ""
    @State private var tablesText = ""
    @State private var includeStructure = true
    @State private var includeData = true
    @State private var dropBeforeCreate = false
    @State private var dropIfExists = false
    @State private var createDatabase = false
    @State private var useInsertStatements = false
    @State private var format: DumpOptions.Format = .plain
    @State private var gzip = false

    @State private var binaryPath = ""
    @State private var detectedVersion: String?
    @State private var outputURL: URL?
    @State private var running = false
    @State private var resultSuccess: Bool?
    @State private var resultMessage = ""

    private var binaryName: String { DumpTool.binaryName(for: context.kind) }
    private var defaultsKey: String { "tessera.dumpPath.\(context.kind.rawValue)" }
    private var isPostgres: Bool { context.kind == .postgres }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export \(context.connectionName)").font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Database").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField("", text: $database).textFieldStyle(.roundedBorder)
                }
                if isPostgres {
                    GridRow {
                        Text("Schemas").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                        TextField("all schemas (comma-separated)", text: $schemasText)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                GridRow {
                    Text("Tables").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField("all tables (comma-separated)", text: $tablesText)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Include").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        Toggle("Structure", isOn: $includeStructure)
                        Toggle("Data", isOn: $includeData)
                    }
                }
                GridRow {
                    Text("Options").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Add DROP before CREATE", isOn: $dropBeforeCreate)
                        if isPostgres {
                            Toggle("Use DROP … IF EXISTS", isOn: $dropIfExists)
                                .disabled(!dropBeforeCreate)
                                .padding(.leading, 16)
                        }
                        Toggle("Add CREATE DATABASE", isOn: $createDatabase)
                        Toggle("Use INSERT statements (portable)", isOn: $useInsertStatements)
                    }
                }
                GridRow {
                    Text("Format").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        if isPostgres {
                            Picker("", selection: $format) {
                                Text("Plain SQL").tag(DumpOptions.Format.plain)
                                Text("Custom (pg_restore)").tag(DumpOptions.Format.custom)
                            }
                            .labelsHidden()
                            .fixedSize()
                            .onChange(of: format) { _, _ in
                                if format == .custom { gzip = false }
                                applyExtension()
                            }
                        }
                        Toggle("Compress (gzip)", isOn: $gzip)
                            .disabled(format == .custom)
                            .onChange(of: gzip) { _, _ in applyExtension() }
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
                                .onSubmit { persistOverride() }
                            Button("Browse…") { browseBinary() }
                            Button("Detect") { setup() }
                        }
                        binaryStatus
                    }
                }
                GridRow {
                    Text("Output").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(outputURL?.lastPathComponent ?? "— choose a file —")
                                .foregroundStyle(outputURL == nil ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.middle)
                            if let folder = outputURL?.deletingLastPathComponent().path {
                                Text(folder).font(.caption2).foregroundStyle(.tertiary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 8)
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
        .frame(width: 560)
        .onAppear(perform: initialSetup)
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
        } else {
            VStack(alignment: .leading, spacing: 2) {
                if let detectedVersion {
                    Text(detectedVersion).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if versionMismatch {
                    Label("This client is older than the server (\(context.serverVersion ?? "?")) — "
                          + "the dump may be refused. Install a matching \(binaryName).",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    private var canRun: Bool {
        !binaryPath.isEmpty && outputURL != nil && (includeStructure || includeData)
            && !database.isEmpty && !running
    }

    private var versionMismatch: Bool {
        guard let serverMajor = context.serverVersion.flatMap(DumpTool.majorVersion),
              let clientMajor = detectedVersion.flatMap(DumpTool.majorVersion) else { return false }
        return clientMajor < serverMajor
    }

    // MARK: Setup

    private func initialSetup() {
        if database.isEmpty { database = context.database }
        if schemasText.isEmpty { schemasText = context.schemas.joined(separator: ", ") }
        if tablesText.isEmpty { tablesText = context.tables.joined(separator: ", ") }
        if outputURL == nil { outputURL = defaultOutputURL }
        setup()
    }

    /// Searches fresh for the binary, preferring a still-valid manual override and
    /// otherwise the installed version that best matches this server.
    private func setup() {
        let override = UserDefaults.standard.string(forKey: defaultsKey)
        let serverMajor = context.serverVersion.flatMap(DumpTool.majorVersion)
        Task { @MainActor in
            binaryPath = await service.locateBest(
                kind: context.kind, serverMajor: serverMajor, override: override) ?? ""
            refreshVersion()
        }
    }

    private func refreshVersion() {
        guard !binaryPath.isEmpty else { detectedVersion = nil; return }
        let path = binaryPath
        Task { detectedVersion = await service.version(binaryPath: path) }
    }

    private func persistOverride() {
        UserDefaults.standard.set(binaryPath, forKey: defaultsKey)
        refreshVersion()
    }

    private func browseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            binaryPath = url.path
            persistOverride()
        }
    }

    // MARK: Output

    private func chooseOutput() {
        let panel = NSSavePanel()
        panel.directoryURL = outputURL?.deletingLastPathComponent() ?? ExportSettings.directory
        panel.nameFieldStringValue = outputURL?.lastPathComponent ?? defaultFileName
        if panel.runModal() == .OK { outputURL = panel.url }
    }

    private var defaultOutputURL: URL {
        ExportSettings.directory.appendingPathComponent(defaultFileName)
    }

    private var defaultFileName: String {
        let base: String
        if let table = splitList(tablesText).first { base = table }
        else if let schema = splitList(schemasText).first { base = schema }
        else { base = database.isEmpty ? context.database : database }
        return ExportSettings.fileName(base: base, extension: fileExtension)
    }

    private var fileExtension: String {
        if format == .custom { return "dump" }
        return gzip ? "sql.gz" : "sql"
    }

    /// Keeps the output file's extension in step with the format/gzip choice.
    private func applyExtension() {
        guard let outputURL else { return }
        var name = outputURL.lastPathComponent
        for suffix in [".sql.gz", ".sql", ".dump"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        self.outputURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("\(name).\(fileExtension)")
    }

    // MARK: Run

    private func splitList(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func runExport() {
        guard let outputURL else { return }
        running = true
        resultSuccess = nil
        let options = DumpOptions(
            schemas: isPostgres ? splitList(schemasText) : [],
            tables: splitList(tablesText),
            includeStructure: includeStructure, includeData: includeData,
            dropBeforeCreate: dropBeforeCreate,
            dropIfExists: isPostgres && dropIfExists,
            createDatabase: createDatabase,
            useInsertStatements: useInsertStatements,
            format: isPostgres ? format : .plain,
            gzip: gzip)
        let targetDatabase = database
        Task {
            let result = await service.dump(
                kind: context.kind, binaryPath: binaryPath,
                host: context.host, port: context.port, user: context.user,
                database: targetDatabase, password: context.password,
                options: options, outputURL: outputURL)
            running = false
            resultSuccess = result.success
            resultMessage = result.success ? "Saved to \(outputURL.path)" : result.message
            if result.success, ExportSettings.revealAfterExport {
                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
            }
        }
    }
}
