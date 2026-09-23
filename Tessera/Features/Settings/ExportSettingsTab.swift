import SwiftUI
import AppKit

/// Export preferences: the default destination folder and the reveal-in-Finder
/// behaviour. Persistence lives in the `ExportSettings` store.
struct ExportSettingsTab: View {
    let connections: ConnectionsModel
    @State private var directory = ExportSettings.directory
    @State private var reveal = ExportSettings.revealAfterExport
    @State private var transfer: ConnectionTransfer?

    var body: some View {
        Form {
            Section("Export") {
                LabeledContent("Default folder") {
                    HStack(spacing: 8) {
                        Text(directory.path)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…") { chooseFolder() }
                        Button("Downloads") { reset() }
                    }
                }
                Toggle("Reveal the file in Finder after export", isOn: $reveal)
                    .onChange(of: reveal) { _, newValue in ExportSettings.revealAfterExport = newValue }
            }
            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        Button("Export…") { transfer = .export }
                            .disabled(connections.profiles.isEmpty)
                        Button("Import…") { transfer = ConnectionTransfer.pickImportFile() }
                    }
                } label: {
                    Text("All connections")
                    Text("Copies connections, folders and passwords to another Tessera as an encrypted .tessera file. Importing only adds; nothing here is overwritten.")
                }
            } header: {
                Text("Connections")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(item: $transfer) { item in
            ConnectionTransferSheet(transfer: item, connections: connections) { transfer = nil }
                .tesseraModalBackground()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        if panel.runModal() == .OK, let url = panel.url {
            ExportSettings.setDirectory(url)
            directory = url
        }
    }

    private func reset() {
        ExportSettings.resetDirectory()
        directory = ExportSettings.directory
    }
}
