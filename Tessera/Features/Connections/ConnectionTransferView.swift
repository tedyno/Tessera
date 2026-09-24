import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DBKit
import DBPersistence

extension UTType {
    /// An encrypted `.tessera` connections file (declared in Info.plist).
    static let tesseraConnections = UTType(exportedAs: "io.github.tedyno.tessera.connections",
                                           conformingTo: .data)
}

/// Moving connections between Tessera installs: which sheet is up.
enum ConnectionTransfer: Identifiable {
    case export
    case importFile(URL)

    var id: String {
        switch self {
        case .export: "export"
        case .importFile(let url): "import:\(url.path)"
        }
    }

    /// Asks for a `.tessera` file to import; nil when cancelled.
    @MainActor static func pickImportFile() -> ConnectionTransfer? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.tesseraConnections]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return .importFile(url)
    }
}

/// The sheet for either direction.
struct ConnectionTransferSheet: View {
    let transfer: ConnectionTransfer
    let connections: ConnectionsModel
    var onClose: () -> Void

    var body: some View {
        switch transfer {
        case .export: ExportConnectionsView(connections: connections, onClose: onClose)
        case .importFile(let url): ImportConnectionsView(url: url, connections: connections, onClose: onClose)
        }
    }
}

// MARK: - Export

/// Writes every connection, passwords included, to an encrypted `.tessera` file and
/// shows the generated password once, to be copied.
struct ExportConnectionsView: View {
    let connections: ConnectionsModel
    var onClose: () -> Void

    @State private var working = false
    @State private var error: String?
    @State private var result: (url: URL, password: String)?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Connections").font(.headline)

            if let result {
                done(result)
            } else {
                Text("All \(connections.profiles.count) connections, with their folders and passwords, are written to an encrypted .tessera file. Open it in Tessera on another Mac to add them there.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Tessera generates the file's password. You'll see it once, after saving.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if working { ProgressView().controlSize(.small); Text("Encrypting…").foregroundStyle(.secondary) }
                Spacer()
                if result == nil {
                    Button("Cancel") { onClose() }
                    Button("Export…") { export() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || connections.profiles.isEmpty)
                } else {
                    Button("Done") { onClose() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder
    private func done(_ result: (url: URL, password: String)) -> some View {
        Label("Saved \(result.url.lastPathComponent)", systemImage: "checkmark.circle")
            .foregroundStyle(.green)
        VStack(alignment: .leading, spacing: 8) {
            Text("Password").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(verbatim: result.password)
                    .font(.system(.title3, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                Button {
                    Self.copy(result.password)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy Password",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .animation(.snappy(duration: 0.2), value: copied)
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        Label("Tessera doesn't keep this password. Without it the file can't be opened — store it now.",
              systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
    }

    private func export() {
        error = nil
        let bundle: ConnectionBundle
        do {
            bundle = try connections.makeBundle()
        } catch {
            self.error = String(localized: "Tessera couldn't read the passwords from the Keychain, so nothing was exported.")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.tesseraConnections]
        panel.directoryURL = ExportSettings.directory
        // Not localized: the file travels between Macs whose languages may differ.
        panel.nameFieldStringValue = ExportSettings.fileName(
            base: "credentials", extension: ConnectionBundleFile.fileExtension)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let password = ExportPassword.generate()
        working = true
        Task {
            // The key derivation is deliberately slow; keep it off the main thread.
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try ConnectionBundleFile.write(bundle, password: password, to: url) }
            }.value
            working = false
            switch outcome {
            case .success: result = (url, password)
            case .failure(let failure):
                error = String(localized: "The file couldn't be written: \(failure.localizedDescription)")
            }
        }
    }

    /// Copies the password marked as concealed, so clipboard managers that honour
    /// the convention don't keep it in their history.
    private static func copy(_ password: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(password, forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }
}

// MARK: - Import

/// Opens a `.tessera` file with its password, shows what would be added, and adds
/// it. Nothing already configured is changed.
struct ImportConnectionsView: View {
    let url: URL
    let connections: ConnectionsModel
    var onClose: () -> Void

    @State private var password = ""
    @State private var working = false
    @State private var error: String?
    @State private var bundle: ConnectionBundle?
    @State private var imported: ConnectionImportPlan?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Connections").font(.headline)
            Label(url.lastPathComponent, systemImage: "doc.badge.gearshape")
                .foregroundStyle(.secondary)

            if let imported {
                summary(imported, done: true)
            } else if let bundle {
                summary(connections.importPlan(for: bundle), done: false)
            } else {
                Text("Enter the password shown when the file was exported.")
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { unlock() }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if working { ProgressView().controlSize(.small); Text("Decrypting…").foregroundStyle(.secondary) }
                Spacer()
                if imported != nil {
                    Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
                } else if let bundle {
                    Button("Cancel") { onClose() }
                    Button("Import") { apply(bundle) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(connections.importPlan(for: bundle).added.isEmpty)
                } else {
                    Button("Cancel") { onClose() }
                    Button("Open") { unlock() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || password.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    @ViewBuilder
    private func summary(_ plan: ConnectionImportPlan, done: Bool) -> some View {
        let added = plan.added.count
        if added == 0 {
            Label("Every connection in this file is already here. Nothing to import.",
                  systemImage: "checkmark.circle")
        } else if done {
            Label("Added \(added) connections.", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        } else {
            Text("\(added) connections will be added, with their folders and passwords.")
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(plan.added, id: \.profile.id) { entry in
                        Text(verbatim: entry.profile.name)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .font(.callout)
        }
        if !plan.skipped.isEmpty {
            Text("\(plan.skipped.count) already exist here and are skipped.")
                .font(.callout).foregroundStyle(.secondary)
        }
        if !done, added > 0 {
            Text("Your existing connections and folders are left as they are.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func unlock() {
        guard !working else { return }
        error = nil
        working = true
        let url = url, password = password
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try ConnectionBundleFile.open(Data(contentsOf: url), password: password) }
            }.value
            working = false
            switch outcome {
            case .success(let opened): bundle = opened
            case .failure(let failure): error = Self.message(for: failure)
            }
        }
    }

    private func apply(_ bundle: ConnectionBundle) {
        do {
            imported = try connections.importBundle(bundle)
        } catch {
            self.error = String(localized: "The passwords couldn't be saved to the Keychain, so nothing was imported.")
        }
    }

    private static func message(for error: Error) -> String {
        switch error as? ConnectionBundleError {
        case .wrongPassword: String(localized: "Wrong password.")
        case .notABundle: String(localized: "This isn't a Tessera connections file.")
        case .unsupportedVersion: String(localized: "This file was exported by a newer Tessera. Update Tessera to import it.")
        case .damaged: String(localized: "The file is damaged.")
        case nil: String(localized: "The file couldn't be read: \(error.localizedDescription)")
        }
    }
}
