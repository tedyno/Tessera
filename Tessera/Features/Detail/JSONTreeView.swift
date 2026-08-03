import SwiftUI
import DBKit

// `JSONTreeNode` (the model + parser) now lives in TesseraCore (DBKit) so the
// parsing rules are unit-testable; this file keeps the SwiftUI rendering.

/// Inspector value display: a collapsible JSON tree when the value parses as
/// one, the plain (pretty-printed) text otherwise. Owns the parse cache — the
/// tree is rebuilt only when the value changes, so expansion state survives
/// unrelated re-renders and a 256 KB value isn't re-parsed per keystroke.
struct JSONInspectorView: View {
    let value: String
    /// Fallback text when the value isn't tree-worthy (pre-formatted upstream).
    let fallback: String

    @State private var parsedSource: String?
    @State private var parsedNode: JSONTreeNode?

    var body: some View {
        Group {
            if parsedSource == value, let node = parsedNode {
                JSONTreeView(node: node)
            } else if parsedSource == value {
                Text(fallback).font(.callout.monospaced())
            } else {
                // First render for this value: parse next tick, show text meanwhile.
                Text(fallback).font(.callout.monospaced())
            }
        }
        .onChange(of: value, initial: true) { _, newValue in
            parsedNode = JSONTreeNode.parse(newValue)
            parsedSource = newValue
        }
    }
}

/// Collapsible key/value rendering of a JSON cell value in the inspector.
/// The root level is always laid out; nested containers start collapsed.
struct JSONTreeView: View {
    let node: JSONTreeNode

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            JSONNodeLabel(node: node)
            ForEach(node.children) { child in
                JSONTreeRow(node: child)
            }
            .padding(.leading, 12)
        }
    }
}

private struct JSONTreeRow: View {
    let node: JSONTreeNode
    @State private var expanded = false

    var body: some View {
        if node.isContainer {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(node.children) { child in
                    JSONTreeRow(node: child)
                }
            } label: {
                JSONNodeLabel(node: node)
            }
        } else {
            JSONNodeLabel(node: node)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One node's key + value, colored by JSON type.
private struct JSONNodeLabel: View {
    let node: JSONTreeNode

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let key = node.key {
                Text(verbatim: node.isContainer ? key : key + ":")
                    .font(.caption.monospaced().bold())
            }
            switch node.value {
            case .object(let count):
                Text("{…} ^[\(count) key](inflect: true)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            case .array(let count):
                Text("[…] ^[\(count) item](inflect: true)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            case .string(let string):
                Text(verbatim: "\"\(string)\"")
                    .font(.caption.monospaced()).foregroundStyle(.red)
            case .number(let number):
                Text(verbatim: number)
                    .font(.caption.monospaced()).foregroundStyle(.blue)
            case .bool(let flag):
                Text(verbatim: flag ? "true" : "false")
                    .font(.caption.monospaced()).foregroundStyle(.purple)
            case .null:
                Text(verbatim: "null")
                    .font(.caption.monospaced().italic()).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }
}
