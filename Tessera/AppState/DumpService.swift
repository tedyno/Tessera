import Foundation
import DBKit

/// Runs the external `pg_dump` / `mysqldump` binaries. Locates them (honouring a
/// user override), reads their version, and streams a dump to a file. The unsigned,
/// un-sandboxed build is free to spawn processes.
@MainActor
final class DumpService {

    /// Handle for stopping a dump or restore that is already under way. The service
    /// registers each process it spawns; cancelling terminates them, and cancelling
    /// before they start stops them from starting at all — otherwise a Stop pressed
    /// in the split second before `run()` would be silently ignored.
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var processes: [Process] = []
        private var cancelled = false

        init() {}

        var isCancelled: Bool { lock.withLock { cancelled } }

        func cancel() {
            let running: [Process] = lock.withLock {
                cancelled = true
                return processes
            }
            for process in running where process.isRunning { process.terminate() }
        }

        /// False means "already cancelled, don't start this".
        func register(_ process: Process) -> Bool {
            lock.withLock {
                guard !cancelled else { return false }
                processes.append(process)
                return true
            }
        }
    }

    /// Resolves the binary path: an explicit override if it's executable, otherwise
    /// the first match on `$PATH` and the known install locations.
    func locate(kind: DatabaseKind, override: String?) -> String? {
        if let override, !override.isEmpty, FileManager.default.isExecutableFile(atPath: override) { return override }
        return candidateBinaries(named: DumpTool.binaryName(for: kind), engine: kind).first
    }

    /// Picks the best binary for a server of `serverMajor`: a valid manual override
    /// wins; otherwise, among all installed binaries, the one whose major version
    /// matches the server (or the lowest that is ≥ it, since e.g. pg_dump must be at
    /// least as new as the server). Falls back to the newest, then the first found.
    func locateBest(kind: DatabaseKind, serverMajor: Int?, override: String?) async -> String? {
        await locateBest(named: DumpTool.binaryName(for: kind), engine: kind,
                         serverMajor: serverMajor, override: override)
    }

    /// Same version-aware search, for any client binary (pg_dump, psql, pg_restore, mysql…).
    func locateBest(named name: String, engine: DatabaseKind,
                    serverMajor: Int?, override: String?) async -> String? {
        if let override, !override.isEmpty, FileManager.default.isExecutableFile(atPath: override) { return override }
        var candidates = candidateBinaries(named: name, engine: engine)
        if candidates.isEmpty {
            // MariaDB installs mariadb-dump/mariadb, but the plain MySQL clients
            // speak the same protocol — whichever the user has works.
            for fallback in Self.equivalentBinaries[name] ?? [] {
                candidates = candidateBinaries(named: fallback, engine: engine)
                if !candidates.isEmpty { break }
            }
        }
        guard candidates.count > 1, let serverMajor else { return candidates.first }

        var versioned: [(path: String, major: Int)] = []
        for path in candidates {
            if let output = await version(binaryPath: path), let major = DumpTool.majorVersion(output) {
                versioned.append((path, major))
            }
        }
        if let exact = versioned.first(where: { $0.major == serverMajor }) { return exact.path }
        if let atLeast = versioned.filter({ $0.major >= serverMajor }).min(by: { $0.major < $1.major }) {
            return atLeast.path
        }
        if let newest = versioned.max(by: { $0.major < $1.major }) { return newest.path }
        return candidates.first
    }

    /// Interchangeable client binaries, tried in order when the preferred one is
    /// missing (MariaDB ↔ MySQL clients are protocol- and argument-compatible).
    private static let equivalentBinaries: [String: [String]] = [
        "mariadb-dump": ["mysqldump"],
        "mariadb": ["mysql"],
    ]

    /// Every installed copy of the binary: `$PATH`, the known dirs, and versioned
    /// Homebrew formulae (`postgresql@16`, `libpq`, `mysql@8`, …) and Postgres.app.
    private func candidateBinaries(named name: String, engine: DatabaseKind) -> [String] {
        let fileManager = FileManager.default
        var paths: [String] = []
        func add(dir: String) {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate), !paths.contains(candidate) {
                paths.append(candidate)
            }
        }

        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        (pathDirectories + DumpTool.searchDirectories).forEach { add(dir: $0) }

        // Versioned / keg-only Homebrew formulae under opt/.
        let formulaPrefixes: [String] = switch engine {
        case .postgres: ["postgresql", "libpq"]
        case .mysql: ["mysql"]
        case .mariadb: ["mariadb", "mysql"]   // either client dumps MariaDB fine
        case .sqlite: []                      // no external tool
        case .redis: []                       // no SQL dump tool
        }
        for optRoot in ["/opt/homebrew/opt", "/usr/local/opt"] {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: optRoot) else { continue }
            for entry in entries where formulaPrefixes.contains(where: { entry.hasPrefix($0) }) {
                add(dir: (optRoot as NSString).appendingPathComponent(entry + "/bin"))
            }
        }
        // Postgres.app bundles one bin dir per major version.
        if engine == .postgres {
            let versionsRoot = "/Applications/Postgres.app/Contents/Versions"
            if let versions = try? fileManager.contentsOfDirectory(atPath: versionsRoot) {
                for version in versions {
                    add(dir: (versionsRoot as NSString).appendingPathComponent(version + "/bin"))
                }
            }
        }
        return paths
    }

    /// The binary's `--version` string (e.g. "pg_dump (PostgreSQL) 16.2"), or nil.
    func version(binaryPath: String) async -> String? {
        await run(binaryPath: binaryPath, arguments: ["--version"], environment: [:], output: nil).stdout?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct DumpResult: Sendable {
        let success: Bool
        let message: String
        /// The user stopped it — an outcome to report as such, not a failure.
        var cancelled = false
    }

    /// Streams a dump to `outputURL`, optionally piped through gzip. Returns success
    /// plus any stderr on failure.
    func dump(kind: DatabaseKind, binaryPath: String, host: String, port: Int, user: String,
              database: String, password: String?, options: DumpOptions, outputURL: URL,
              cancellation: Cancellation? = nil) async -> DumpResult {
        let arguments = DumpTool.arguments(kind: kind, host: host, port: port, user: user,
                                           database: database, options: options)
        let extraEnvironment = DumpTool.environment(kind: kind, password: password)
        let useGzip = options.gzip

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let dumpProcess = Process()
                dumpProcess.executableURL = URL(fileURLWithPath: binaryPath)
                dumpProcess.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                for (key, value) in extraEnvironment { environment[key] = value }
                dumpProcess.environment = environment

                let errorPipe = Pipe()
                dumpProcess.standardError = errorPipe

                FileManager.default.createFile(atPath: outputURL.path, contents: nil)
                guard let outputHandle = try? FileHandle(forWritingTo: outputURL) else {
                    continuation.resume(returning: DumpResult(
                        success: false, message: "Cannot write to \(outputURL.path)"))
                    return
                }

                // Optionally: dump | gzip -c > file.gz
                var gzipProcess: Process?
                var gzipPipe: Pipe?
                if useGzip {
                    let pipe = Pipe()
                    gzipPipe = pipe
                    dumpProcess.standardOutput = pipe
                    let gzip = Process()
                    gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
                    gzip.arguments = ["-c"]
                    gzip.standardInput = pipe
                    gzip.standardOutput = outputHandle
                    gzipProcess = gzip
                } else {
                    dumpProcess.standardOutput = outputHandle
                }

                // Registered before starting: a Stop that lands in the gap between
                // these two lines must still take effect.
                let registered = [dumpProcess, gzipProcess].compactMap { $0 }
                    .allSatisfy { cancellation?.register($0) ?? true }
                guard registered else {
                    try? outputHandle.close()
                    continuation.resume(returning: DumpResult(
                        success: false, message: "", cancelled: true))
                    return
                }
                do {
                    try gzipProcess?.run()
                    try dumpProcess.run()
                } catch {
                    try? outputHandle.close()
                    continuation.resume(returning: DumpResult(
                        success: false, message: String(describing: error)))
                    return
                }
                // Drop our copy of the write end so gzip sees EOF when the dump ends.
                try? gzipPipe?.fileHandleForWriting.close()

                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                dumpProcess.waitUntilExit()
                gzipProcess?.waitUntilExit()
                try? outputHandle.close()

                let stderr = String(data: errorData, encoding: .utf8) ?? ""
                let gzipStatus = gzipProcess?.terminationStatus ?? 0
                if cancellation?.isCancelled == true {
                    // Terminated on purpose; the half-written file is the caller's to
                    // clean up, and the tool's dying words are not an error report.
                    continuation.resume(returning: DumpResult(
                        success: false, message: "", cancelled: true))
                } else if dumpProcess.terminationStatus == 0, gzipStatus == 0 {
                    continuation.resume(returning: DumpResult(success: true, message: stderr))
                } else {
                    let message = stderr.isEmpty
                        ? "Exit code \(dumpProcess.terminationStatus == 0 ? gzipStatus : dumpProcess.terminationStatus)"
                        : stderr
                    continuation.resume(returning: DumpResult(success: false, message: message))
                }
            }
        }
    }

    /// Restores a dump. Plain files are handed to the tool (psql `-f`, pg_restore) or
    /// piped on stdin (mysql); gzipped files stream through `gzip -dc`.
    func restore(engine: DatabaseKind, binaryPath: String, host: String, port: Int, user: String,
                 database: String, password: String?, input: RestoreInput, fileURL: URL,
                 options: RestoreOptions, cancellation: Cancellation? = nil) async -> DumpResult {
        let arguments = RestoreTool.arguments(engine: engine, host: host, port: port, user: user,
                                              database: database, input: input,
                                              filePath: fileURL.path, options: options)
        let extraEnvironment = RestoreTool.environment(engine: engine, password: password)
        // psql/pg_restore open the file themselves; everything else reads stdin.
        let toolOpensFile = engine == .postgres && !input.readsStandardInput

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let restoreProcess = Process()
                restoreProcess.executableURL = URL(fileURLWithPath: binaryPath)
                restoreProcess.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                for (key, value) in extraEnvironment { environment[key] = value }
                restoreProcess.environment = environment

                let errorPipe = Pipe()
                restoreProcess.standardError = errorPipe
                // Discard stdout: psql prints a line per statement, and draining two
                // pipes one after the other deadlocks once the unread one fills up.
                restoreProcess.standardOutput = FileHandle.nullDevice

                var gunzipProcess: Process?
                var gunzipPipe: Pipe?
                var inputHandle: FileHandle?
                if !toolOpensFile {
                    if input == .gzippedSQL {
                        // gzip -dc file | tool
                        let pipe = Pipe()
                        gunzipPipe = pipe
                        let gunzip = Process()
                        gunzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
                        gunzip.arguments = ["-dc", fileURL.path]
                        gunzip.standardOutput = pipe
                        restoreProcess.standardInput = pipe
                        gunzipProcess = gunzip
                    } else if let handle = try? FileHandle(forReadingFrom: fileURL) {
                        inputHandle = handle
                        restoreProcess.standardInput = handle
                    } else {
                        continuation.resume(returning: DumpResult(
                            success: false, message: "Cannot read \(fileURL.path)"))
                        return
                    }
                }

                // See `dump`: registered before starting, so a Stop can't slip through.
                let registered = [restoreProcess, gunzipProcess].compactMap { $0 }
                    .allSatisfy { cancellation?.register($0) ?? true }
                guard registered else {
                    try? inputHandle?.close()
                    continuation.resume(returning: DumpResult(
                        success: false, message: "", cancelled: true))
                    return
                }
                do {
                    try gunzipProcess?.run()
                    try restoreProcess.run()
                } catch {
                    continuation.resume(returning: DumpResult(
                        success: false, message: String(describing: error)))
                    return
                }
                try? gunzipPipe?.fileHandleForWriting.close()

                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                restoreProcess.waitUntilExit()
                gunzipProcess?.waitUntilExit()
                try? inputHandle?.close()

                let stderr = String(data: errorData, encoding: .utf8) ?? ""
                if cancellation?.isCancelled == true {
                    // Stopped on purpose. Note the database keeps whatever the restore
                    // managed to apply — the caller says so, this only reports the fact.
                    continuation.resume(returning: DumpResult(
                        success: false, message: "", cancelled: true))
                } else if restoreProcess.terminationStatus == 0 {
                    continuation.resume(returning: DumpResult(success: true, message: stderr))
                } else {
                    continuation.resume(returning: DumpResult(
                        success: false,
                        message: stderr.isEmpty ? "Exit code \(restoreProcess.terminationStatus)" : stderr))
                }
            }
        }
    }

    // MARK: - Process runner

    private struct ProcessOutcome: Sendable { var exitCode: Int32; var stdout: String?; var stderr: String? }

    private func run(binaryPath: String, arguments: [String], environment: [String: String],
                     output: URL?) async -> ProcessOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binaryPath)
                process.arguments = arguments
                var env = ProcessInfo.processInfo.environment
                for (key, value) in environment { env[key] = value }
                process.environment = env

                let errorPipe = Pipe()
                process.standardError = errorPipe

                var stdoutPipe: Pipe?
                var outputHandle: FileHandle?
                if let output {
                    FileManager.default.createFile(atPath: output.path, contents: nil)
                    outputHandle = try? FileHandle(forWritingTo: output)
                    guard let outputHandle else {
                        continuation.resume(returning: ProcessOutcome(
                            exitCode: -1, stdout: nil, stderr: "Cannot write to \(output.path)"))
                        return
                    }
                    process.standardOutput = outputHandle
                } else {
                    let pipe = Pipe()
                    stdoutPipe = pipe
                    process.standardOutput = pipe
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ProcessOutcome(
                        exitCode: -1, stdout: nil, stderr: String(describing: error)))
                    return
                }
                // Read pipes before waiting to avoid deadlock on large output.
                let stdoutData = stdoutPipe?.fileHandleForReading.readDataToEndOfFile()
                let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                try? outputHandle?.close()
                continuation.resume(returning: ProcessOutcome(
                    exitCode: process.terminationStatus,
                    stdout: stdoutData.flatMap { String(data: $0, encoding: .utf8) },
                    stderr: String(data: stderrData, encoding: .utf8)))
            }
        }
    }
}
