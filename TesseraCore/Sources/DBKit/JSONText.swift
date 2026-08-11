import Foundation

/// Whitespace-only JSON text tooling: a tokenizer with UTF-16 ranges (for syntax
/// highlighting) and formatters that pretty-print or minify by rearranging only the
/// whitespace *between* tokens — every lexeme is copied verbatim from the source.
/// Unlike `JSONSerialization`, a format → minify round trip can never change key
/// order, number spelling (`1.00`), or string escapes, so an untouched value
/// re-serializes byte-identically.
public enum JSONText {
    /// Beyond this the editor falls back to plain text — parity with `JSONTreeNode.parse`.
    public static let sizeLimit = 256_000

    /// Formatting bails out once the output grows past this, so a pathologically
    /// deep document (whose indentation is quadratic in depth) can't balloon.
    private static let outputLimit = 2_000_000

    public struct Token: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// A string in key position (before a `:` in an object).
            case objectKey
            case string
            case number
            case bool
            case null
            /// One of `{ } [ ] : ,`.
            case punctuation
        }

        public let kind: Kind
        /// UTF-16 offsets into the scanned text (ready for `NSTextStorage`).
        public let range: NSRange

        public init(kind: Kind, range: NSRange) {
            self.kind = kind
            self.range = range
        }
    }

    public struct ScanResult: Sendable {
        /// Tokens up to the first syntax error (all of them when `isValid`).
        public let tokens: [Token]
        /// The text is exactly one complete JSON value plus optional whitespace.
        public let isValid: Bool
        /// The root value starts an object or array — scalars aren't worth formatting.
        public let isContainer: Bool
    }

    /// Best-effort scan; nil only above `sizeLimit`. Invalid text still yields the
    /// tokens up to the error with `isValid == false`, so a document being edited
    /// keeps its tolerant highlighting.
    public static func scan(_ text: String) -> ScanResult? {
        let units = Array(text.utf16)
        guard units.count <= sizeLimit else { return nil }
        var scanner = Scanner(units: units)
        return scanner.scan()
    }

    /// The text re-indented one value per line, or nil when it isn't a complete
    /// JSON object/array (or would format beyond `outputLimit`).
    public static func prettyPrinted(_ text: String, indent: String = "  ") -> String? {
        guard let result = scan(text), result.isValid, result.isContainer else { return nil }
        let source = text as NSString
        let indentLength = indent.utf16.count
        var out = ""
        out.reserveCapacity(source.length + source.length / 2)
        var written = 0
        var depth = 0
        var index = 0
        while index < result.tokens.count {
            guard written <= outputLimit else { return nil }
            let token = result.tokens[index]
            let lexeme = source.substring(with: token.range)
            if token.kind == .punctuation {
                switch lexeme {
                case "{", "[":
                    out += lexeme
                    written += 1
                    // An empty container stays on one line.
                    if index + 1 < result.tokens.count,
                       result.tokens[index + 1].kind == .punctuation,
                       source.substring(with: result.tokens[index + 1].range) == matchingClose(of: lexeme) {
                        out += source.substring(with: result.tokens[index + 1].range)
                        written += 1
                        index += 1
                    } else {
                        depth += 1
                        newline(into: &out, depth: depth, indent: indent)
                        written += 1 + depth * indentLength
                    }
                case "}", "]":
                    depth -= 1
                    newline(into: &out, depth: depth, indent: indent)
                    out += lexeme
                    written += 2 + depth * indentLength
                case ",":
                    out += ","
                    newline(into: &out, depth: depth, indent: indent)
                    written += 2 + depth * indentLength
                default: // ":"
                    out += ": "
                    written += 2
                }
            } else {
                out += lexeme
                written += token.range.length
            }
            index += 1
        }
        return out
    }

    /// All lexemes with no whitespace between them, or nil when the text isn't a
    /// complete JSON object/array.
    public static func minified(_ text: String) -> String? {
        guard let result = scan(text), result.isValid, result.isContainer else { return nil }
        let source = text as NSString
        var out = ""
        out.reserveCapacity(source.length)
        for token in result.tokens {
            out += source.substring(with: token.range)
        }
        return out
    }

    /// Whether both texts are valid JSON built from the same lexeme sequence —
    /// i.e. they differ only in whitespace. Either side invalid counts as changed.
    public static func haveSameTokens(_ a: String, _ b: String) -> Bool {
        guard let scanA = scan(a), scanA.isValid,
              let scanB = scan(b), scanB.isValid,
              scanA.tokens.count == scanB.tokens.count else { return false }
        let sourceA = a as NSString
        let sourceB = b as NSString
        for (tokenA, tokenB) in zip(scanA.tokens, scanB.tokens) {
            guard tokenA.kind == tokenB.kind,
                  sourceA.substring(with: tokenA.range) == sourceB.substring(with: tokenB.range)
            else { return false }
        }
        return true
    }

    /// Whether the stored text is single-line. Inside a JSON string a raw newline
    /// is illegal (only the `\n` escape is), so any newline can only be formatting.
    /// Scalar-checked so a CRLF pair — one grapheme — can't slip past `contains`.
    public static func isInline(_ text: String) -> Bool {
        !text.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
    }

    // MARK: - Formatting helpers

    private static func matchingClose(of open: String) -> String {
        open == "{" ? "}" : "]"
    }

    private static func newline(into out: inout String, depth: Int, indent: String) {
        out += "\n"
        for _ in 0..<depth { out += indent }
    }

    // MARK: - Scanner

    /// Iterative pushdown scanner over UTF-16 code units — all JSON structure is
    /// ASCII, so surrogate pairs only ever appear inside strings and pass through
    /// untouched while the running index stays a correct UTF-16 offset.
    private struct Scanner {
        let units: [UInt16]
        var index = 0
        var tokens: [Token] = []
        var containers: [Container] = []
        var state = State.value(allowClose: false)
        var rootIsContainer = false

        enum Container { case object, array }

        enum State {
            /// Expecting a value; `allowClose` right after `[` permits `]`.
            case value(allowClose: Bool)
            /// Expecting an object key; `allowClose` right after `{` permits `}`.
            case key(allowClose: Bool)
            case colon
            /// Expecting `,`, a closing bracket, or the end of input.
            case afterValue
        }

        mutating func scan() -> ScanResult {
            while true {
                while index < units.count, isWhitespace(units[index]) { index += 1 }
                guard index < units.count else { break }
                let unit = units[index]
                switch state {
                case .value(let allowClose):
                    if tokens.isEmpty { rootIsContainer = unit == 0x7B || unit == 0x5B }
                    switch unit {
                    case 0x7B: // {
                        appendPunctuation()
                        containers.append(.object)
                        state = .key(allowClose: true)
                    case 0x5B: // [
                        appendPunctuation()
                        containers.append(.array)
                        state = .value(allowClose: true)
                    case 0x5D where allowClose: // ] of an empty array
                        appendPunctuation()
                        containers.removeLast()
                        state = .afterValue
                    case 0x22: // "
                        guard scanString(kind: .string) else { return failure() }
                        state = .afterValue
                    case 0x2D, 0x30...0x39: // - or digit
                        guard scanNumber() else { return failure() }
                        state = .afterValue
                    case 0x74: // t
                        guard scanKeyword("true", kind: .bool) else { return failure() }
                        state = .afterValue
                    case 0x66: // f
                        guard scanKeyword("false", kind: .bool) else { return failure() }
                        state = .afterValue
                    case 0x6E: // n
                        guard scanKeyword("null", kind: .null) else { return failure() }
                        state = .afterValue
                    default:
                        return failure()
                    }
                case .key(let allowClose):
                    switch unit {
                    case 0x7D where allowClose: // } of an empty object
                        appendPunctuation()
                        containers.removeLast()
                        state = .afterValue
                    case 0x22:
                        guard scanString(kind: .objectKey) else { return failure() }
                        state = .colon
                    default:
                        return failure()
                    }
                case .colon:
                    guard unit == 0x3A else { return failure() }
                    appendPunctuation()
                    state = .value(allowClose: false)
                case .afterValue:
                    guard let container = containers.last else { return failure() } // trailing garbage
                    switch (unit, container) {
                    case (0x2C, .object):
                        appendPunctuation()
                        state = .key(allowClose: false)
                    case (0x2C, .array):
                        appendPunctuation()
                        state = .value(allowClose: false)
                    case (0x7D, .object), (0x5D, .array):
                        appendPunctuation()
                        containers.removeLast()
                        state = .afterValue
                    default:
                        return failure()
                    }
                }
            }
            let complete: Bool
            if case .afterValue = state, containers.isEmpty { complete = true } else { complete = false }
            return ScanResult(tokens: tokens, isValid: complete, isContainer: rootIsContainer)
        }

        private func failure() -> ScanResult {
            ScanResult(tokens: tokens, isValid: false, isContainer: rootIsContainer)
        }

        private func isWhitespace(_ unit: UInt16) -> Bool {
            unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
        }

        private func isDigit(_ unit: UInt16) -> Bool {
            (0x30...0x39).contains(unit)
        }

        private func isHexDigit(_ unit: UInt16) -> Bool {
            isDigit(unit) || (0x41...0x46).contains(unit) || (0x61...0x66).contains(unit)
        }

        private mutating func appendPunctuation() {
            tokens.append(Token(kind: .punctuation, range: NSRange(location: index, length: 1)))
            index += 1
        }

        private mutating func scanString(kind: Token.Kind) -> Bool {
            let start = index
            index += 1 // opening quote
            while index < units.count {
                let unit = units[index]
                switch unit {
                case 0x22: // closing quote
                    index += 1
                    tokens.append(Token(kind: kind, range: NSRange(location: start, length: index - start)))
                    return true
                case 0x5C: // backslash escape
                    index += 1
                    guard index < units.count else { return false }
                    switch units[index] {
                    case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74: // " \ / b f n r t
                        index += 1
                    case 0x75: // \uXXXX
                        index += 1
                        for _ in 0..<4 {
                            guard index < units.count, isHexDigit(units[index]) else { return false }
                            index += 1
                        }
                    default:
                        return false
                    }
                case ..<0x20: // raw control character — illegal in a JSON string
                    return false
                default:
                    index += 1
                }
            }
            return false // unterminated
        }

        private mutating func scanNumber() -> Bool {
            let start = index
            if units[index] == 0x2D { index += 1 }
            guard index < units.count, isDigit(units[index]) else { return false }
            if units[index] == 0x30 {
                index += 1 // a leading zero stands alone ("01" is invalid)
            } else {
                while index < units.count, isDigit(units[index]) { index += 1 }
            }
            if index < units.count, units[index] == 0x2E { // fraction
                index += 1
                guard index < units.count, isDigit(units[index]) else { return false }
                while index < units.count, isDigit(units[index]) { index += 1 }
            }
            if index < units.count, units[index] == 0x65 || units[index] == 0x45 { // exponent
                index += 1
                if index < units.count, units[index] == 0x2B || units[index] == 0x2D { index += 1 }
                guard index < units.count, isDigit(units[index]) else { return false }
                while index < units.count, isDigit(units[index]) { index += 1 }
            }
            tokens.append(Token(kind: .number, range: NSRange(location: start, length: index - start)))
            return true
        }

        private mutating func scanKeyword(_ word: String, kind: Token.Kind) -> Bool {
            let expected = Array(word.utf16)
            guard index + expected.count <= units.count else { return false }
            for (offset, unit) in expected.enumerated() where units[index + offset] != unit {
                return false
            }
            tokens.append(Token(kind: kind, range: NSRange(location: index, length: expected.count)))
            index += expected.count
            return true
        }
    }
}
