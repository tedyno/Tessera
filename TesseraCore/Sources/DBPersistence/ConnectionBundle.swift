import Foundation
import CommonCrypto
import CryptoKit
import DBKit

/// One profile's secrets inside a `ConnectionBundle`.
///
/// `Secrets` is deliberately not `Codable` so it can never reach disk by accident.
/// This type is the one sanctioned exception: it only ever exists inside a bundle's
/// plaintext, which is serialized solely to be encrypted by `ConnectionBundleFile`.
public struct BundledSecrets: Codable, Sendable, Equatable {
    public var databasePassword: String?
    public var sshPassword: String?
    public var sshPassphrase: String?

    public init(_ secrets: Secrets) {
        databasePassword = secrets.databasePassword
        sshPassword = secrets.sshPassword
        sshPassphrase = secrets.sshPassphrase
    }

    public var secrets: Secrets {
        Secrets(databasePassword: databasePassword, sshPassword: sshPassword,
                sshPassphrase: sshPassphrase)
    }

    public var isEmpty: Bool {
        databasePassword == nil && sshPassword == nil && sshPassphrase == nil
    }
}

/// Everything needed to recreate one Tessera's connections elsewhere: the organizer
/// tree, the profiles it points at, and their passwords. This is the plaintext of a
/// `.tessera` file.
public struct ConnectionBundle: Codable, Sendable, Equatable {
    public var exportedAt: Date
    public var organizer: OrganizerDocument
    public var profiles: [ConnectionProfile]
    /// Keyed by profile id (`uuidString`); profiles without a stored secret are absent.
    public var secrets: [String: BundledSecrets]

    public init(exportedAt: Date = Date(), organizer: OrganizerDocument,
                profiles: [ConnectionProfile], secrets: [UUID: Secrets]) {
        self.exportedAt = exportedAt
        self.organizer = organizer
        self.profiles = profiles
        var stored: [String: BundledSecrets] = [:]
        for (id, value) in secrets {
            let bundled = BundledSecrets(value)
            if !bundled.isEmpty { stored[id.uuidString] = bundled }
        }
        self.secrets = stored
    }

    public func secrets(for profileID: UUID) -> Secrets {
        secrets[profileID.uuidString]?.secrets ?? Secrets()
    }
}

public enum ConnectionBundleError: Error, Sendable, Equatable {
    /// Not a Tessera connections file at all.
    case notABundle
    /// Written by a newer Tessera with a format this build can't read.
    case unsupportedVersion(Int)
    /// The password doesn't open the file (or the file was tampered with — AES-GCM
    /// can't tell the two apart, and neither should the user need to).
    case wrongPassword
    /// Decrypted, but the contents aren't a bundle.
    case damaged
}

/// The on-disk `.tessera` format: a small JSON envelope around an AES-256-GCM box.
/// The key comes from the password via PBKDF2-HMAC-SHA256 with a random salt, so the
/// same password never yields the same key twice.
public enum ConnectionBundleFile {
    public static let fileExtension = "tessera"
    public static let formatName = "tessera-connections"
    public static let currentVersion = 1
    /// OWASP's 2023 figure for PBKDF2-HMAC-SHA256. The generated password is strong
    /// on its own; this only matters if someone types a weak one.
    public static let defaultIterations = 600_000
    /// What a file may ask for. The count comes from the file itself, so an absurd
    /// one would stall the import (or overflow the `UInt32` CommonCrypto takes).
    static let allowedIterations = 1...10_000_000

    private struct Envelope: Codable {
        var format: String
        var version: Int
        var kdf: String
        var iterations: Int
        var salt: Data
        var cipher: String
        var sealed: Data
    }

    /// Binds the ciphertext to the format and version so neither can be swapped out.
    private static func associatedData(version: Int) -> Data {
        Data("\(formatName)/\(version)".utf8)
    }

    public static func seal(_ bundle: ConnectionBundle, password: String,
                            iterations: Int = defaultIterations) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(bundle)

        var salt = Data(count: 16)
        salt.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let key = try deriveKey(password: ExportPassword.normalized(password), salt: salt,
                                iterations: iterations)
        let box = try AES.GCM.seal(plaintext, using: key,
                                   authenticating: associatedData(version: currentVersion))
        guard let combined = box.combined else { throw ConnectionBundleError.damaged }

        let envelope = Envelope(format: formatName, version: currentVersion,
                                kdf: "pbkdf2-sha256", iterations: iterations, salt: salt,
                                cipher: "aes-256-gcm", sealed: combined)
        let out = JSONEncoder()
        out.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try out.encode(envelope)
    }

    /// Seals `bundle` and writes it owner-readable only: it holds every password.
    public static func write(_ bundle: ConnectionBundle, password: String, to url: URL) throws {
        try PrivateFile.write(seal(bundle, password: password), to: url)
    }

    public static func open(_ data: Data, password: String) throws -> ConnectionBundle {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.format == formatName else { throw ConnectionBundleError.notABundle }
        guard envelope.version <= currentVersion else {
            throw ConnectionBundleError.unsupportedVersion(envelope.version)
        }
        guard envelope.kdf == "pbkdf2-sha256", envelope.cipher == "aes-256-gcm",
              allowedIterations.contains(envelope.iterations) else {
            throw ConnectionBundleError.notABundle
        }

        let key = try deriveKey(password: ExportPassword.normalized(password),
                                salt: envelope.salt, iterations: envelope.iterations)
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.sealed)
            plaintext = try AES.GCM.open(box, using: key,
                                         authenticating: associatedData(version: envelope.version))
        } catch {
            throw ConnectionBundleError.wrongPassword
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let bundle = try? decoder.decode(ConnectionBundle.self, from: plaintext) else {
            throw ConnectionBundleError.damaged
        }
        return bundle
    }

    static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let passwordBytes = Array(password.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes.map { CChar(bitPattern: $0) }, passwordBytes.count,
                saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                &derived, derived.count)
        }
        guard status == kCCSuccess else { throw ConnectionBundleError.damaged }
        return SymmetricKey(data: derived)
    }
}

/// The password Tessera generates for each export. Nobody picks it, so it can be
/// long and random; it's grouped so it survives being read aloud or retyped.
public enum ExportPassword {
    /// Lowercase letters and digits minus the look-alikes (0/o, 1/l/i).
    public static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
    public static let groupCount = 6
    public static let groupLength = 5

    /// Six groups of five: ~148 bits of entropy.
    public static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<groupCount).map { _ in
            String((0..<groupLength).map { _ in alphabet.randomElement(using: &rng)! })
        }.joined(separator: "-")
    }

    /// What the user typed or pasted, as it was generated: stray whitespace (a
    /// trailing newline from the clipboard) and capitals don't make it wrong.
    public static func normalized(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
