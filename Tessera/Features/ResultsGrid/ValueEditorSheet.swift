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
                        .help("This result can’t be edited — only a query that reads from a single table is editable.")
                }
            }
            .padding(12)

            Divider()

            if let kind = temporalKind, target.isEditable {
                // Date/time columns get a picker over the raw text — either
                // edits the same value; the text below stays the source of
                // truth and accepts anything typed or pasted.
                HStack(spacing: 10) {
                    switch kind {
                    case .date:
                        DatePicker("", selection: pickerBinding, displayedComponents: .date)
                    case .time:
                        DatePicker("", selection: pickerBinding, displayedComponents: .hourAndMinute)
                    case .dateTime:
                        DatePicker("", selection: pickerBinding,
                                   displayedComponents: [.date, .hourAndMinute])
                    }
                    Spacer()
                    Button("Now") { pickerBinding.wrappedValue = Date() }
                }
                .labelsHidden()
                .environment(\.timeZone, Self.utc)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()
            }

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

    // MARK: Date/time picking

    private enum TemporalKind { case date, time, dateTime }

    /// Which picker the column's type deserves, if any. `timestamp` must be
    /// checked before `time` — it's a prefix collision.
    private var temporalKind: TemporalKind? {
        let type = target.typeName.lowercased()
        if type.contains("timestamp") || type.contains("datetime") { return .dateTime }
        if type == "date" { return .date }
        if type.hasPrefix("time") { return .time }
        return nil
    }

    private static let utc = TimeZone(identifier: "UTC")!

    /// The picker reads whatever the text parses to and writes a canonical
    /// rendering back — raw text stays authoritative in between.
    private var pickerBinding: Binding<Date> {
        Binding(get: { parsedDate ?? Date() },
                set: { text = format($0) })
    }

    private var parsedDate: Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }
        for pattern in ["yyyy-MM-dd HH:mm:ss.SSSZZZZZ", "yyyy-MM-dd HH:mm:ssZZZZZ",
                        "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss",
                        "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
                        "HH:mm:ss.SSS", "HH:mm:ss", "HH:mm"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = Self.utc
            formatter.dateFormat = pattern
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    /// Renders in the shape the value already had — `T`/`Z` ISO stays ISO,
    /// otherwise the plain SQL form the server accepts either way.
    private func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Self.utc
        switch temporalKind {
        case .date: formatter.dateFormat = "yyyy-MM-dd"
        case .time: formatter.dateFormat = "HH:mm:ss"
        default:
            formatter.dateFormat = text.contains("T") || target.text.contains("T")
                ? "yyyy-MM-dd'T'HH:mm:ss'Z'"
                : "yyyy-MM-dd HH:mm:ss"
        }
        return formatter.string(from: date)
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
