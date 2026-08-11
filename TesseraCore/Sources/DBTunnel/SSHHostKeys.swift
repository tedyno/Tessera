import Foundation
import Crypto

/// Host-key trust for the SSH tunnel: helpers shared by the known-hosts parser,
/// the TOFU store, and the tunnel's validator.
public enum SSHHostKeys {
    /// OpenSSH-style fingerprint of a wire-format public-key blob:
    /// `SHA256:` + unpadded base64.
    public static func fingerprint(ofBlob blob: Data) -> String {
        let digest = SHA256.hash(data: blob)
        let base64 = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return "SHA256:" + base64
    }

    /// The algorithm name a key blob leads with (`ssh-ed25519`, `ssh-rsa`, …) —
    /// the wire format starts with a length-prefixed ASCII string.
    public static func algorithm(ofBlob blob: Data) -> String? {
        guard blob.count >= 4 else { return nil }
        let length = blob.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= 64, blob.count >= 4 + length else { return nil }
        return String(data: Data(blob.dropFirst(4).prefix(length)), encoding: .ascii)
    }

    /// How OpenSSH spells a host in `known_hosts`: bare for port 22,
    /// `[host]:port` otherwise.
    public static func hostToken(host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }
}

/// The SSH server presented a key that contradicts what we trust for that host —
/// the one situation that must stop the connection and reach the user verbatim.
public struct SSHHostKeyMismatchError: Error, Sendable {
    public let host: String
    public let port: Int
    /// Fingerprint we trusted (from the TOFU store or `known_hosts`).
    public let expectedFingerprint: String
    /// Fingerprint the server presented now.
    public let presentedFingerprint: String
    public let presentedAlgorithm: String
    /// Wire-format blob of the presented key, base64 — what "Trust new key" stores.
    public let presentedKeyBase64: String

    public init(host: String, port: Int, expectedFingerprint: String,
                presentedFingerprint: String, presentedAlgorithm: String,
                presentedKeyBase64: String) {
        self.host = host
        self.port = port
        self.expectedFingerprint = expectedFingerprint
        self.presentedFingerprint = presentedFingerprint
        self.presentedAlgorithm = presentedAlgorithm
        self.presentedKeyBase64 = presentedKeyBase64
    }
}

/// Read-only view of `~/.ssh/known_hosts`: a host the user already trusts via
/// plain `ssh` should connect without a fresh TOFU entry. Supports plain,
/// `[host]:port`, globbed (`*`/`?`), negated (`!`) and hashed (`|1|…`) host
/// patterns; `@revoked` / `@cert-authority` lines are skipped (those hosts fall
/// through to the TOFU store).
public struct SSHKnownHosts: Sendable {
    public enum Verdict: Equatable, Sendable {
        /// An entry matches host and key exactly.
        case trusted
        /// An entry matches the host and algorithm but carries a different key.
        case mismatch(expectedFingerprint: String)
        /// No entry applies to this host.
        case unknown
    }

    private struct Entry {
        var patterns: [String]
        var algorithm: String
        var keyBase64: String
    }

    private var entries: [Entry] = []

    public init(text: String) {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("@") else { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3 else { continue }
            entries.append(Entry(patterns: fields[0].split(separator: ",").map(String.init),
                                 algorithm: String(fields[1]),
                                 keyBase64: String(fields[2])))
        }
    }

    /// Loads the user's default known-hosts file; missing or unreadable files
    /// just mean an empty list.
    public static func loadDefault() -> SSHKnownHosts {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/known_hosts")
        return SSHKnownHosts(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    /// What the file says about `host:port` presenting `keyBase64`.
    public func evaluate(host: String, port: Int, algorithm: String,
                         keyBase64: String) -> Verdict {
        let token = SSHHostKeys.hostToken(host: host, port: port)
        var sawSameAlgorithm: String?
        for entry in entries where Self.matches(patterns: entry.patterns, hostToken: token) {
            if entry.keyBase64 == keyBase64 { return .trusted }
            if entry.algorithm == algorithm, sawSameAlgorithm == nil {
                sawSameAlgorithm = entry.keyBase64
            }
        }
        if let other = sawSameAlgorithm, let blob = Data(base64Encoded: other) {
            return .mismatch(expectedFingerprint: SSHHostKeys.fingerprint(ofBlob: blob))
        }
        return .unknown
    }

    /// OpenSSH pattern-list semantics: a negated match vetoes the whole line;
    /// otherwise any positive match applies. Hashed patterns compare
    /// HMAC-SHA1(salt, host-token).
    private static func matches(patterns: [String], hostToken: String) -> Bool {
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if matchesOne(String(pattern.dropFirst()), hostToken) { return false }
            } else if matchesOne(pattern, hostToken) {
                matched = true
            }
        }
        return matched
    }

    private static func matchesOne(_ pattern: String, _ hostToken: String) -> Bool {
        if pattern.hasPrefix("|1|") {
            let parts = pattern.split(separator: "|")
            guard parts.count == 3,
                  let salt = Data(base64Encoded: String(parts[1])),
                  let expected = Data(base64Encoded: String(parts[2])) else { return false }
            let mac = HMAC<Insecure.SHA1>.authenticationCode(
                for: Data(hostToken.utf8), using: SymmetricKey(data: salt))
            return Data(mac) == expected
        }
        if pattern.contains("*") || pattern.contains("?") {
            let escaped = NSRegularExpression.escapedPattern(for: pattern)
                .replacingOccurrences(of: "\\*", with: ".*")
                .replacingOccurrences(of: "\\?", with: ".")
            return hostToken.range(of: "^\(escaped)$",
                                   options: [.regularExpression, .caseInsensitive]) != nil
        }
        return pattern.caseInsensitiveCompare(hostToken) == .orderedSame
    }
}

/// One remembered host key.
public struct SSHHostKeyRecord: Codable, Sendable, Equatable {
    public var algorithm: String
    public var keyBase64: String
    public var firstSeen: Date

    public var fingerprint: String {
        Data(base64Encoded: keyBase64).map { SSHHostKeys.fingerprint(ofBlob: $0) } ?? ""
    }

    public init(algorithm: String, keyBase64: String, firstSeen: Date) {
        self.algorithm = algorithm
        self.keyBase64 = keyBase64
        self.firstSeen = firstSeen
    }
}

/// Trust-on-first-use store: `host:port` → the key seen on first connect, as a
/// small JSON file. First use records silently (like ssh's default accept); a
/// later different key makes the tunnel fail with `SSHHostKeyMismatchError`,
/// and "Trust new key" calls `replace` deliberately. Fingerprints aren't
/// secrets, so this lives beside the other persisted JSON, not in the Keychain.
public struct SSHHostKeyStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultURL(
        bundleID: String = "io.github.tedyno.tessera",
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ssh-host-keys.json")
    }

    /// The default store, degrading to a temporary file if Application Support
    /// is unavailable (trust then just doesn't persist across launches).
    public static func standard() -> SSHHostKeyStore {
        SSHHostKeyStore(fileURL: (try? defaultURL())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("tessera-ssh-host-keys.json"))
    }

    public func storedKey(host: String, port: Int) -> SSHHostKeyRecord? {
        load()[key(host, port)]
    }

    /// Records a first-use key; never overwrites an existing record (replacing
    /// a contradicted key must be the user's explicit `replace`).
    public func record(host: String, port: Int, algorithm: String, keyBase64: String) {
        var all = load()
        guard all[key(host, port)] == nil else { return }
        all[key(host, port)] = SSHHostKeyRecord(algorithm: algorithm, keyBase64: keyBase64,
                                                firstSeen: Date())
        save(all)
    }

    /// Deliberately trusts a new key for the host (the mismatch dialog's action).
    public func replace(host: String, port: Int, algorithm: String, keyBase64: String) {
        var all = load()
        all[key(host, port)] = SSHHostKeyRecord(algorithm: algorithm, keyBase64: keyBase64,
                                                firstSeen: Date())
        save(all)
    }

    private func key(_ host: String, _ port: Int) -> String { "\(host.lowercased()):\(port)" }

    private func load() -> [String: SSHHostKeyRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: SSHHostKeyRecord].self, from: data)) ?? [:]
    }

    private func save(_ all: [String: SSHHostKeyRecord]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(all) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
