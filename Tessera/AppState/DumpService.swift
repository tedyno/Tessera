import Foundation
import DBKit

/// Runs the external `pg_dump` / `mysqldump` binaries. Locates them (honouring a
/// user override), reads their version, and streams a dump to a file. The unsigned,
/// un-sandboxed build is free to spawn processes.
@MainActor
final class DumpService {

    /// Resolves the binary path: an explicit override if it's executable, otherwise
    /// the first match on `$PATH` and the known install locations.
    func locate(kind: DatabaseKind, override: String?) -> String? {
        let fileManager = FileManager.default
        if let override, !override.isEmpty, fileManager.isExecutableFile(atPath: override) { return override }
        let name = DumpTool.binaryName(for: kind)
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        for directory in pathDirectories + DumpTool.searchDirectories {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The binary's `--version` string (e.g. "pg_dump (PostgreSQL) 16.2"), or nil.
    func version(binaryPath: String) async -> String? {
        await run(binaryPath: binaryPath, arguments: ["--version"], environment: [:], output: nil).stdout?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct DumpResult: Sendable { let success: Bool; let message: String }

    /// Streams a dump to `outputURL`; returns success plus any stderr on failure.
    func dump(kind: DatabaseKind, binaryPath: String, host: String, port: Int, user: String,
              database: String, password: String?, options: DumpOptions, outputURL: URL) async -> DumpResult {
        let arguments = DumpTool.arguments(kind: kind, host: host, port: port, user: user,
                                           database: database, options: options)
        let environment = DumpTool.environment(kind: kind, password: password)
        let result = await run(binaryPath: binaryPath, arguments: arguments,
                               environment: environment, output: outputURL)
        if result.exitCode == 0 {
            return DumpResult(success: true, message: result.stderr ?? "")
        }
        let message = (result.stderr?.isEmpty == false) ? result.stderr! : "Exit code \(result.exitCode)"
        return DumpResult(success: false, message: message)
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
