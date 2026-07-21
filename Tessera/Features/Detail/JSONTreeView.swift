import SwiftUI

/// Parsed JSON as a displayable tree — built once per inspected value, capped
/// so a megabyte of JSON can't stall the inspector.
struct JSONTreeNode: Identifiable {
    enum Value {
        case string(String)
        case number(String)
        case bool(Bool)
        case null
        case object(count: Int)
        case array(count: Int)
    }

    let id = UUID()
    /// Key in the parent object, or "[index]" in an array; nil at the root.
    var key: String?
    var value: Value
    var children: [JSONTreeNode] = []

    var isContainer: Bool {
        if case .object = value { return true }
        if case .array = value { return true }
        return false
    }

    /// Parses only real containers (a bare string/number isn't worth a tree),
    /// and gives up beyond ~256 KB or a few thousand nodes — the plain text
    /// rendering handles those better than a tree ever would.
    static func parse(_ text: String) -> JSONTreeNode? {
        guard text.count <= 256_000,
              let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first,
              first == "{" || first == "[",
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var budget = 4000
        return build(object, key: nil, budget: &budget)
    }

    private static func build(_ any: Any, key: String?, budget: inout Int) -> JSONTreeNode? {
        guard budget > 0 else { return nil }
        budget -= 1
        switch any {
        case let dictionary as [String: Any]:
            var node = JSONTreeNode(key: key, value: .object(count: dictionary.count))
            for name in dictionary.keys.sorted() {
                if let child = build(dictionary[name]!, key: name, budget: &budget) {
                    node.children.append(child)
                }
            }
            return node
        case let array as [Any]:
            var node = JSONTreeNode(key: key, value: .array(count: array.count))
            for (index, element) in array.enumerated() {
                if let child = build(element, key: "[\(index)]", budget: &budget) {
                    node.children.append(child)
                }
            }
            return node
        case let number as NSNumber:
            // NSNumber wraps booleans too; CFBoolean is the reliable tell.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return JSONTreeNode(key: key, value: .bool(number.boolValue))
            }
            return JSONTreeNode(key: key, value: .number(number.stringValue))
        case let string as String:
            return JSONTreeNode(key: key, value: .string(string))
        case is NSNull:
            return JSONTreeNode(key: key, value: .null)
        default:
            return nil
        }
    }
}

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
