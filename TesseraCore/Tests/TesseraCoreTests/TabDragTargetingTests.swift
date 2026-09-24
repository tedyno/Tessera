import XCTest
@testable import DBKit

final class TabDragTargetingTests: XCTestCase {

    private let groupA = UUID()
    private let groupB = UUID()
    private let chip1 = UUID()
    private let chip2 = UUID()
    private let chip3 = UUID()

    /// Pane A: strip across the top-left quadrant, body below it.
    /// Three 100-wide chips starting at x = 0, so their midpoints are 50/150/250.
    private func stripA() -> TabStripGeometry {
        TabStripGeometry(
            groupID: groupA,
            frame: CGRect(x: 0, y: 0, width: 400, height: 34),
            chips: [
                .init(id: chip1, frame: CGRect(x: 0, y: 0, width: 100, height: 34)),
                .init(id: chip2, frame: CGRect(x: 100, y: 0, width: 100, height: 34)),
                .init(id: chip3, frame: CGRect(x: 200, y: 0, width: 100, height: 34)),
            ])
    }

    private func bodyA() -> PaneBodyGeometry {
        PaneBodyGeometry(groupID: groupA, frame: CGRect(x: 0, y: 34, width: 400, height: 366))
    }

    // MARK: Insertion point within a strip

    func testInsertsBeforeTheChipWhoseMiddleIsPastThePointer() {
        let strip = stripA()
        // Left of the first midpoint: lands in front of everything.
        XCTAssertEqual(TabDragTargeting.insertion(at: 10, in: strip), chip1)
        // Just short of the first midpoint still counts as "before the first".
        XCTAssertEqual(TabDragTargeting.insertion(at: 49, in: strip), chip1)
        // Past it, the insertion point flips to the next chip.
        XCTAssertEqual(TabDragTargeting.insertion(at: 51, in: strip), chip2)
        XCTAssertEqual(TabDragTargeting.insertion(at: 151, in: strip), chip3)
    }

    func testPastEveryMidpointMeansTheEndOfTheStrip() {
        XCTAssertNil(TabDragTargeting.insertion(at: 260, in: stripA()))
        // Well past the last chip, in the strip's empty run.
        XCTAssertNil(TabDragTargeting.insertion(at: 390, in: stripA()))
    }

    func testEmptyStripAlwaysTakesTheTabAtItsEnd() {
        let empty = TabStripGeometry(groupID: groupA,
                                     frame: CGRect(x: 0, y: 0, width: 400, height: 34),
                                     chips: [])
        XCTAssertNil(TabDragTargeting.insertion(at: 5, in: empty))
    }

    // MARK: Split edges

    func testEdgePicksTheNearestSideAsFourTriangles() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        XCTAssertEqual(TabDragTargeting.edge(for: CGPoint(x: 10, y: 200), in: frame), .left)
        XCTAssertEqual(TabDragTargeting.edge(for: CGPoint(x: 390, y: 200), in: frame), .right)
        XCTAssertEqual(TabDragTargeting.edge(for: CGPoint(x: 200, y: 10), in: frame), .top)
        XCTAssertEqual(TabDragTargeting.edge(for: CGPoint(x: 200, y: 390), in: frame), .bottom)
    }

    func testEdgeIsRelativeToTheFramesOrigin() {
        // A pane in the right half of the window: a point near its own left edge
        // is a left split, even though its x is past the window's middle.
        let frame = CGRect(x: 400, y: 0, width: 400, height: 400)
        XCTAssertEqual(TabDragTargeting.edge(for: CGPoint(x: 410, y: 200), in: frame), .left)
    }

    func testDegenerateFrameDoesNotDivideByZero() {
        let frame = CGRect(x: 0, y: 0, width: 0, height: 0)
        // Only has to produce *an* edge rather than crash or yield NaN.
        _ = TabDragTargeting.edge(for: .zero, in: frame)
    }

    // MARK: Whole-target resolution

    func testPointerOverAStripReorders() {
        let target = TabDragTargeting.target(at: CGPoint(x: 120, y: 17),
                                             strips: [stripA()], bodies: [bodyA()])
        XCTAssertEqual(target, .insert(groupID: groupA, before: chip2))
    }

    func testPointerOverABodySplits() {
        let target = TabDragTargeting.target(at: CGPoint(x: 390, y: 200),
                                             strips: [stripA()], bodies: [bodyA()])
        XCTAssertEqual(target, .split(groupID: groupA, edge: .right))
    }

    func testStripWinsWhereItMeetsTheBody() {
        // On the shared boundary the strip must win: reordering by mistake is
        // recoverable, an accidental split rearranges the whole window.
        let strips = [TabStripGeometry(groupID: groupA,
                                       frame: CGRect(x: 0, y: 0, width: 400, height: 34),
                                       chips: stripA().chips)]
        let bodies = [PaneBodyGeometry(groupID: groupA,
                                       frame: CGRect(x: 0, y: 30, width: 400, height: 370))]
        let target = TabDragTargeting.target(at: CGPoint(x: 120, y: 32),
                                             strips: strips, bodies: bodies)
        XCTAssertEqual(target, .insert(groupID: groupA, before: chip2))
    }

    func testTargetsThePaneThePointerIsActuallyOver() {
        let stripB = TabStripGeometry(
            groupID: groupB,
            frame: CGRect(x: 400, y: 0, width: 400, height: 34),
            chips: [.init(id: chip3, frame: CGRect(x: 400, y: 0, width: 100, height: 34))])
        let bodyB = PaneBodyGeometry(groupID: groupB,
                                     frame: CGRect(x: 400, y: 34, width: 400, height: 366))
        let target = TabDragTargeting.target(at: CGPoint(x: 410, y: 17),
                                             strips: [stripA(), stripB],
                                             bodies: [bodyA(), bodyB])
        XCTAssertEqual(target, .insert(groupID: groupB, before: chip3))
    }

    func testPointerOutsideEveryPaneHasNoTarget() {
        XCTAssertNil(TabDragTargeting.target(at: CGPoint(x: 900, y: 900),
                                             strips: [stripA()], bodies: [bodyA()]))
    }
}
