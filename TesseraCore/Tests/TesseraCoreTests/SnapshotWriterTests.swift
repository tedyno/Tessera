import XCTest
@testable import DBPersistence

final class SnapshotWriterTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("snapshot.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writer() -> SnapshotWriter {
        let url = fileURL!
        return SnapshotWriter(
            write: { try? $0.write(to: url, options: [.atomic]) },
            remove: { try? FileManager.default.removeItem(at: url) })
    }

    private func waitUntil(_ condition: @escaping () -> Bool, _ message: String) {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail(message)
    }

    func testWritesTheSubmittedSnapshot() throws {
        let writer = writer()
        writer.submit(Data("first".utf8))
        waitUntil({ FileManager.default.fileExists(atPath: self.fileURL.path) }, "snapshot was never written")
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "first")
    }

    /// The regression this guards: a delete issued next to the writer could run
    /// before a snapshot that was still in flight, and that write would then bring
    /// the file back for a connection the user had just removed.
    func testRemovalIsNeverOvertakenByAPendingSnapshot() {
        let writer = writer()
        for i in 0..<20 { writer.submit(Data("snapshot \(i)".utf8)) }
        writer.submitRemoval()

        waitUntil({ !FileManager.default.fileExists(atPath: self.fileURL.path) }, "the file was not removed")
        // And nothing queued behind it puts the file back.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testTheWriterIsStillUsableAfterARemoval() throws {
        let writer = writer()
        writer.submit(Data("first".utf8))
        writer.submitRemoval()
        waitUntil({ !FileManager.default.fileExists(atPath: self.fileURL.path) }, "the file was not removed")

        writer.submit(Data("second".utf8))
        waitUntil({ FileManager.default.fileExists(atPath: self.fileURL.path) }, "the later snapshot was dropped")
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "second")
    }

    /// A writer with nowhere to delete to ignores the request rather than trapping.
    func testRemovalWithoutARemoverIsANoOp() {
        let url = fileURL!
        let writeOnly = SnapshotWriter(write: { try? $0.write(to: url, options: [.atomic]) })
        writeOnly.submitRemoval()
        writeOnly.submit(Data("kept".utf8))
        waitUntil({ FileManager.default.fileExists(atPath: url.path) }, "snapshot was never written")
    }
}
