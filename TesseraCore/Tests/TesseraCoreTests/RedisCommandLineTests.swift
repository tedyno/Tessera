import XCTest
@testable import DBKit

final class RedisCommandLineTests: XCTestCase {

    // MARK: Tokenizing

    func testSplitsOnWhitespace() {
        XCTAssertEqual(RedisCommandLine.tokenize("GET user:1"), ["GET", "user:1"])
        XCTAssertEqual(RedisCommandLine.tokenize("  HSET  h  f  v  "), ["HSET", "h", "f", "v"])
    }

    func testDoubleQuotesGroupWithEscapes() {
        XCTAssertEqual(RedisCommandLine.tokenize(#"SET "my key" "a \"b\" c""#),
                       ["SET", "my key", "a \"b\" c"])
        XCTAssertEqual(RedisCommandLine.tokenize(#"SET k "line\nbreak\tand\\slash""#),
                       ["SET", "k", "line\nbreak\tand\\slash"])
    }

    func testSingleQuotesGroupLiterally() {
        XCTAssertEqual(RedisCommandLine.tokenize(#"SET k 'a \n literal'"#),
                       ["SET", "k", #"a \n literal"#])
    }

    func testAdjacentQuotedAndBareJoinIntoOneToken() {
        // redis-cli concatenates: ab"cd"ef is one argument.
        XCTAssertEqual(RedisCommandLine.tokenize(#"ECHO ab"cd"ef"#), ["ECHO", "abcdef"])
    }

    func testUnbalancedQuoteIsNil() {
        XCTAssertNil(RedisCommandLine.tokenize(#"SET k "unclosed"#))
        XCTAssertNil(RedisCommandLine.tokenize("SET k 'unclosed"))
        XCTAssertNil(RedisCommandLine.tokenize(#"SET k "trailing\"#))
    }

    func testEmptyLine() {
        XCTAssertEqual(RedisCommandLine.tokenize(""), [])
        XCTAssertEqual(RedisCommandLine.tokenize("   "), [])
    }

    // MARK: Key quoting

    func testQuoteKeyOnlyWhenNeeded() {
        XCTAssertEqual(RedisCommandLine.quoteKey("user:1"), "user:1")
        XCTAssertEqual(RedisCommandLine.quoteKey("my key"), "\"my key\"")
        XCTAssertEqual(RedisCommandLine.quoteKey("a\"b"), "\"a\\\"b\"")
        XCTAssertEqual(RedisCommandLine.quoteKey(""), "\"\"")
    }

    func testQuotedKeyRoundTripsThroughTokenizer() {
        for key in ["plain", "with space", "wei\"rd", "tab\there"] {
            let line = "GET \(RedisCommandLine.quoteKey(key))"
            XCTAssertEqual(RedisCommandLine.tokenize(line), ["GET", key], key)
        }
    }

    // MARK: Read commands

    func testReadCommandPerType() {
        XCTAssertEqual(RedisCommandLine.readCommand(key: "k", type: "string"), "GET k")
        XCTAssertEqual(RedisCommandLine.readCommand(key: "k", type: "hash"), "HGETALL k")
        XCTAssertEqual(RedisCommandLine.readCommand(key: "k", type: "list", limit: 100),
                       "LRANGE k 0 99")
        XCTAssertEqual(RedisCommandLine.readCommand(key: "k", type: "set"), "SMEMBERS k")
        XCTAssertEqual(RedisCommandLine.readCommand(key: "k", type: "zset", limit: 100),
                       "ZRANGE k 0 99 WITHSCORES")
        XCTAssertEqual(RedisCommandLine.readCommand(key: "k", type: "stream", limit: 100),
                       "XRANGE k - + COUNT 100")
        XCTAssertEqual(RedisCommandLine.readCommand(key: "my key", type: "string"),
                       "GET \"my key\"")
    }

    // MARK: Key list rendering

    func testKeyListResultShape() {
        let result = RedisGridDisplay.keyListResult([
            RedisKeyInfo(key: "user:1", type: "hash", ttlSeconds: 60),
            RedisKeyInfo(key: "cache:x", type: "string", ttlSeconds: nil),
        ], truncated: true)
        XCTAssertEqual(result.columns.map(\.name), ["key", "type", "ttl"])
        XCTAssertEqual(result.rows, [
            [Cell("user:1"), Cell("hash"), Cell("60")],
            [Cell("cache:x"), Cell("string"), Cell(nil)],
        ])
        XCTAssertTrue(result.isTruncated)
        XCTAssertTrue(result.returnsRows)
    }
}
