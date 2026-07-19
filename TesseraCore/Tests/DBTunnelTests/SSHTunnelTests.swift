import XCTest
import DBKit
import DBDriverPostgres
@testable import DBTunnel

/// SSH tunnel integration test. Skipped unless a test SSH server is provided.
///
/// Set: TESSERA_SSH_HOST, TESSERA_SSH_PORT, TESSERA_SSH_USER, TESSERA_SSH_PASSWORD,
/// TESSERA_SSH_TARGET_HOST, TESSERA_SSH_TARGET_PORT
final class SSHTunnelTests: XCTestCase {

    func testTunnelForwardsToTarget() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["TESSERA_SSH_HOST"],
              let user = env["TESSERA_SSH_USER"],
              let targetHost = env["TESSERA_SSH_TARGET_HOST"] else {
            throw XCTSkip("Set TESSERA_SSH_* env vars to run the SSH tunnel test")
        }
        let port = Int(env["TESSERA_SSH_PORT"] ?? "22") ?? 22
        let targetPort = Int(env["TESSERA_SSH_TARGET_PORT"] ?? "5432") ?? 5432

        let ssh = SSHConfig(host: host, port: port, username: user, authMethod: .password)
        let secrets = Secrets(sshPassword: env["TESSERA_SSH_PASSWORD"])

        let tunnel = SSHTunnel()
        let endpoint = try await tunnel.start(
            ssh: ssh, secrets: secrets, remoteHost: targetHost, remotePort: targetPort)
        defer { Task { await tunnel.stop() } }

        XCTAssertEqual(endpoint.host, "127.0.0.1")
        XCTAssertGreaterThan(endpoint.port, 0)

        // Prove the local port actually accepts a TCP connection (forwarded).
        let probe = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(endpoint.port).bigEndian)
            inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Foundation.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            close(sock)
            cont.resume(returning: result == 0)
        }
        XCTAssertTrue(probe)
    }

    /// End-to-end: tunnel to a Postgres reachable only via the SSH host, then run
    /// a real query through the forwarded local port.
    func testPostgresThroughTunnel() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["TESSERA_SSH_HOST"],
              let user = env["TESSERA_SSH_USER"],
              let targetHost = env["TESSERA_SSH_TARGET_HOST"] else {
            throw XCTSkip("Set TESSERA_SSH_* env vars to run the SSH tunnel test")
        }
        let port = Int(env["TESSERA_SSH_PORT"] ?? "22") ?? 22
        let targetPort = Int(env["TESSERA_SSH_TARGET_PORT"] ?? "5432") ?? 5432

        let ssh = SSHConfig(host: host, port: port, username: user, authMethod: .password)
        let tunnel = SSHTunnel()
        let endpoint = try await tunnel.start(
            ssh: ssh, secrets: Secrets(sshPassword: env["TESSERA_SSH_PASSWORD"]),
            remoteHost: targetHost, remotePort: targetPort)
        defer { Task { await tunnel.stop() } }

        let profile = ConnectionProfile(
            name: "via-tunnel", kind: .postgres,
            host: targetHost, port: targetPort,
            database: env["TESSERA_SSH_PG_DB"] ?? "shop",
            username: env["TESSERA_SSH_PG_USER"] ?? "tessera",
            tlsMode: .disable)
        let secrets = Secrets(databasePassword: env["TESSERA_SSH_PG_PASSWORD"] ?? "tessera")

        let driver = PostgresDriver()
        try await driver.connect(profile: profile, secrets: secrets, endpoint: endpoint)
        defer { Task { await driver.close() } }

        let result = try await driver.execute("SELECT 1 AS one")
        XCTAssertEqual(result.rows.first?.first?.text, "1")
    }
}
