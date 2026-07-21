import SwiftUI
import DBKit

/// Multiline editor for one cell value — the in-cell field is single-line, which
/// makes JSON and other multiline text unwieldy. Opened from the grid via ⇧↩,
/// the context menu, or by double-clicking a value that contains newlines.
struct ValueEditorSheet: View {
    let target: ValueEditorTarget
    /// Applies the edited value (nil = SQL NULL) through the tab's edit pipeline.
    let onSave: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var isNull: Bool

    init(target: ValueEditorTarget, onSave: @escaping (String?) -> Void) {
        self.target = target
        self.onSave = onSave
        _text = State(initialValue: target.text)
        _isNull = State(initialValue: target.isNull)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(verbatim: target.columnName)
                    .font(.headline)
                if !target.typeName.isEmpty {
                    Text(verbatim: target.typeName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isNull {
                    // On an insert row an unset column means "database default",
                    // not NULL — the commit omits the column entirely.
                    Text(verbatim: target.isInsertRow ? "DEFAULT" : "NULL")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.18), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !target.isEditable {
                    Text("Read-only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)

            Divider()

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .disabled(!target.isEditable)
                .scrollContentBackground(.hidden)
                .padding(6)
                .onChange(of: text) { _, _ in isNull = false }

            Divider()

            HStack {
                Button("Pretty-print JSON") { prettyPrint() }
                    .disabled(prettyPrinted() == nil)
                if target.isEditable {
                    // Insert rows can't express NULL — removing the value falls
                    // back to the column default, so the button says what it does.
                    Button(target.isInsertRow ? "Use Default" : "Set NULL") {
                        onSave(nil)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if target.isEditable {
                    Button("Save") {
                        // An untouched NULL saves as NULL, not as "".
                        onSave(isNull ? nil : text)
                        dismiss()
                    }
                    // ⌘↩, not plain Return — Return types a newline in the editor.
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 520, idealWidth: 640, maxWidth: .infinity,
               minHeight: 340, idealHeight: 440, maxHeight: .infinity)
    }

    /// The text re-serialized with indentation, or nil when it isn't JSON.
    private func prettyPrinted() -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              object is [Any] || object is [String: Any],
              let pretty = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes]),
              let string = String(data: pretty, encoding: .utf8) else { return nil }
        return string
    }

    private func prettyPrint() {
        if let pretty = prettyPrinted() { text = pretty }
    }
}
