import Foundation

/// Parsed JSON as a displayable tree — built once per inspected value, capped so a
/// megabyte of JSON can't stall the inspector. Pure model + parser (no SwiftUI), so
/// the parsing rules are unit-testable.
public struct JSONTreeNode: Identifiable {
    public enum Value: Equatable {
        case string(String)
        case number(String)
        case bool(Bool)
        case null
        case object(count: Int)
        case array(count: Int)
    }

    public let id = UUID()
    /// Key in the parent object, or "[index]" in an array; nil at the root.
    public var key: String?
    public var value: Value
    public var children: [JSONTreeNode] = []

    public init(key: String?, value: Value, children: [JSONTreeNode] = []) {
        self.key = key
        self.value = value
        self.children = children
    }

    public var isContainer: Bool {
        if case .object = value { return true }
        if case .array = value { return true }
        return false
    }

    /// Parses only real containers (a bare string/number isn't worth a tree), and
    /// gives up beyond ~256 KB or a few thousand nodes — the plain text rendering
    /// handles those better than a tree ever would. Returns nil for non-JSON, a
    /// scalar, or an over-budget document.
    public static func parse(_ text: String) -> JSONTreeNode? {
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
