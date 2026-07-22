import SwiftUI
import AppKit

/// Export preferences: the default destination folder and the reveal-in-Finder
/// behaviour. Persistence lives in the `ExportSettings` store.
struct ExportSettingsTab: View {
    @State private var directory = ExportSettings.directory
    @State private var reveal = ExportSettings.revealAfterExport

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
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
