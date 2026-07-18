import SwiftUI
import DBKit
import DBDriverPostgres

/// Drives one query console: holds the driver, runs SQL, publishes results.
/// Phase 1 uses a hardcoded local connection; Phase 2 replaces it with real
/// connection management and Keychain-backed secrets.
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

    private let driver = PostgresDriver()

    // TEMPORARY: hardcoded local connection (Phase 1 happy path). Requires a local
    // Postgres reachable at 127.0.0.1:5432. Replaced in Phase 2.
    private let profile = ConnectionProfile(
        name: "local", kind: .postgres, host: "127.0.0.1", port: 5432,
        database: "shop", username: "tessera", tlsMode: .disable
    )
    private let secrets = Secrets(databasePassword: "tessera")

    var isBusy: Bool { status == .connecting || status == .running }

    func connectIfNeeded() async {
        guard status == .idle || isFailed else { return }
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
        if status == .idle || isFailed { await connectIfNeeded() }
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

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
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
