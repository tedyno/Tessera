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
    func execute(_ sql: String) async throws -> QueryResult
    /// The database server version string (e.g. "16.3").
    func serverVersion() async throws -> String
    func close() async
}
