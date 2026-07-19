import Foundation

/// Any JSON value — needed because MCP carries free-form tool schemas and
/// arguments that don't map to fixed Swift types.
public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Emit whole numbers without a decimal point.
            if value == value.rounded(), abs(value) < 9e15 { try container.encode(Int(value)) }
            else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // Convenience accessors for reading tool arguments.
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var intValue: Int? {
        if case .number(let n) = self { return Int(n) }
        if case .string(let s) = self { return Int(s) }
        return nil
    }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    public static func string(_ value: String?) -> JSONValue { value.map { .string($0) } ?? .null }
}

// MARK: - JSON-RPC 2.0

/// Request ids may be a number, a string, or absent (notification).
public enum JSONRPCID: Codable, Equatable, Sendable {
    case number(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) { self = .number(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

public struct JSONRPCRequest: Codable, Sendable {
    public let jsonrpc: String
    public let id: JSONRPCID?
    public let method: String
    public let params: JSONValue?

    /// No id means a notification: the client expects no reply.
    public var isNotification: Bool { id == nil }
}

public struct JSONRPCErrorBody: Codable, Equatable, Sendable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public static func invalidRequest(_ message: String) -> Self { .init(code: -32600, message: message) }
    public static func methodNotFound(_ method: String) -> Self {
        .init(code: -32601, message: "Unknown method: \(method)")
    }
    public static func invalidParams(_ message: String) -> Self { .init(code: -32602, message: message) }
    public static func internalError(_ message: String) -> Self { .init(code: -32603, message: message) }
}

public struct JSONRPCResponse: Codable, Sendable {
    public let jsonrpc: String
    public let id: JSONRPCID?
    public let result: JSONValue?
    public let error: JSONRPCErrorBody?

    public init(id: JSONRPCID?, result: JSONValue) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: JSONRPCID?, error: JSONRPCErrorBody) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }
}
