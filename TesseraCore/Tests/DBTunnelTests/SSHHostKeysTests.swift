import XCTest
import Crypto
@testable import DBTunnel

final class SSHHostKeysTests: XCTestCase {

    /// A fake wire-format blob: length-prefixed algorithm string + payload.
    private func blob(algorithm: String, payload: [UInt8] = [1, 2, 3, 4]) -> Data {
        var data = Data()
        let name = Data(algorithm.utf8)
        data.append(contentsOf: [0, 0, 0, UInt8(name.count)])
        data.append(name)
        data.append(contentsOf: payload)
        return data
    }

    // MARK: Helpers

    func testAlgorithmReadsLeadingSSHString() {
        XCTAssertEqual(SSHHostKeys.algorithm(ofBlob: blob(algorithm: "ssh-ed25519")), "ssh-ed25519")
        XCTAssertNil(SSHHostKeys.algorithm(ofBlob: Data([0, 0])))
    }

    func testFingerprintMatchesOpenSSHShape() {
        let fingerprint = SSHHostKeys.fingerprint(ofBlob: blob(algorithm: "ssh-ed25519"))
        XCTAssertTrue(fingerprint.hasPrefix("SHA256:"))
        XCTAssertFalse(fingerprint.contains("="), "OpenSSH strips base64 padding")
    }

    func testHostToken() {
        XCTAssertEqual(SSHHostKeys.hostToken(host: "db.example.com", port: 22), "db.example.com")
        XCTAssertEqual(SSHHostKeys.hostToken(host: "db.example.com", port: 2222),
                       "[db.example.com]:2222")
    }

    // MARK: known_hosts

    private func knownHosts(_ lines: [String]) -> SSHKnownHosts {
        SSHKnownHosts(text: lines.joined(separator: "\n"))
    }

    func testPlainEntryTrustsExactKey() {
        let key = blob(algorithm: "ssh-ed25519").base64EncodedString()
        let hosts = knownHosts(["db.example.com ssh-ed25519 \(key) comment"])
        XCTAssertEqual(hosts.evaluate(host: "db.example.com", port: 22,
                                      algorithm: "ssh-ed25519", keyBase64: key), .trusted)
        XCTAssertEqual(hosts.evaluate(host: "other.example.com", port: 22,
                                      algorithm: "ssh-ed25519", keyBase64: key), .unknown)
    }

    func testSameAlgorithmDifferentKeyIsMismatch() {
        let trusted = blob(algorithm: "ssh-ed25519", payload: [9, 9, 9])
        let presented = blob(algorithm: "ssh-ed25519", payload: [1, 1, 1])
        let hosts = knownHosts(["db.example.com ssh-ed25519 \(trusted.base64EncodedString())"])
        XCTAssertEqual(
            hosts.evaluate(host: "db.example.com", port: 22, algorithm: "ssh-ed25519",
                           keyBase64: presented.base64EncodedString()),
            .mismatch(expectedFingerprint: SSHHostKeys.fingerprint(ofBlob: trusted)))
    }

    func testDifferentAlgorithmForSameHostIsUnknown() {
        // The server may present ed25519 while the file only knows its RSA key —
        // that is not evidence of an attack.
        let rsa = blob(algorithm: "ssh-rsa").base64EncodedString()
        let hosts = knownHosts(["db.example.com ssh-rsa \(rsa)"])
        let presented = blob(algorithm: "ssh-ed25519").base64EncodedString()
        XCTAssertEqual(hosts.evaluate(host: "db.example.com", port: 22,
                                      algorithm: "ssh-ed25519", keyBase64: presented), .unknown)
    }

    func testPortSpellingAndCommaListAndGlob() {
        let key = blob(algorithm: "ssh-ed25519").base64EncodedString()
        let hosts = knownHosts([
            "[db.example.com]:2222,10.0.0.5 ssh-ed25519 \(key)",
            "*.internal ssh-ed25519 \(key)",
        ])
        XCTAssertEqual(hosts.evaluate(host: "db.example.com", port: 2222,
                                      algorithm: "ssh-ed25519", keyBase64: key), .trusted)
        XCTAssertEqual(hosts.evaluate(host: "db.example.com", port: 22,
                                      algorithm: "ssh-ed25519", keyBase64: key), .unknown)
        XCTAssertEqual(hosts.evaluate(host: "10.0.0.5", port: 22,
                                      algorithm: "ssh-ed25519", keyBase64: key), .trusted)
        XCTAssertEqual(hosts.evaluate(host: "pg.internal", port: 22,
                                      algorithm: "ssh-ed25519", keyBase64: key), .trusted)
    }

    func testNegatedPatternVetoesTheLine() {
        let key = blob(algorithm: "ssh-ed25519").base64EncodedString()
        let hosts = knownHosts(["*.internal,!bad.internal ssh-ed25519 \(key)"])
        XCTAssertEqual(hosts.evaluate(host: "good.internal", port: 22,
                                      algorithm: "ssh-ed25519", keyBase64: key), .trusted)
        XCTAssertEqual(hosts.evaluate(host: "bad.internal", port: 22,
                                      algorithm: "ssh-ed25519", keyBase64: key), .unknown)
    }

    func testHashedEntryMatchesViaHMAC() {
        let key = blob(algorithm: "ssh-ed25519").base64EncodedString()
        let salt = Data((0..<20).map { UInt8($0) })
        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data("db.example.com".utf8), using: SymmetricKey(data: salt))
        let pattern = "|1|\(salt.base64EncodedString())|\(Data(mac).base64EncodedString())"
        let hosts = knownHosts(["\(pattern) ssh-ed25519 \(key)"])
        XCTAssertEqual(hosts.evaluate(host: "db.example.com", port: 22,
                                      algorithm: "ssh-ed25519", keyBase64: key), .trusted)
        XCTAssertEqual(hosts.evaluate(host: "other.example.com", port: 22,
                                      algorithm: "ssh-ed25519", keyBase64: key), .unknown)
    }

    func testCommentsAndMarkersAreSkipped() {
        let key = blob(algorithm: "ssh-ed25519").base64EncodedString()
        let hosts = knownHosts([
            "# a comment",
            "@revoked db.example.com ssh-ed25519 \(key)",
            "",
        ])
        XCTAssertEqual(hosts.evaluate(host: "db.example.com", port: 22,
                                      algorithm: "ssh-ed25519", keyBase64: key), .unknown)
    }

    // MARK: TOFU store

    private func temporaryStore() -> SSHHostKeyStore {
        SSHHostKeyStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("hostkeys-\(UUID().uuidString).json"))
    }

    func testRecordThenReadBack() {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        XCTAssertNil(store.storedKey(host: "db.example.com", port: 22))
        store.record(host: "db.example.com", port: 22, algorithm: "ssh-ed25519", keyBase64: "AAAA")
        let record = store.storedKey(host: "DB.example.com", port: 22)
        XCTAssertEqual(record?.keyBase64, "AAAA", "host lookup is case-insensitive")
        XCTAssertNil(store.storedKey(host: "db.example.com", port: 2222),
                     "a different port is a different endpoint")
    }

    func testRecordNeverOverwritesButReplaceDoes() {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        store.record(host: "h", port: 22, algorithm: "ssh-ed25519", keyBase64: "OLD")
        store.record(host: "h", port: 22, algorithm: "ssh-ed25519", keyBase64: "NEW")
        XCTAssertEqual(store.storedKey(host: "h", port: 22)?.keyBase64, "OLD",
                       "first-use recording must not silently overwrite")
        store.replace(host: "h", port: 22, algorithm: "ssh-rsa", keyBase64: "NEW")
        XCTAssertEqual(store.storedKey(host: "h", port: 22)?.keyBase64, "NEW")
    }
}
