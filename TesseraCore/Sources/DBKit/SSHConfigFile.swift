import Foundation

/// One `Host` block from an OpenSSH client config, reduced to the directives the
/// tunnel needs.
public struct SSHConfigBlock: Equatable, Sendable {
    public var patterns: [String]
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var identityFile: String?

    public init(patterns: [String], hostName: String? = nil, user: String? = nil,
                port: Int? = nil, identityFile: String? = nil) {
        self.patterns = patterns
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
    }
}

/// The settings an alias resolves to.
public struct SSHConfigResolution: Equatable, Sendable {
    public var hostName: String
    public var user: String?
    public var port: Int?
    public var identityFile: String?

    public init(hostName: String, user: String? = nil, port: Int? = nil, identityFile: String? = nil) {
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
    }
}

/// Reads `~/.ssh/config` so a connection can name a host alias instead of repeating
/// its hostname, user, port, and key. Parsing is pure (and unit-tested); reading
/// files is confined to `loadDefault`.
public enum SSHConfigFile {
    public static let defaultPath = "~/.ssh/config"

    // MARK: Parsing

    /// Parses config text into its `Host` blocks, in file order. `include` is called
    /// for each `Include` directive and returns the text of the files it names, so
    /// includes are expanded in place (OpenSSH reads them where they appear).
    public static func parse(_ text: String,
                             include: (String) -> [String] = { _ in [] }) -> [SSHConfigBlock] {
        var blocks: [SSHConfigBlock] = []
        var current: SSHConfigBlock?

        func flush() {
            if let block = current { blocks.append(block) }
            current = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let (keyword, value) = directive(line) else { continue }

            switch keyword {
            case "host":
                flush()
                current = SSHConfigBlock(patterns: value.split(separator: " ").map(String.init))
            case "include":
                // Included text is parsed with the same rules and spliced in.
                for path in value.split(separator: " ").map(String.init) {
                    for included in include(path) {
                        flush()
                        blocks.append(contentsOf: parse(included, include: include))
                    }
                }
            case "hostname":
                current?.hostName = value
            case "user":
                current?.user = value
            case "port":
                current?.port = Int(value)
            case "identityfile":
                // Only the first IdentityFile is used; later ones are alternatives.
                if current?.identityFile == nil { current?.identityFile = value }
            default:
                continue   // Match, ProxyJump, ciphers… are not our business
            }
        }
        flush()
        return blocks
    }

    /// Splits `Keyword value` (or `Keyword = value`), lowercasing the keyword and
    /// stripping surrounding quotes from the value.
    private static func directive(_ line: String) -> (String, String)? {
        let separators = CharacterSet(charactersIn: " \t=")
        let parts = line.components(separatedBy: separators).filter { !$0.isEmpty }
        guard let keyword = parts.first, parts.count > 1 else { return nil }
        let value = parts.dropFirst().joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return (keyword.lowercased(), value)
    }

    // MARK: Resolution

    /// Aliases worth offering in a picker: literal names, no wildcards, no duplicates.
    public static func aliases(in blocks: [SSHConfigBlock]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for block in blocks {
            for pattern in block.patterns
            where !pattern.contains("*") && !pattern.contains("?") && !pattern.hasPrefix("!") {
                if seen.insert(pattern).inserted { result.append(pattern) }
            }
        }
        return result
    }

    /// Resolves `alias` against the blocks. OpenSSH uses the **first** value obtained
    /// for each keyword, so earlier blocks win and later ones only fill gaps. An alias
    /// with no `HostName` resolves to itself, exactly as ssh does.
    public static func resolve(_ alias: String, in blocks: [SSHConfigBlock]) -> SSHConfigResolution {
        var resolution = SSHConfigResolution(hostName: alias)
        var haveHostName = false
        for block in blocks where matches(alias, patterns: block.patterns) {
            if !haveHostName, let hostName = block.hostName {
                resolution.hostName = hostName
                haveHostName = true
            }
            if resolution.user == nil { resolution.user = block.user }
            if resolution.port == nil { resolution.port = block.port }
            if resolution.identityFile == nil { resolution.identityFile = block.identityFile }
        }
        return resolution
    }

    /// True when `alias` matches the block's pattern list: at least one positive
    /// pattern matches and no negated (`!`) pattern does.
    public static func matches(_ alias: String, patterns: [String]) -> Bool {
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if glob(String(pattern.dropFirst()), matches: alias) { return false }
            } else if glob(pattern, matches: alias) {
                matched = true
            }
        }
        return matched
    }

    /// Shell-style match supporting `*` (any run) and `?` (one character).
    public static func glob(_ pattern: String, matches text: String) -> Bool {
        let p = Array(pattern), t = Array(text)
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1; ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = ti; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    // MARK: Loading

    /// Reads the user's config, expanding `Include` (paths are relative to `~/.ssh`
    /// and may contain a glob). Returns an empty list when there is no config.
    public static func loadDefault(fileManager: FileManager = .default) -> [SSHConfigBlock] {
        let root = (defaultPath as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: root, encoding: .utf8) else { return [] }
        return parse(text) { pattern in
            expand(include: pattern, fileManager: fileManager)
                .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        }
    }

    /// Resolves an `Include` pattern to concrete file paths.
    private static func expand(include pattern: String, fileManager: FileManager) -> [String] {
        let sshDirectory = ("~/.ssh" as NSString).expandingTildeInPath
        var path = (pattern as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = (sshDirectory as NSString).appendingPathComponent(path) }

        let directory = (path as NSString).deletingLastPathComponent
        let last = (path as NSString).lastPathComponent
        guard last.contains("*") || last.contains("?") else {
            return fileManager.fileExists(atPath: path) ? [path] : []
        }
        let entries = (try? fileManager.contentsOfDirectory(atPath: directory)) ?? []
        return entries
            .filter { glob(last, matches: $0) }
            .sorted()
            .map { (directory as NSString).appendingPathComponent($0) }
    }
}
