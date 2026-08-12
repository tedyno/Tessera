import SwiftUI
import AppKit
import DBKit

/// A result that is one JSON value (a key-value GET on a JSON-valued key) shown
/// as the document itself rather than a one-row grid. Formatting only re-indents
/// for reading, so the view can always switch back to the bytes the server
/// actually returned — nobody should have to guess whether the pretty layout is
/// what's stored.
struct JSONValueView: View {
    let column: ColumnDescriptor
    /// Exactly what the server returned.
    let raw: String
    /// The same value re-indented; equal to `raw` when it was stored formatted.
    let formatted: String

    /// Sticky across values and tabs — someone who works with raw payloads keeps
    /// getting raw ones.
    @AppStorage("tessera.jsonValueRaw") private var showRaw = false

    private var text: String { showRaw ? raw : formatted }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(verbatim: column.name).font(.caption.bold())
                if !column.typeName.isEmpty {
                    Text(verbatim: column.typeName).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                // A value stored formatted renders identically either way — no
                // switch, because there is nothing to switch between.
                if raw != formatted {
                    Picker(String(""), selection: $showRaw) {
                        Text("Formatted").tag(false)
                        Text("Raw").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .help("Show the value formatted or exactly as it is stored")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy value")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            ValueTextEditor(text: .constant(text), isEditable: false)
                .padding(4)
        }
    }
}
