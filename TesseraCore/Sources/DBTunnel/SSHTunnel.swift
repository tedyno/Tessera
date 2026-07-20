import Foundation
import DBKit
@preconcurrency import Citadel
import NIOCore
import NIOPosix
import NIOSSH
import Crypto

/// An SSH tunnel doing local port forwarding: connects to an SSH server, opens a
/// local listener on 127.0.0.1, and forwards each accepted connection through the
/// SSH server to `remoteHost:remotePort` via a direct-tcpip channel. The database
/// driver then connects to the returned local endpoint, unaware of SSH.
public actor SSHTunnel {
    private var client: SSHClient?
    private var serverChannel: Channel?

    // Shared singleton group so the tunnel never leaks its own event-loop threads.
    private var group: MultiThreadedEventLoopGroup { .singleton }

    public init() {}

    /// Establishes the tunnel and returns the local endpoint to connect to.
    public func start(
        ssh: SSHConfig,
        secrets: Secrets,
        remoteHost: String,
        remotePort: Int
    ) async throws -> NetworkEndpoint {
        await stop()

        // A profile may name a ~/.ssh/config alias instead of spelling everything out;
        // resolve it now so later edits to that file are picked up.
        let ssh = Self.applyingConfigAlias(ssh)

        let auth: SSHAuthenticationMethod
        switch ssh.authMethod {
        case .password:
            auth = .passwordBased(username: ssh.username, password: secrets.sshPassword ?? "")
        case .privateKey(let path):
            auth = try Self.privateKeyAuth(username: ssh.username, path: path,
                                           passphrase: secrets.sshPassphrase)
        }

        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: ssh.host,
                port: ssh.port,
                authenticationMethod: auth,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never)
        } catch {
            throw DatabaseError.connectionFailed("SSH connect failed: \(error)")
        }
        self.client = client

        let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 32)
            .childChannelInitializer { localChannel in
                // NIO only starts reading the child channel once this initializer
                // future completes, so the glue is guaranteed to be in place first.
                localChannel.eventLoop.makeFutureWithTask {
                    let remoteChannel = try await client.createDirectTCPIPChannel(
                        using: SSHChannelType.DirectTCPIP(
                            targetHost: remoteHost,
                            targetPort: remotePort,
                            originatorAddress: originator)
                    ) { sshChannel in
                        // The forwarder must be in place *before* the channel goes
                        // active: a server that speaks first (MySQL sends its greeting
                        // immediately) would otherwise have those bytes arrive at an
                        // empty pipeline and be dropped. Citadel already installs
                        // DataToBufferCodec, so this channel speaks plain ByteBuffer.
                        sshChannel.pipeline.addHandler(ForwardHandler(peer: localChannel))
                    }
                    // Only the local side is left to wire; the remote side is done above.
                    try await localChannel.pipeline.addHandler(ForwardHandler(peer: remoteChannel)).get()
                }
            }

        do {
            let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
            self.serverChannel = channel
            guard let port = channel.localAddress?.port else {
                throw DatabaseError.connectionFailed("SSH tunnel: no local port bound")
            }
            return NetworkEndpoint(host: "127.0.0.1", port: port)
        } catch {
            await stop()
            throw DatabaseError.connectionFailed("SSH tunnel bind failed: \(error)")
        }
    }

    public func stop() async {
        if let serverChannel { try? await serverChannel.close().get() }
        serverChannel = nil
        if let client { try? await client.close() }
        client = nil
    }

    /// Loads an OpenSSH private key from disk and builds the matching auth method.
    /// Supports ed25519 and RSA keys, encrypted ones via the stored passphrase.
    /// Fills a config-alias tunnel from `~/.ssh/config`. Anything the file doesn't
    /// specify falls back to the profile's own fields, then to ssh's own defaults
    /// (the login user, port 22), so a bare `Host` entry is enough.
    static func applyingConfigAlias(_ ssh: SSHConfig) -> SSHConfig {
        guard let alias = ssh.configAlias, !alias.isEmpty else { return ssh }
        let resolved = SSHConfigFile.resolve(alias, in: SSHConfigFile.loadDefault())
        var result = ssh
        result.host = resolved.hostName
        result.port = resolved.port ?? (ssh.port > 0 ? ssh.port : 22)
        result.username = resolved.user ?? (ssh.username.isEmpty ? NSUserName() : ssh.username)
        if let identityFile = resolved.identityFile {
            result.authMethod = .privateKey(path: identityFile)
        }
        return result
    }

    private static func privateKeyAuth(username: String, path: String,
                                       passphrase: String?) throws -> SSHAuthenticationMethod {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let key = try? String(contentsOf: url, encoding: .utf8) else {
            throw DatabaseError.connectionFailed("Cannot read the SSH private key at \(path)")
        }
        let decryptionKey = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }

        if let ed25519 = try? Curve25519.Signing.PrivateKey(sshEd25519: key, decryptionKey: decryptionKey) {
            return .ed25519(username: username, privateKey: ed25519)
        }
        if let rsa = try? Insecure.RSA.PrivateKey(sshRsa: key, decryptionKey: decryptionKey) {
            return .rsa(username: username, privateKey: rsa)
        }
        throw DatabaseError.connectionFailed(
            "Unsupported or encrypted SSH key at \(path). Supported: OpenSSH ed25519 and RSA"
            + (decryptionKey == nil ? " (add the passphrase if the key is encrypted)." : "."))
    }
}
