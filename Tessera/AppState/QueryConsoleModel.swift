import SwiftUI
import DBKit
import DBDriverPostgres
import DBDriverMySQL
import DBTunnel

/// Drives one query console: opens a connection for a chosen profile (Postgres or
/// MySQL), runs SQL, publishes results and the schema tree. Secrets come from the
/// Keychain via the caller; this model never stores them.
@MainActor
@Observable
final class QueryConsoleModel {
    enum Status: Equatable {
        case idle
        case connecting
        case ready
        case running
        case failed(String)
    }

    var sql: String = """
        SELECT o.id, c.name, o.total, o.status, o.created_at
        FROM orders o
        JOIN customers c ON c.id = o.customer_id
        ORDER BY o.created_at DESC
        LIMIT 200;
        """

    private(set) var status: Status = .idle
    private(set) var result: QueryResult?
    private(set) var elapsedMS: Int?
    private(set) var connectionName: String?
    private(set) var schema: DatabaseTree?

    private var driver: (any DatabaseDriver)?
    private var tunnel: SSHTunnel?

    var isBusy: Bool { status == .connecting || status == .running }

    /// Opens a connection for the given profile, picking the driver by engine.
    /// Without an SSH tunnel the endpoint is the profile host directly; Phase 5
    /// points it at the local end of the tunnel.
    func open(profile: ConnectionProfile, secrets: Secrets) async {
        await driver?.close()
        await tunnel?.stop()
        tunnel = nil
        connectionName = profile.name
        result = nil
        elapsedMS = nil
        schema = nil
        status = .connecting

        do {
            // If the profile uses an SSH tunnel, forward a local port and connect
            // the driver there; otherwise connect directly.
            let endpoint: NetworkEndpoint
            if let ssh = profile.ssh {
                let tunnel = SSHTunnel()
                endpoint = try await tunnel.start(
                    ssh: ssh, secrets: secrets,
                    remoteHost: profile.host, remotePort: profile.port)
                self.tunnel = tunnel
            } else {
                endpoint = NetworkEndpoint(host: profile.host, port: profile.port)
            }

            let driver: any DatabaseDriver = switch profile.kind {
            case .postgres: PostgresDriver()
            case .mysql: MySQLDriver()
            }
            self.driver = driver

            try await driver.connect(profile: profile, secrets: secrets, endpoint: endpoint)
            status = .ready
            schema = try? await driver.fetchSchema()
        } catch {
            status = .failed(Self.message(for: error))
        }
    }

    func refreshSchema() async {
        guard let driver else { return }
        schema = try? await driver.fetchSchema()
    }

    /// Sets the editor to `SELECT *` for a table and runs it.
    func selectAll(schema: String, table: String) async {
        sql = "SELECT * FROM \(schema).\(table) LIMIT 200;"
        await run()
    }

    func run() async {
        guard status == .ready, let driver else { return }
        status = .running
        do {
            let queryResult = try await driver.execute(sql)
            result = queryResult
            elapsedMS = queryResult.elapsed.map(Self.milliseconds)
            status = .ready
        } catch {
            status = .failed(Self.message(for: error))
        }
    }

    var errorMessage: String? {
        if case .failed(let message) = status { return message }
        return nil
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let c = duration.components
        return Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000)
    }

    private static func message(for error: Error) -> String {
        guard let dbError = error as? DatabaseError else { return String(describing: error) }
        switch dbError {
        case .notConnected: return "Not connected"
        case .connectionFailed(let m): return "Connection failed: \(m)"
        case .queryFailed(let m): return m
        case .cancelled: return "Cancelled"
        case .unsupported(let m): return "Unsupported: \(m)"
        }
    }
}
