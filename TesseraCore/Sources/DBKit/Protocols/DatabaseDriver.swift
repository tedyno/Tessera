import Foundation

/// Driver-level errors, independent of any specific engine.
public enum DatabaseError: Error, Sendable, Equatable {
    case notConnected
    case connectionFailed(String)
    case queryFailed(String)
    case cancelled
    case unsupported(String)
}

/// Uniform contract for a database engine. `DBKit` knows **nothing** about NIO or
/// concrete drivers — implementations (`DBDriverPostgres`, `DBDriverMySQL`) depend
/// on this protocol, not the other way around. The UI layer works purely through it.
///
/// `endpoint` is the actual TCP target: either the profile host directly, or the
/// local end of an SSH tunnel (see `NetworkEndpoint`). The driver knows nothing
/// about SSH.
public protocol DatabaseDriver: Sendable {
    func connect(profile: ConnectionProfile, secrets: Secrets, endpoint: NetworkEndpoint) async throws
    func fetchSchema() async throws -> DatabaseTree
    /// Runs `sql`, reading at most `maxRows` rows (nil = no cap). Stopping early
    /// keeps a huge result from being pulled entirely into memory; the result is
    /// then marked `isTruncated`.
    func execute(_ sql: String, maxRows: Int?) async throws -> QueryResult
    /// Runs `statements` atomically on a single connection (BEGIN … COMMIT, with
    /// ROLLBACK on the first failure), so a partial write can't be left behind.
    func executeTransaction(_ statements: [String]) async throws
    /// Asks the server to abort the query currently running on this driver
    /// (Postgres `pg_cancel_backend`, MySQL `KILL QUERY`). Best effort.
    func cancelRunningQuery() async
    /// The database server version string (e.g. "16.3").
    func serverVersion() async throws -> String
    func close() async
}

public extension DatabaseDriver {
    /// Convenience for callers that don't need a row cap.
    func execute(_ sql: String) async throws -> QueryResult {
        try await execute(sql, maxRows: nil)
    }
}
