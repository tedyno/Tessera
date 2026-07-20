import Foundation
import DBKit
import DBTunnel
import DBDriverPostgres
import DBDriverMySQL

/// Runs a connection test in the two stages it actually happens in — SSH tunnel
/// first, then the database through it — so a failure points at the stage that
/// broke instead of one opaque error. Each stage has a timeout and retries.
@MainActor
@Observable
final class ConnectionTester {
    enum Stage: String, CaseIterable, Identifiable {
        case tunnel, database
        var id: String { rawValue }

        var title: String {
            switch self {
            case .tunnel: String(localized: "SSH tunnel")
            case .database: String(localized: "Database")
            }
        }
    }

    enum State: Equatable {
        case pending
        /// Not applicable (e.g. no tunnel configured).
        case skipped
        case running(String)
        case ok(String)
        case failed(String)

        var isFailure: Bool { if case .failed = self { return true }; return false }
    }

    /// Per-stage timeout. Long enough for a slow bastion, short enough not to hang.
    static let stageTimeout: Duration = .seconds(15)
    /// Total attempts per stage (first try + retries).
    static let attempts = 3
    private static let retryDelay: Duration = .milliseconds(800)

    private(set) var states: [Stage: State] = [:]
    private(set) var isRunning = false

    @ObservationIgnored private var task: Task<Void, Never>?

    func state(_ stage: Stage) -> State { states[stage] ?? .pending }

    /// True once every stage that ran finished successfully.
    var succeeded: Bool {
        !isRunning && !states.isEmpty && !states.values.contains { $0.isFailure }
            && states.values.contains { if case .ok = $0 { return true }; return false }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    func start(profile: ConnectionProfile, secrets: Secrets) {
        cancel()
        states = [.tunnel: .pending, .database: .pending]
        isRunning = true
        task = Task { await run(profile: profile, secrets: secrets) }
    }

    private func run(profile: ConnectionProfile, secrets: Secrets) async {
        defer { isRunning = false }
        var tunnel: SSHTunnel?
        defer { let t = tunnel; Task { await t?.stop() } }

        // Stage 1 — the tunnel, if there is one.
        var endpoint = NetworkEndpoint(host: profile.host, port: profile.port)
        if let ssh = profile.ssh {
            let target = Self.describe(ssh)
            // Built up front so it can be torn down even if `start` times out.
            let created = SSHTunnel()
            tunnel = created
            do {
                let local = try await attempt(.tunnel, describing: "Connecting to \(target)…") {
                    try await created.start(ssh: ssh, secrets: secrets,
                                            remoteHost: profile.host, remotePort: profile.port)
                }
                endpoint = local
                states[.tunnel] = .ok(String(localized: "\(target) → 127.0.0.1:\(String(local.port))"))
            } catch {
                states[.tunnel] = .failed(Self.message(for: error, stage: .tunnel))
                states[.database] = .skipped
                return
            }
        } else {
            states[.tunnel] = .skipped
        }

        // Stage 2 — the database, through whatever endpoint stage 1 produced.
        let via = profile.ssh == nil
            ? "\(profile.host):\(String(profile.port))"
            : String(localized: "the tunnel")
        let target = endpoint
        do {
            let version = try await attempt(.database, describing: "Connecting to \(via)…") {
                let driver: any DatabaseDriver = profile.kind == .postgres ? PostgresDriver() : MySQLDriver()
                try await driver.connect(profile: profile, secrets: secrets, endpoint: target)
                let version = (try? await driver.serverVersion()) ?? ""
                await driver.close()
                return version
            }
            states[.database] = .ok(version.isEmpty
                                    ? String(localized: "Connected")
                                    : "\(profile.kind.displayName) \(version)")
        } catch {
            states[.database] = .failed(Self.message(for: error, stage: .database))
        }
    }

    /// Runs one stage with a timeout, retrying a few times and reporting each retry.
    private func attempt<T: Sendable>(_ stage: Stage, describing description: String,
                                      _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        var lastError: Error = OperationTimeout()
        for attempt in 1...Self.attempts {
            if Task.isCancelled { throw CancellationError() }
            states[stage] = .running(attempt == 1
                                     ? description
                                     : String(localized: "Reconnecting… (attempt \(String(attempt)) of \(String(Self.attempts)))"))
            do {
                return try await withTimeout(Self.stageTimeout, work)
            } catch {
                lastError = error
                if error is CancellationError { throw error }
                if attempt < Self.attempts { try? await Task.sleep(for: Self.retryDelay) }
            }
        }
        throw lastError
    }

    // MARK: Helpers

    /// "user@host:port" for the tunnel, resolving a ~/.ssh/config alias first.
    private static func describe(_ ssh: SSHConfig) -> String {
        guard let alias = ssh.configAlias, !alias.isEmpty else {
            return "\(ssh.username)@\(ssh.host):\(String(ssh.port))"
        }
        let resolved = SSHConfigFile.resolve(alias, in: SSHConfigFile.loadDefault())
        let user = resolved.user ?? (ssh.username.isEmpty ? NSUserName() : ssh.username)
        return "\(user)@\(resolved.hostName):\(String(resolved.port ?? 22))"
    }

    private static func message(for error: Error, stage: Stage) -> String {
        if error is OperationTimeout {
            return stage == .tunnel
                ? String(localized: "Timed out reaching the SSH server. Check the host, port, and that you can reach it.")
                : String(localized: "Timed out connecting to the database. The tunnel is up, so check the database host, port, and that it is listening.")
        }
        if error is CancellationError { return String(localized: "Cancelled.") }
        if let dbError = error as? DatabaseError {
            switch dbError {
            case .connectionFailed(let m), .queryFailed(let m), .unsupported(let m): return m
            case .notConnected: return String(localized: "Not connected.")
            case .cancelled: return String(localized: "Cancelled.")
            }
        }
        return String(describing: error)
    }
}
