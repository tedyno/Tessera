import SwiftUI
import AppKit
import DBKit

/// Which connection to import into.
struct ImportTarget: Identifiable {
    let id = UUID()
    let profileID: UUID
}

/// Sheet that restores a dump with psql / pg_restore / mysql.
struct ImportView: View {
    let context: ExportContext          // same connection details as export
    let service: DumpService
    var onClose: () -> Void

    @State private var fileURL: URL?
    @State private var database = ""
    @State private var stopOnError = true
    @State private var singleTransaction = true
    @State private var dropBeforeCreate = false

    @State private var binaryPath = ""
    @State private var detectedVersion: String?
    @State private var running = false
    @State private var resultSuccess: Bool?
    @State private var resultMessage = ""

    private var input: RestoreInput {
        fileURL.map { RestoreInput.detect(fileName: $0.lastPathComponent) } ?? .plainSQL
    }
    private var binaryName: String { RestoreTool.binaryName(for: context.kind, input: input) }
    private var defaultsKey: String { "tessera.restorePath.\(context.kind.rawValue).\(binaryName)" }
    private var isPostgres: Bool { context.kind == .postgres }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import into \(context.connectionName)").font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("File").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(fileURL?.lastPathComponent ?? "— choose a dump —")
                                .foregroundStyle(fileURL == nil ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.middle)
                            if fileURL != nil {
                                Text(inputDescription).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer(minLength: 8)
                        Button("Choose…") { chooseFile() }
                    }
                }
                GridRow {
                    Text("Database").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField("", text: $database).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Options").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Stop on first error", isOn: $stopOnError)
                            .disabled(!isPostgres || input == .pgCustom)
                        Toggle("Run in a single transaction", isOn: $singleTransaction)
                            .disabled(!isPostgres)
                        if isPostgres, input == .pgCustom {
                            Toggle("Drop objects before recreating", isOn: $dropBeforeCreate)
                        }
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
                            Button("Detect") { locateBinary() }
                        }
                        if binaryPath.isEmpty {
                            Text(RestoreTool.installHint(for: context.kind))
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled).foregroundStyle(.secondary)
                        } else if let detectedVersion {
                            Text(detectedVersion).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }

            Label("Importing writes into the target database and can overwrite data.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)

            if let success = resultSuccess {
                Label(resultMessage.isEmpty ? (success ? "Imported" : "Failed") : resultMessage,
                      systemImage: success ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(success ? .green : .red)
                    .font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                if running { ProgressView().controlSize(.small); Text("Importing…").foregroundStyle(.secondary) }
                Spacer()
                Button("Close") { onClose() }
                Button("Import") { runImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRun)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            if database.isEmpty { database = context.database }
            locateBinary()
        }
    }

    private var inputDescription: String {
        switch input {
        case .plainSQL: "Plain SQL — restored with \(binaryName)"
        case .gzippedSQL: "Gzipped SQL — decompressed on the fly"
        case .pgCustom: "pg_dump custom format — restored with pg_restore"
        }
    }

    private var canRun: Bool { fileURL != nil && !binaryPath.isEmpty && !database.isEmpty && !running }

    // MARK: Actions

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = ExportSettings.directory
        if panel.runModal() == .OK, let url = panel.url {
            fileURL = url
            locateBinary()   // the needed tool depends on the file's format
        }
    }

    private func locateBinary() {
        let override = UserDefaults.standard.string(forKey: defaultsKey)
        let serverMajor = context.serverVersion.flatMap(DumpTool.majorVersion)
        Task { @MainActor in
            binaryPath = await service.locateBest(
                named: binaryName, engine: context.kind, serverMajor: serverMajor, override: override) ?? ""
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
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            binaryPath = url.path
            persistOverride()
        }
    }

    private func runImport() {
        guard let fileURL else { return }
        running = true
        resultSuccess = nil
        let options = RestoreOptions(stopOnError: stopOnError,
                                     singleTransaction: singleTransaction && isPostgres,
                                     dropBeforeCreate: dropBeforeCreate)
        let targetDatabase = database
        let detected = input
        Task {
            let result = await service.restore(
                engine: context.kind, binaryPath: binaryPath,
                host: context.host, port: context.port, user: context.user,
                database: targetDatabase, password: context.password,
                input: detected, fileURL: fileURL, options: options)
            running = false
            resultSuccess = result.success
            resultMessage = result.success
                ? "Imported \(fileURL.lastPathComponent)"
                : result.message
        }
    }
}
