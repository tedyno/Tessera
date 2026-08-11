import XCTest
import NIOCore
import DBKit
@testable import DBDriverRedis

final class RESPCodecTests: XCTestCase {

    private func buffer(_ text: String) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        return buffer
    }

    private func parse(_ text: String) throws -> RESPValue? {
        var b = buffer(text)
        return try RESPCodec.parse(&b)
    }

    // MARK: Encoding

    func testEncodesCommandAsBulkStringArray() {
        var b = ByteBufferAllocator().buffer(capacity: 64)
        RESPCodec.encode(command: ["SET", "k", "hello world"], into: &b)
        XCTAssertEqual(b.readString(length: b.readableBytes),
                       "*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$11\r\nhello world\r\n")
    }

    func testEncodedLengthCountsUTF8Bytes() {
        var b = ByteBufferAllocator().buffer(capacity: 64)
        RESPCodec.encode(command: ["ECHO", "žluťoučký"], into: &b)
        let expected = "*2\r\n$4\r\nECHO\r\n$\(Array("žluťoučký".utf8).count)\r\nžluťoučký\r\n"
        XCTAssertEqual(b.readString(length: b.readableBytes), expected)
    }

    // MARK: Decoding

    func testParsesScalars() throws {
        XCTAssertEqual(try parse("+OK\r\n"), .simpleString("OK"))
        XCTAssertEqual(try parse("-ERR nope\r\n"), .error("ERR nope"))
        XCTAssertEqual(try parse(":42\r\n"), .integer(42))
        XCTAssertEqual(try parse(":-1\r\n"), .integer(-1))
        XCTAssertEqual(try parse("$5\r\nhello\r\n"), .bulkString("hello"))
        XCTAssertEqual(try parse("$0\r\n\r\n"), .bulkString(""))
        XCTAssertEqual(try parse("$-1\r\n"), .bulkString(nil))
        XCTAssertEqual(try parse("+\r\n"), .simpleString(""))
    }

    func testParsesArrays() throws {
        XCTAssertEqual(try parse("*2\r\n$1\r\na\r\n$1\r\nb\r\n"),
                       .array([.bulkString("a"), .bulkString("b")]))
        XCTAssertEqual(try parse("*0\r\n"), .array([]))
        XCTAssertEqual(try parse("*-1\r\n"), .array(nil))
        XCTAssertEqual(try parse("*2\r\n*1\r\n:1\r\n$1\r\nx\r\n"),
                       .array([.array([.integer(1)]), .bulkString("x")]))
    }

    func testBulkStringMayContainCRLF() throws {
        XCTAssertEqual(try parse("$7\r\na\r\nb\r\nc\r\n"), .bulkString("a\r\nb\r\nc"))
    }

    func testIncompleteFrameLeavesBufferUntouched() throws {
        for partial in ["+OK", "$5\r\nhel", "*2\r\n$1\r\na\r\n", ":12"] {
            var b = buffer(partial)
            let before = b.readableBytes
            XCTAssertNil(try RESPCodec.parse(&b), partial)
            XCTAssertEqual(b.readableBytes, before, "must not consume on incomplete: \(partial)")
        }
    }

    func testParsesFramesSplitAcrossFeeds() throws {
        var b = buffer("*2\r\n$1\r\na\r\n")
        XCTAssertNil(try RESPCodec.parse(&b))
        b.writeString("$1\r\nb\r\n+OK\r\n")
        XCTAssertEqual(try RESPCodec.parse(&b), .array([.bulkString("a"), .bulkString("b")]))
        XCTAssertEqual(try RESPCodec.parse(&b), .simpleString("OK"))
        XCTAssertNil(try RESPCodec.parse(&b))
    }

    func testInvalidPrefixThrows() {
        var b = buffer("?what\r\n")
        XCTAssertThrowsError(try RESPCodec.parse(&b))
    }

    func testHostileLengthsThrowInsteadOfCrashing() {
        // A non-Redis peer declaring absurd sizes must not overflow or allocate.
        for frame in ["$9223372036854775806\r\n", "$99999999999999999999\r\n",
                      "*4611686018427387904\r\n", "$-2\r\n", "*-5\r\n"] {
            var b = buffer(frame)
            XCTAssertThrowsError(try RESPCodec.parse(&b), frame)
        }
    }

    func testUnsupportedCommandsAreRefusedBeforeSending() async {
        let driver = RedisDriver()   // deliberately unconnected
        for command in ["SUBSCRIBE news", "BLPOP jobs 0", "MONITOR",
                        "XREAD BLOCK 0 STREAMS s $"] {
            do {
                _ = try await driver.execute(command, maxRows: nil)
                XCTFail("expected \(command) to be refused")
            } catch let DatabaseError.unsupported(message) {
                XCTAssertTrue(message.contains("not supported"), message)
            } catch {
                XCTFail("wrong error for \(command): \(error)")
            }
        }
    }

    // MARK: Reply rendering

    func testScalarReplies() {
        let ok = RedisReplyDisplay.result(command: ["SET", "k", "v"],
                                          reply: .simpleString("OK"), maxRows: nil)
        XCTAssertEqual(ok.rows, [[Cell("OK")]])
        let n = RedisReplyDisplay.result(command: ["DEL", "k"], reply: .integer(2), maxRows: nil)
        XCTAssertEqual(n.rows, [[Cell("2")]])
        let missing = RedisReplyDisplay.result(command: ["GET", "k"],
                                               reply: .bulkString(nil), maxRows: nil)
        XCTAssertEqual(missing.rows, [[Cell(nil)]])
    }

    func testHGETALLRendersFieldValuePairs() {
        let reply = RESPValue.array([.bulkString("name"), .bulkString("Alice"),
                                     .bulkString("age"), .bulkString("30")])
        let result = RedisReplyDisplay.result(command: ["HGETALL", "user:1"],
                                              reply: reply, maxRows: nil)
        XCTAssertEqual(result.columns.map(\.name), ["field", "value"])
        XCTAssertEqual(result.rows, [[Cell("name"), Cell("Alice")],
                                     [Cell("age"), Cell("30")]])
    }

    func testWithScoresRendersMemberScorePairs() {
        let reply = RESPValue.array([.bulkString("a"), .bulkString("1.5"),
                                     .bulkString("b"), .bulkString("2")])
        let result = RedisReplyDisplay.result(
            command: ["ZRANGE", "z", "0", "-1", "WITHSCORES"], reply: reply, maxRows: nil)
        XCTAssertEqual(result.columns.map(\.name), ["member", "score"])
        XCTAssertEqual(result.rows.count, 2)
    }

    func testPlainArrayRendersValueColumn() {
        let reply = RESPValue.array([.bulkString("a"), .bulkString("b")])
        let result = RedisReplyDisplay.result(command: ["SMEMBERS", "s"],
                                              reply: reply, maxRows: nil)
        XCTAssertEqual(result.columns.map(\.name), ["value"])
        XCTAssertEqual(result.rows, [[Cell("a")], [Cell("b")]])
    }

    func testNestedArraysRenderAsColumns() {
        let reply = RESPValue.array([
            .array([.bulkString("id-1"), .array([.bulkString("f"), .bulkString("v")])]),
            .array([.bulkString("id-2"), .array([.bulkString("g"), .bulkString("w")])]),
        ])
        let result = RedisReplyDisplay.result(command: ["XRANGE", "s", "-", "+"],
                                              reply: reply, maxRows: nil)
        XCTAssertEqual(result.columns.count, 2)
        XCTAssertEqual(result.rows[0], [Cell("id-1"), Cell("f v")])
    }

    func testMaxRowsTruncates() {
        let reply = RESPValue.array((0..<10).map { .bulkString(String($0)) })
        let result = RedisReplyDisplay.result(command: ["LRANGE", "l", "0", "-1"],
                                              reply: reply, maxRows: 3)
        XCTAssertEqual(result.rows.count, 3)
        XCTAssertTrue(result.isTruncated)
    }
}
