import XCTest
@testable import DBKit

/// Unit tests for the pure pane-tiling algorithm (`PaneLayout`): splitting a pane,
/// closing one (with collapse + fraction normalization), and structure queries.
final class PaneLayoutTests: XCTestCase {

    private let a = UUID(), b = UUID(), c = UUID()

    // MARK: Split

    func testSplitLeafRightAppendsNewPane() {
        XCTAssertEqual(PaneLayout.leaf(a).splitting(a, with: b, on: .right),
                       .split(axis: .horizontal, children: [.leaf(a), .leaf(b)], fractions: [0.5, 0.5]))
    }

    func testSplitLeafLeftInsertsNewPaneFirst() {
        XCTAssertEqual(PaneLayout.leaf(a).splitting(a, with: b, on: .left),
                       .split(axis: .horizontal, children: [.leaf(b), .leaf(a)], fractions: [0.5, 0.5]))
    }

    func testSplitBottomIsVerticalAxis() {
        guard case .split(let axis, _, _) = PaneLayout.leaf(a).splitting(a, with: b, on: .bottom) else {
            return XCTFail("expected a split")
        }
        XCTAssertEqual(axis, .vertical)
    }

    func testSplitLeavesUnrelatedLeafUntouched() {
        XCTAssertEqual(PaneLayout.leaf(a).splitting(b, with: c, on: .right), .leaf(a))
    }

    // MARK: Remove / collapse

    func testRemovingCollapsesTwoChildSplitToSurvivor() {
        let split = PaneLayout.split(axis: .horizontal, children: [.leaf(a), .leaf(b)], fractions: [0.3, 0.7])
        XCTAssertEqual(split.removing(a), .leaf(b))
    }

    func testRemovingFromThreeChildrenRenormalizesFractions() {
        let split = PaneLayout.split(axis: .horizontal,
                                     children: [.leaf(a), .leaf(b), .leaf(c)], fractions: [0.2, 0.3, 0.5])
        guard case .split(_, let children, let fractions)? = split.removing(b) else {
            return XCTFail("expected a split")
        }
        XCTAssertEqual(children, [.leaf(a), .leaf(c)])
        XCTAssertEqual(fractions[0], 0.2 / 0.7, accuracy: 1e-9)
        XCTAssertEqual(fractions[1], 0.5 / 0.7, accuracy: 1e-9)
    }

    func testRemovingNestedCollapsesGrandchildUpward() {
        let inner = PaneLayout.split(axis: .vertical, children: [.leaf(b), .leaf(c)], fractions: [0.5, 0.5])
        let root = PaneLayout.split(axis: .horizontal, children: [.leaf(a), inner], fractions: [0.5, 0.5])
        XCTAssertEqual(root.removing(b),
                       .split(axis: .horizontal, children: [.leaf(a), .leaf(c)], fractions: [0.5, 0.5]))
    }

    func testRemovingSoleLeafReturnsNil() {
        XCTAssertNil(PaneLayout.leaf(a).removing(a))
    }

    // MARK: Queries & fractions

    func testGroupIDsAreInVisualOrder() {
        let root = PaneLayout.split(axis: .horizontal, children: [
            .leaf(a),
            .split(axis: .vertical, children: [.leaf(b), .leaf(c)], fractions: [0.5, 0.5]),
        ], fractions: [0.5, 0.5])
        XCTAssertEqual(root.groupIDs, [a, b, c])
        XCTAssertTrue(root.contains(c))
        XCTAssertFalse(root.contains(UUID()))
    }

    func testNormalizedFractionsEqualSplitWhenCountMismatches() {
        XCTAssertEqual(PaneLayout.normalizedFractions([0.9], count: 2), [0.5, 0.5])
    }

    func testNormalizedFractionsRescaleToSumOne() {
        let f = PaneLayout.normalizedFractions([1, 3], count: 2)
        XCTAssertEqual(f[0], 0.25, accuracy: 1e-9)
        XCTAssertEqual(f[1], 0.75, accuracy: 1e-9)
    }
}
