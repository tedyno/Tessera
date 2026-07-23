import Foundation

/// A destination for query rows delivered incrementally, so an arbitrarily large
/// result can be processed (typically exported) without ever holding all of it in
/// memory. The producer — a driver's `stream(_:batchSize:into:)` — calls `begin`
/// exactly once, then `write` for each batch, then `finish`, all on a single task
/// and never concurrently, so conforming types need no internal locking.
///
/// Columns are best-effort: SQLite knows them before the first row (so an empty
/// result still gets a header), while the network drivers derive them from the
/// first row and pass an empty array when the result has none.
public protocol RowSink: Sendable {
    func begin(columns: [ColumnDescriptor]) throws
    func write(_ rows: [[Cell]]) throws
    func finish() throws
}

/// A destination for raw bytes, written incrementally. Backs the streaming
/// exporters: an in-memory buffer for tests, a file for real exports.
public protocol ByteSink: Sendable {
    func write(_ data: Data) throws
}

/// Collects streamed bytes in memory — for tests and small callers that still want
/// the whole thing as `Data` at the end. Serialized by the `RowSink` contract.
public final class InMemoryByteSink: ByteSink, @unchecked Sendable {
    public private(set) var data = Data()
    public init() {}
    public func write(_ data: Data) throws { self.data.append(data) }
    public var string: String { String(decoding: data, as: UTF8.self) }
}

/// Appends streamed bytes straight to a file handle, so exporting a huge result
/// never materializes it in memory. Call `close()` when done.
public final class FileByteSink: ByteSink, @unchecked Sendable {
    private let handle: FileHandle
    public private(set) var bytesWritten = 0
    public init(_ handle: FileHandle) { self.handle = handle }

    /// Creates (truncating) the file at `url` and opens it for writing.
    public convenience init(creatingAt url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.init(handle)
    }

    public func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        bytesWritten += data.count
    }

    public func close() throws { try handle.close() }
}
