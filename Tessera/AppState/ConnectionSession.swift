import SwiftUI
import DBKit
import DBPersistence
import DBDriverPostgres
import DBDriverMySQL
import DBDriverSQLite
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
    /// Organizer folder path (workspace → … → folder), used to tell apart two
    /// connections that share a name but live in different folders.
    var location: [String] = []

    /// Name qualified by its deepest folder when it has one ("db · staging").
    var qualifiedName: String {
        location.last.map { "\(name) · \($0)" } ?? name
    }
    /// Full breadcrumb including the connection name (for a tooltip).
    var pathLabel: String { (location + [name]).joined(separator: " / ") }

    private(set) var status: Status = .idle
    private(set) var serverVersion: String?
    private(set) var schema: DatabaseTree?
    /// The host/port a client should actually connect to — the SSH tunnel's local
    /// endpoint when tunnelled, otherwise the direct host. Used by dump/export.
    private(set) var endpoint: NetworkEndpoint?
    /// The database name of the live connection, for dump/export.
    private(set) var database: String?
    /// Databases available on the server, for the schema sidebar's switcher.
    private(set) var databases: [String] = []
    /// Overrides `profile.database` on the next open, so switching database (and any
    /// later auto-reconnect) targets the chosen one rather than the profile default.
    var preferredDatabase: String?

    private(set) var driver: (any DatabaseDriver)?
    private var tunnel: SSHTunnel?
    /// Last time a query actually ran against this session — the auto-disconnect
    /// idle sweep compares against this, not against when a tab merely sits open.
    private(set) var lastActivityAt = Date()
    /// True while `close()` is tearing the connection down — `status` itself only
    /// flips to `.idle` once that's finished, so the sidebar dot needs this to show
    /// a spinner during the teardown instead of sitting frozen on the old state.
    private(set) var isDisconnecting = false
    /// Diagnostics sink, injected by the console. Errors here are what the status
    /// bar can't show: the raw text plus the settings that produced it.
    @ObservationIgnored var log: ConnectionLog?

    init(profile: ConnectionProfile) {
        self.id = profile.id
        self.name = profile.name
        self.colorName = profile.color
        self.engine = profile.kind
    }

    /// Cap on each connect stage (tunnel, then driver) so a silent network never
    /// leaves the session spinning on "Connecting…" forever.
    static let stageTimeout: Duration = .seconds(15)

    var isReady: Bool { status == .ready }
    var isConnecting: Bool { status == .connecting }
    var errorMessage: String? { if case .failed(let m) = status { return m }; return nil }

    /// Resets the idle-disconnect timer — call whenever the session runs a query.
    func touch() { lastActivityAt = Date() }

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
                let via = ssh.configAlias.map { "alias \($0)" }
                    ?? "\(ssh.username)@\(ssh.host):\(ssh.port)"
                log?.record(profile.name, .tunnel, "Opening tunnel via \(via)",
                            detail: Self.tunnelDetail(ssh, profile: profile))
                let tunnel = SSHTunnel()
                self.tunnel = tunnel   // stored first so a timeout can still tear it down
                endpoint = try await withTimeout(Self.stageTimeout) {
                    try await tunnel.start(
                        ssh: ssh, secrets: secrets,
                        remoteHost: profile.host, remotePort: profile.port)
                }
                log?.record(profile.name, .tunnel,
                            "Tunnel open on \(endpoint.host):\(endpoint.port)")
            } else {
                endpoint = NetworkEndpoint(host: profile.host, port: profile.port)
            }
            self.endpoint = endpoint

            // Reconnect to the chosen database when the user switched away from the
            // profile default (Postgres can't change database on a live connection).
            var target = profile
            if let preferred = preferredDatabase, !preferred.isEmpty { target.database = preferred }
            self.database = target.database
            let effective = target

            let driver: any DatabaseDriver = switch profile.kind {
            case .postgres: PostgresDriver()
            case .mysql, .mariadb: MySQLDriver()   // same wire protocol
            case .sqlite: SQLiteDriver()
            }
            self.driver = driver

            log?.record(profile.name, .connect,
                        profile.kind.isFileBased
                            ? "Opening \(effective.database)"
                            : "Connecting to \(endpoint.host):\(endpoint.port)/\(effective.database)",
                        detail: Self.connectDetail(effective, endpoint: endpoint, secrets: secrets))
            try await withTimeout(Self.stageTimeout) {
                try await driver.connect(profile: effective, secrets: secrets, endpoint: endpoint)
            }
            status = .ready
            lastActivityAt = Date()
            serverVersion = try? await driver.serverVersion()
            log?.record(profile.name, .connect,
                        "Connected\(serverVersion.map { " — \($0)" } ?? "")")
            schema = try? await driver.fetchSchema()
            if schema == nil {
                log?.record(profile.name, .introspect, "Could not read the schema", isError: true)
            }
            databases = await fetchDatabases()
        } catch {
            status = .failed(Self.message(for: error))
            // The status bar gets one line; the log gets everything.
            log?.record(profile.name, .connect, Self.message(for: error), isError: true,
                        detail: Self.failureDetail(error, profile: profile, endpoint: endpoint))
        }
    }

    /// Tears the connection down (driver + tunnel) and marks it idle. Logs only when
    /// there was actually something live — `open()` also calls this to clear any
    /// prior state before reconnecting, and a fresh first connect has nothing to tear
    /// down yet.
    ///
    /// Guards against a second overlapping call (e.g. "Disconnect All" and the idle
    /// sweep landing on the same session): everything up to the first `await` runs
    /// synchronously on the main actor, so a caller that arrives while `isDisconnecting`
    /// is already true bails out before touching the driver/tunnel a second time.
    func close(reason: String = "Disconnected") async {
        guard !isDisconnecting, driver != nil || tunnel != nil else { return }
        isDisconnecting = true
        await driver?.close()
        await tunnel?.stop()
        driver = nil
        tunnel = nil
        serverVersion = nil
        schema = nil
        endpoint = nil
        database = nil
        databases = []
        status = .idle
        isDisconnecting = false
        log?.record(name, .disconnect, reason)
    }

    /// Re-introspects the schema of a live connection.
    func refreshSchema() async {
        guard let driver else { return }
        schema = try? await driver.fetchSchema()
    }

    /// Lists the databases on the server (excluding templates/system schemas).
    private func fetchDatabases() async -> [String] {
        guard let driver, let sql = engine.dialect.listDatabasesSQL else { return [] }
        guard let result = try? await driver.execute(sql, maxRows: nil) else { return [] }
        return result.rows.compactMap { $0.first?.text }
    }

    /// Marks the session failed without connecting (e.g. Keychain access denied).
    func reportFailure(_ message: String) {
        status = .failed(message)
        log?.record(name, .connect, message, isError: true)
    }

    // MARK: Diagnostics detail

    private static func tunnelDetail(_ ssh: SSHConfig, profile: ConnectionProfile) -> String {
        var lines = ["SSH host: \(ssh.host):\(ssh.port)", "SSH user: \(ssh.username)"]
        if let alias = ssh.configAlias { lines.append("Config alias: \(alias)") }
        switch ssh.authMethod {
        case .password: lines.append("Auth: password")
        case .privateKey(let path): lines.append("Auth: key \(path.isEmpty ? "(from ssh config)" : path)")
        }
        lines.append("Forwarding to: \(profile.host):\(profile.port)")
        return lines.joined(separator: "\n")
    }

    private static func connectDetail(_ profile: ConnectionProfile,
                                      endpoint: NetworkEndpoint, secrets: Secrets) -> String {
        [
            "Engine: \(profile.kind.displayName)",
            "Endpoint: \(endpoint.host):\(endpoint.port)",
            "Database: \(profile.database)",
            "User: \(profile.username)",
            "TLS: \(profile.tlsMode.rawValue)",
            "Password: \((secrets.databasePassword?.isEmpty == false) ? "supplied" : "none")",
        ].joined(separator: "\n")
    }

    /// The raw error as well as the message — `DatabaseError` hides the underlying
    /// driver text, which is usually the part that says what actually went wrong.
    private static func failureDetail(_ error: Error, profile: ConnectionProfile,
                                      endpoint: NetworkEndpoint?) -> String {
        var lines = ["Raw error: \(String(reflecting: error))"]
        if let endpoint { lines.append("Endpoint: \(endpoint.host):\(endpoint.port)") }
        lines.append("Engine: \(profile.kind.displayName)")
        lines.append("Database: \(profile.database)")
        lines.append("User: \(profile.username)")
        lines.append("TLS: \(profile.tlsMode.rawValue)")
        if profile.ssh != nil { lines.append("Via SSH tunnel: yes") }
        return lines.joined(separator: "\n")
    }

    /// Quotes an identifier for this engine so mixed-case / reserved names work.
    func quote(_ identifier: String) -> String {
        engine.dialect.quote(identifier)
    }

    static func message(for error: Error) -> String {
        if error is OperationTimeout {
            return String(localized: "Timed out while connecting. Use “Test connection” in the connection’s settings to see whether the tunnel or the database is at fault.")
        }
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
