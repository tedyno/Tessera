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
    /// The text is a complete JSON object/array — enables the format toggle.
    @State private var isFormattableJSON: Bool
    /// The stored value was single-line JSON: it opens pretty-printed for
    /// editing and Save minifies it back to match the stored format. A value
    /// stored formatted keeps the user's own formatting untouched.
    private let wasInline: Bool

    init(target: ValueEditorTarget, onSave: @escaping (String?) -> Void) {
        self.target = target
        self.onSave = onSave
        _isNull = State(initialValue: target.isNull)
        // Formatting must happen here, not in onAppear — a later write to `text`
        // would trip the onChange that clears `isNull`.
        if !target.isNull, JSONText.isInline(target.text),
           let pretty = JSONText.prettyPrinted(target.text) {
            wasInline = true
            _text = State(initialValue: pretty)
            _isFormattableJSON = State(initialValue: true)
        } else {
            wasInline = false
            _text = State(initialValue: target.text)
            let scanned = target.isNull ? nil : JSONText.scan(target.text)
            _isFormattableJSON = State(initialValue: scanned.map { $0.isValid && $0.isContainer } ?? false)
        }
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

            ValueTextEditor(text: $text, isEditable: target.isEditable)
                .padding(6)
                .onChange(of: text) { _, _ in
                    isNull = false
                    isFormattableJSON = JSONText.scan(text)
                        .map { $0.isValid && $0.isContainer } ?? false
                }

            Divider()

            HStack {
                // One toggle, labeled by what it would do to the current text.
                if JSONText.isInline(text) {
                    Button("Pretty-print JSON") {
                        if let pretty = JSONText.prettyPrinted(text) { text = pretty }
                    }
                    .disabled(!isFormattableJSON)
                } else {
                    Button("Minify JSON") {
                        if let minified = JSONText.minified(text) { text = minified }
                    }
                    .disabled(!isFormattableJSON)
                }
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
                        onSave(isNull ? nil : savedText)
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

    /// What Save writes: a value stored as inline JSON goes back minified (the
    /// pretty-printing was only for editing); anything else is saved exactly as
    /// displayed. An untouched value returns the byte-identical original, so the
    /// caller's "did it change" guard still discards no-op saves.
    private var savedText: String {
        guard wasInline else { return text }
        if JSONText.haveSameTokens(text, target.text) { return target.text }
        // Invalid JSON after an edit: save as typed — the server reports the
        // error the same way it does today, nothing is silently dropped.
        return JSONText.minified(text) ?? text
    }
}
