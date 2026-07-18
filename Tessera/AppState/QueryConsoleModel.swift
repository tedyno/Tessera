import SwiftUI
import DBKit
import DBDriverPostgres

/// Drives one query console: holds the driver, opens a connection for a chosen
/// profile, runs SQL, publishes results. Secrets come from the Keychain via the
/// caller; this model never stores them.
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

    private let driver = PostgresDriver()

    var isBusy: Bool { status == .connecting || status == .running }

    /// Opens a connection for the given profile (Postgres only for now).
    /// Without an SSH tunnel the endpoint is the profile host directly; Phase 5
    /// will point it at the local end of the tunnel.
    func open(profile: ConnectionProfile, secrets: Secrets) async {
        guard profile.kind == .postgres else {
            status = .failed("\(profile.kind.displayName) is not supported yet (Phase 4).")
            return
        }
        connectionName = profile.name
        result = nil
        elapsedMS = nil
        status = .connecting
        do {
            try await driver.connect(
                profile: profile,
                secrets: secrets,
                endpoint: NetworkEndpoint(host: profile.host, port: profile.port)
            )
            status = .ready
        } catch {
            status = .failed(Self.message(for: error))
        }
    }

    func run() async {
        guard status == .ready else { return }
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
