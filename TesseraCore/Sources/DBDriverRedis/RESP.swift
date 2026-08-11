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
        case invalidLineEnding
        case tooDeep
    }

    /// Sanity bounds on wire-declared sizes, so a malformed or hostile peer
    /// (a non-Redis service on the profiled port) can't crash the app with a
    /// declared multi-exabyte frame: Redis itself caps bulk strings at 512 MB,
    /// and no real reply carries a billion elements. Nesting is bounded for the
    /// same reason — real replies nest a handful of levels deep, while an
    /// endless run of `*1` headers is otherwise enough to exhaust memory.
    static let maxBulkLength = 512 * 1024 * 1024
    static let maxArrayCount = 10_000_000
    static let maxDepth = 64

    /// Parses one complete reply, consuming its bytes; nil when the buffer
    /// doesn't yet hold a full frame. Stateless: on nil *and* on a throw the
    /// buffer is left exactly as it was, so a caller that swallows the error
    /// cannot end up reading from the middle of a half-consumed frame. Feeding
    /// a stream chunk by chunk belongs to `RESPParser`, which doesn't restart
    /// from the beginning each time.
    public static func parse(_ buffer: inout ByteBuffer) throws -> RESPValue? {
        let snapshot = buffer.readerIndex
        var parser = RESPParser()
        do {
            if let value = try parser.next(&buffer) { return value }
        } catch {
            buffer.moveReaderIndex(to: snapshot)
            throw error
        }
        buffer.moveReaderIndex(to: snapshot)
        return nil
    }

    /// Reads up to (and consuming) the next CRLF; nil when incomplete. RESP has
    /// no bare-LF form: accepting one would silently eat the character before
    /// the newline, so a peer that isn't Redis fails loudly here instead.
    static func readLine(_ buffer: inout ByteBuffer) throws -> String? {
        let readable = buffer.readableBytesView
        guard let lineFeed = readable.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        guard lineFeed > readable.startIndex,
              readable[readable.index(before: lineFeed)] == UInt8(ascii: "\r")
        else { throw ParseError.invalidLineEnding }
        let length = readable.distance(from: readable.startIndex, to: lineFeed) - 1
        guard let bytes = buffer.readBytes(length: length) else { return nil }
        buffer.moveReaderIndex(forwardBy: 2)   // trailing \r\n
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Incremental RESP2 reader: keeps the partially built value across reads, so a
/// reply split over many TCP chunks is parsed once instead of from scratch on
/// every chunk — re-parsing made a large array cost O(chunks × elements) and
/// froze the event loop. Nesting is held on an explicit stack rather than the
/// call stack, because its depth comes off the wire.
public struct RESPParser: Sendable {
    /// An array whose header has been read but whose elements are still coming.
    private struct Frame {
        let count: Int
        var elements: [RESPValue]
    }

    private enum Token {
        case value(RESPValue)
        case arrayHeader(Int)
    }

    private var stack: [Frame] = []

    public init() {}

    /// The next complete value, consuming its bytes; nil when more bytes are
    /// needed. Anything already parsed stays in the parser, so the same
    /// instance must keep serving the same connection.
    public mutating func next(_ buffer: inout ByteBuffer) throws -> RESPValue? {
        while true {
            // A token that turns out to be incomplete is re-read in full next
            // time; only whole tokens are ever committed to the stack.
            let snapshot = buffer.readerIndex
            guard let token = try readToken(&buffer) else {
                buffer.moveReaderIndex(to: snapshot)
                return nil
            }
            var finished: RESPValue
            switch token {
            case .arrayHeader(let count):
                guard stack.count < RESPCodec.maxDepth else { throw RESPCodec.ParseError.tooDeep }
                if count > 0 {
                    var frame = Frame(count: count, elements: [])
                    // Reserve modestly: the declared count is untrusted until
                    // the elements actually arrive.
                    frame.elements.reserveCapacity(min(count, 4096))
                    stack.append(frame)
                    continue
                }
                finished = .array([])
            case .value(let value):
                finished = value
            }
            // Hand the value to its parent, closing every array it completes.
            var carried: RESPValue? = finished
            while let value = carried, !stack.isEmpty {
                stack[stack.count - 1].elements.append(value)
                carried = stack[stack.count - 1].elements.count == stack[stack.count - 1].count
                    ? .array(stack.removeLast().elements)
                    : nil
            }
            if let value = carried { return value }
        }
    }

    /// One scalar, or the header of an array whose elements follow.
    private func readToken(_ buffer: inout ByteBuffer) throws -> Token? {
        guard let prefix = buffer.readInteger(as: UInt8.self) else { return nil }
        switch prefix {
        case UInt8(ascii: "+"):
            guard let line = try RESPCodec.readLine(&buffer) else { return nil }
            return .value(.simpleString(line))
        case UInt8(ascii: "-"):
            guard let line = try RESPCodec.readLine(&buffer) else { return nil }
            return .value(.error(line))
        case UInt8(ascii: ":"):
            guard let line = try RESPCodec.readLine(&buffer) else { return nil }
            guard let value = Int64(line) else { throw RESPCodec.ParseError.invalidLength }
            return .value(.integer(value))
        case UInt8(ascii: "$"):
            guard let line = try RESPCodec.readLine(&buffer) else { return nil }
            guard let length = Int(line), length >= -1, length <= RESPCodec.maxBulkLength
            else { throw RESPCodec.ParseError.invalidLength }
            if length == -1 { return .value(.bulkString(nil)) }
            guard buffer.readableBytes >= length + 2,
                  let bytes = buffer.readBytes(length: length) else { return nil }
            // Verify the terminator rather than skipping two bytes blindly:
            // against a peer that isn't Redis, a wrong one means the declared
            // length was wrong, and every later reply would be misaligned.
            guard buffer.readInteger(as: UInt8.self) == UInt8(ascii: "\r"),
                  buffer.readInteger(as: UInt8.self) == UInt8(ascii: "\n")
            else { throw RESPCodec.ParseError.invalidLineEnding }
            return .value(.bulkString(String(decoding: bytes, as: UTF8.self)))
        case UInt8(ascii: "*"):
            guard let line = try RESPCodec.readLine(&buffer) else { return nil }
            guard let count = Int(line), count >= -1, count <= RESPCodec.maxArrayCount
            else { throw RESPCodec.ParseError.invalidLength }
            if count == -1 { return .value(.array(nil)) }
            return .arrayHeader(count)
        default:
            throw RESPCodec.ParseError.invalidPrefix(prefix)
        }
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
