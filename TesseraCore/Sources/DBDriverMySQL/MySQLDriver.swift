import Foundation
import DBKit
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL
import Logging

/// MySQL implementation of `DatabaseDriver`, built on MySQLNIO. MySQLNIO has no
/// modern async pool, so this holds a single `MySQLConnection` and bridges its
/// `EventLoopFuture` API to async/await. One instance per session.
public actor MySQLDriver: DatabaseDriver {
    private var connection: MySQLConnection?
    private let group: EventLoopGroup
    private var databaseName: String?

    public init() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    public func connect(profile: ConnectionProfile, secrets: Secrets, endpoint: NetworkEndpoint) async throws {
        await close()
        do {
            let address = try SocketAddress.makeAddressResolvingHost(endpoint.host, port: endpoint.port)
            let connection = try await MySQLConnection.connect(
                to: address,
                username: profile.username,
                database: profile.database,
                password: secrets.databasePassword ?? "",
                tlsConfiguration: Self.makeTLS(profile.tlsMode),
                on: group.next()
            ).get()
            self.connection = connection
            self.databaseName = profile.database
        } catch {
            await close()
            throw DatabaseError.connectionFailed(String(describing: error))
        }
    }

    public func execute(_ sql: String) async throws -> QueryResult {
        guard let connection else { throw DatabaseError.notConnected }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            // simpleQuery uses the text protocol (COM_QUERY): every value arrives
            // as UTF-8 text, which is what we want for generic display.
            let rows = try await connection.simpleQuery(sql).get()
            var columns: [ColumnDescriptor] = []
            if let first = rows.first {
                columns = first.columnDefinitions.map {
                    ColumnDescriptor(name: $0.name, typeName: String(describing: $0.columnType))
                }
            }
            var resultRows: [[Cell]] = []
            for row in rows {
                var cells: [Cell] = []
                for definition in row.columnDefinitions {
                    cells.append(Cell(Self.text(row.column(definition.name))))
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
        guard connection != nil else { throw DatabaseError.notConnected }
        let database = databaseName ?? ""

        let tables = try await execute("""
            SELECT table_name, table_type FROM information_schema.tables
            WHERE table_schema = DATABASE() ORDER BY table_name
            """)
        let columns = try await execute("""
            SELECT table_name, column_name, data_type, is_nullable, column_key
            FROM information_schema.columns
            WHERE table_schema = DATABASE()
            ORDER BY table_name, ordinal_position
            """)

        var columnsByTable: [String: [SchemaColumn]] = [:]
        for row in columns.rows where row.count >= 5 {
            let table = row[0].text ?? ""
            columnsByTable[table, default: []].append(
                SchemaColumn(
                    name: row[1].text ?? "",
                    dataType: row[2].text ?? "",
                    isPrimaryKey: (row[4].text ?? "") == "PRI",
                    isNullable: (row[3].text ?? "YES") == "YES"))
        }

        var schemaTables: [SchemaTable] = []
        for row in tables.rows where row.count >= 2 {
            let name = row[0].text ?? ""
            let kind: SchemaTable.Kind = (row[1].text ?? "").uppercased().contains("VIEW") ? .view : .table
            schemaTables.append(SchemaTable(name: name, kind: kind, columns: columnsByTable[name] ?? []))
        }

        return DatabaseTree(databaseName: database, schemas: [SchemaNamespace(name: database, tables: schemaTables)])
    }

    public func close() async {
        if let connection {
            try? await connection.close().get()
        }
        connection = nil
    }

    // MARK: - Helpers

    private static func makeTLS(_ mode: TLSMode) -> TLSConfiguration? {
        switch mode {
        case .disable:
            return nil
        case .prefer, .require:
            var config = TLSConfiguration.makeClientConfiguration()
            config.certificateVerification = .none
            return config
        case .verifyCA, .verifyFull:
            return .makeClientConfiguration()
        }
    }

    private static func text(_ data: MySQLData?) -> String? {
        // COM_QUERY uses the text protocol, so every non-null value is UTF-8 text
        // in the buffer regardless of column type (int, decimal, datetime, …).
        guard let data, var buffer = data.buffer else { return nil }
        return buffer.readString(length: buffer.readableBytes)
    }
}
