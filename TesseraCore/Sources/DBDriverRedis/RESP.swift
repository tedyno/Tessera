import Foundation
import NIOCore

/// One RESP2 protocol value. Bulk strings are decoded as UTF-8 (lossy for
/// binary payloads — Tessera is a display client, not a byte-faithful proxy).
public enum RESPValue: Sendable, Equatable {
    case simpleString(String)
    case error(String)
    case integer(Int64)
    /// nil = null bulk string ($-1).
    case bulkString(String?)
    /// nil = null array (*-1).
    case array([RESPValue]?)
}

/// RESP2 wire coding: commands out (always as arrays of bulk strings), replies
/// in (incremental — a partial frame leaves the buffer untouched and returns
/// nil, so the caller just waits for more bytes). Pure functions over
/// `ByteBuffer`, unit-tested without a server.
public enum RESPCodec {
    /// Encodes a command (name + arguments) as the client side always sends it.
    public static func encode(command: [String], into buffer: inout ByteBuffer) {
        buffer.writeString("*\(command.count)\r\n")
        for argument in command {
            let bytes = Array(argument.utf8)
            buffer.writeString("$\(bytes.count)\r\n")
            buffer.writeBytes(bytes)
            buffer.writeString("\r\n")
        }
    }

    public enum ParseError: Error, Equatable {
        case invalidPrefix(UInt8)
        case invalidLength
    }

    /// Parses one complete reply from the buffer, consuming its bytes; nil when
    /// the buffer doesn't yet hold a full frame (nothing is consumed then).
    public static func parse(_ buffer: inout ByteBuffer) throws -> RESPValue? {
        let snapshot = buffer.readerIndex
        if let value = try parseValue(&buffer) { return value }
        buffer.moveReaderIndex(to: snapshot)
        return nil
    }

    private static func parseValue(_ buffer: inout ByteBuffer) throws -> RESPValue? {
        guard let prefix = buffer.readInteger(as: UInt8.self) else { return nil }
        switch prefix {
        case UInt8(ascii: "+"):
            guard let line = readLine(&buffer) else { return nil }
            return .simpleString(line)
        case UInt8(ascii: "-"):
            guard let line = readLine(&buffer) else { return nil }
            return .error(line)
        case UInt8(ascii: ":"):
            guard let line = readLine(&buffer) else { return nil }
            guard let value = Int64(line) else { throw ParseError.invalidLength }
            return .integer(value)
        case UInt8(ascii: "$"):
            guard let line = readLine(&buffer) else { return nil }
            guard let length = Int(line), length >= -1 else { throw ParseError.invalidLength }
            if length == -1 { return .bulkString(nil) }
            guard buffer.readableBytes >= length + 2,
                  let bytes = buffer.readBytes(length: length) else { return nil }
            buffer.moveReaderIndex(forwardBy: 2)   // trailing \r\n
            return .bulkString(String(decoding: bytes, as: UTF8.self))
        case UInt8(ascii: "*"):
            guard let line = readLine(&buffer) else { return nil }
            guard let count = Int(line), count >= -1 else { throw ParseError.invalidLength }
            if count == -1 { return .array(nil) }
            var elements: [RESPValue] = []
            elements.reserveCapacity(count)
            for _ in 0..<count {
                guard let element = try parseValue(&buffer) else { return nil }
                elements.append(element)
            }
            return .array(elements)
        default:
            throw ParseError.invalidPrefix(prefix)
        }
    }

    /// Reads up to (and consuming) the next \r\n; nil when incomplete.
    private static func readLine(_ buffer: inout ByteBuffer) -> String? {
        let readable = buffer.readableBytesView
        guard let lineFeed = readable.firstIndex(of: UInt8(ascii: "\n")),
              lineFeed > readable.startIndex else { return nil }
        let length = lineFeed - readable.startIndex - 1   // strip \r
        guard let bytes = buffer.readBytes(length: length) else { return nil }
        buffer.moveReaderIndex(forwardBy: 2)
        return String(decoding: bytes, as: UTF8.self)
    }
}

public extension RESPValue {
    /// The value as display text: what a cell shows for a scalar reply.
    var displayText: String? {
        switch self {
        case .simpleString(let s): return s
        case .error(let e): return e
        case .integer(let i): return String(i)
        case .bulkString(let s): return s
        case .array: return nil
        }
    }
}
