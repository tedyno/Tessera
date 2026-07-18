import Foundation
import DBKit
import PostgresNIO
import NIOSSL

/// PostgreSQL implementation of `DatabaseDriver`, built on PostgresNIO's async
/// `PostgresClient` (with its built-in connection pool). One instance owns one
/// live connection pool; the UI creates one per session.
public actor PostgresDriver: DatabaseDriver {
    private var client: PostgresClient?
    private var runTask: Task<Void, Never>?

    public init() {}

    public func connect(profile: ConnectionProfile, secrets: Secrets, endpoint: NetworkEndpoint) async throws {
        // Drop any prior connection so re-opening a driver is clean.
        await close()

        let config = PostgresClient.Configuration(
            host: endpoint.host,
            port: endpoint.port,
            username: profile.username,
            password: secrets.databasePassword,
            database: profile.database,
            tls: Self.makeTLS(profile.tlsMode)
        )

        let client = PostgresClient(configuration: config)
        // The pool only works while `run()` is executing; keep it alive in a task.
        let task = Task { await client.run() }
        self.client = client
        self.runTask = task

        do {
            // Fail fast if the connection/auth is bad.
            _ = try await client.query("SELECT 1")
        } catch {
            await close()
            throw DatabaseError.connectionFailed(String(describing: error))
        }
    }

    public func execute(_ sql: String) async throws -> QueryResult {
        guard let client else { throw DatabaseError.notConnected }

        let clock = ContinuousClock()
        let start = clock.now
        do {
            let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
            var columns: [ColumnDescriptor] = []
            var resultRows: [[Cell]] = []

            for try await row in rows {
                var cells: [Cell] = []
                var index = 0
                for cell in row {
                    if columns.count <= index {
                        columns.append(ColumnDescriptor(name: cell.columnName, typeName: Self.typeName(cell.dataType)))
                    }
                    cells.append(Cell(Self.stringify(cell)))
                    index += 1
                }
                resultRows.append(cells)
            }

            return QueryResult(columns: columns, rows: resultRows, elapsed: clock.now - start)
        } catch is CancellationError {
            throw DatabaseError.cancelled
        } catch {
            throw DatabaseError.queryFailed(String(describing: error))
        }
    }

    public func fetchSchema() async throws -> DatabaseTree {
        // Implemented in Phase 3.
        throw DatabaseError.unsupported("fetchSchema")
    }

    public func close() async {
        runTask?.cancel()
        runTask = nil
        client = nil
    }

    // MARK: - Helpers

    private static func makeTLS(_ mode: TLSMode) -> PostgresClient.Configuration.TLS {
        switch mode {
        case .disable:
            return .disable
        case .prefer:
            return .prefer(.makeClientConfiguration())
        case .require, .verifyCA, .verifyFull:
            return .require(.makeClientConfiguration())
        }
    }

    /// Renders a cell to display text. `nil` means SQL NULL. Decoding is driven by
    /// the column's actual Postgres type (values often arrive in binary format, so
    /// we must not blindly read bytes as text). Unknown types fall back to their
    /// text-format bytes.
    private static func stringify(_ cell: PostgresCell) -> String? {
        guard cell.bytes != nil else { return nil }
        do {
            switch cell.dataType {
            case .bool:
                return try cell.decode(Bool.self) ? "true" : "false"
            case .int2:
                return String(try cell.decode(Int16.self))
            case .int4, .oid:
                return String(try cell.decode(Int32.self))
            case .int8:
                return String(try cell.decode(Int64.self))
            case .float4:
                return String(try cell.decode(Float.self))
            case .float8:
                return String(try cell.decode(Double.self))
            case .numeric:
                return try cell.decode(Decimal.self).description
            case .uuid:
                return try cell.decode(UUID.self).uuidString
            case .timestamp, .timestamptz, .date:
                return try cell.decode(Date.self).ISO8601Format()
            case .text, .varchar, .bpchar, .name, .char, .json, .jsonb:
                return try cell.decode(String.self)
            default:
                break
            }
        } catch {
            // Fall through to raw text handling below.
        }
        // Unknown types are requested in text format by the server; read directly.
        if let buffer = cell.bytes, let text = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
            return text
        }
        return "<binary>"
    }

    private static func typeName(_ dataType: PostgresDataType) -> String {
        String(describing: dataType)
    }
}
