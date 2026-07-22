import SwiftUI

/// PhpStorm-style local filter for one column: the distinct fetched values
/// with their counts; checking values keeps only their rows. Everything is
/// client-side and applies live.
struct ColumnFilterView: View {
    let columnName: String
    let values: [(value: String?, count: Int)]
    let initialSelection: Set<String?>
    var onChange: (Set<String?>) -> Void

    @State private var selected: Set<String?> = []
    @State private var search = ""

    private var visibleValues: [(value: String?, count: Int)] {
        guard !search.isEmpty else { return values }
        return values.filter { ($0.value ?? "NULL").localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local filter for “\(columnName)”")
                .font(.headline)
                .lineLimit(1)
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(visibleValues.enumerated()), id: \.offset) { _, entry in
                        HStack {
                            Toggle(isOn: binding(entry.value)) {
                                if let value = entry.value {
                                    Text(verbatim: value).lineLimit(1)
                                } else {
                                    Text(verbatim: "NULL").italic().foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            Spacer()
                            Text(verbatim: "\(entry.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Clear Filter") {
                    selected = []
                    onChange([])
                }
                .disabled(selected.isEmpty)
                Spacer()
                Text("Checked values keep their rows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 300, height: 400)
        .onAppear { selected = initialSelection }
    }

    private func binding(_ value: String?) -> Binding<Bool> {
        Binding(get: { selected.contains(value) },
                set: { on in
                    if on { selected.insert(value) } else { selected.remove(value) }
                    onChange(selected)
                })
    }
}
