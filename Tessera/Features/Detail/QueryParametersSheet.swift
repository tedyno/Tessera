import SwiftUI

/// Asks for the values of a query's `:name` placeholders before it runs.
/// Values are remembered across runs, so re-running with tweaks is one Enter.
struct QueryParametersSheet: View {
    let names: [String]
    let initial: [String: String]
    var onRun: ([String: String]) -> Void
    var onCancel: () -> Void

    @State private var values: [String: String] = [:]
    @FocusState private var focused: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Query Parameters", systemImage: "curlybraces")
                .font(.headline)
            Form {
                ForEach(names, id: \.self) { name in
                    TextField(name, text: binding(name))
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .focused($focused, equals: name)
                }
            }
            .formStyle(.columns)
            Text("Empty values run as NULL; numbers stay unquoted.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Run") { onRun(values) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            values = names.reduce(into: [:]) { $0[$1] = initial[$1] ?? "" }
            focused = names.first
        }
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
    }
}
