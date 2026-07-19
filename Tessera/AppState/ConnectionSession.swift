import SwiftUI
import DBKit
import DBPersistence
import DBDriverPostgres
import DBDriverMySQL
import DBTunnel

/// One live database connection: its driver (and SSH tunnel), status, server
/// version, and introspected schema. Each query tab belongs to a session, so
/// several connections (e.g. staging and production) can be live at once.
@MainActor
@Observable
final class ConnectionSession: Identifiable {
    enum Status: Hashable {
        case idle
        case connecting
        case ready
        case failed(String)
    }

    /// Identified by the profile it was opened from.
    let id: UUID
    var name: String
    var colorName: String?
    let engine: DatabaseKind

    private(set) var status: Status = .idle
    private(set) var serverVersion: String?
    private(set) var schema: DatabaseTree?

    private(set) var driver: (any DatabaseDriver)?
    private var tunnel: SSHTunnel?

    init(profile: ConnectionProfile) {
        self.id = profile.id
        self.name = profile.name
        self.colorName = profile.color
        self.engine = profile.kind
    }

    var isReady: Bool { status == .ready }
    var isConnecting: Bool { status == .connecting }
    var errorMessage: String? { if case .failed(let m) = status { return m }; return nil }

    /// Opens (or reopens) the connection, building an SSH tunnel first when configured.
    func open(profile: ConnectionProfile, secrets: Secrets) async {
        await close()
        name = profile.name
        colorName = profile.color
        serverVersion = nil
        schema = nil
        status = .connecting
        do {
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
            serverVersion = try? await driver.serverVersion()
            schema = try? await driver.fetchSchema()
        } catch {
            status = .failed(Self.message(for: error))
        }
    }

    /// Tears the connection down (driver + tunnel) and marks it idle.
    func close() async {
        await driver?.close()
        await tunnel?.stop()
        driver = nil
        tunnel = nil
        serverVersion = nil
        schema = nil
        status = .idle
    }

    /// Re-introspects the schema of a live connection.
    func refreshSchema() async {
        guard let driver else { return }
        schema = try? await driver.fetchSchema()
    }

    /// Marks the session failed without connecting (e.g. Keychain access denied).
    func reportFailure(_ message: String) {
        status = .failed(message)
    }

    /// Quotes an identifier for this engine so mixed-case / reserved names work.
    func quote(_ identifier: String) -> String {
        switch engine {
        case .mysql:
            return "`" + identifier.replacingOccurrences(of: "`", with: "``") + "`"
        default:
            return "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
    }

    static func message(for error: Error) -> String {
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
