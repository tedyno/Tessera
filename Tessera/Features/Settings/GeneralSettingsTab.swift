import SwiftUI

/// General preferences: interface language and the query row cap.
struct GeneralSettingsTab: View {
    @State private var language = AppLanguage.current
    @State private var languageChanged = false
    @State private var maxRows = ExportSettings.maxRows

    var body: some View {
        Form {
            Section("Language") {
                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .onChange(of: language) { _, newValue in
                    AppLanguage.apply(newValue)
                    languageChanged = true
                }
                if languageChanged {
                    HStack {
                        Text("Restart the app to apply the language.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Relaunch") { AppLanguage.relaunch() }
                    }
                }
            }
            Section {
                LabeledContent("Default row limit") {
                    HStack {
                        TextField("", value: $maxRows, format: .number)
                            .frame(width: 90)
                            .onSubmit { ExportSettings.maxRows = max(0, maxRows) }
                        Text("0 = unlimited").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Results")
            } footer: {
                Text("Caps console query results and is the starting Limit for a table view — table views then load more as you scroll. 0 removes the console cap.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
