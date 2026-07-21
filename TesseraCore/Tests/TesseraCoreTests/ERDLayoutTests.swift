import XCTest
@testable import DBKit

final class ERDLayoutTests: XCTestCase {

    private func node(_ id: String, w: CGFloat = 200, h: CGFloat = 100) -> ERDLayout.Node {
        ERDLayout.Node(id: id, size: CGSize(width: w, height: h))
    }

    private func frames(_ nodes: [ERDLayout.Node],
                        _ positions: [String: CGPoint]) -> [String: CGRect] {
        Dictionary(uniqueKeysWithValues: nodes.compactMap { node in
            positions[node.id].map { (node.id, CGRect(origin: $0, size: node.size)) }
        })
    }

    func testChainOrdersReferencedTablesLeft() {
        // a → b → c: c is the most-referenced leaf and must sit leftmost.
        let nodes = [node("a"), node("b"), node("c")]
        let positions = ERDLayout.layout(
            nodes: nodes,
            edges: [.init(from: "a", to: "b"), .init(from: "b", to: "c")])
        XCTAssertEqual(positions.count, 3)
        XCTAssertLessThan(positions["c"]!.x, positions["b"]!.x)
        XCTAssertLessThan(positions["b"]!.x, positions["a"]!.x)
    }

    func testDiamondPlacesSharedTargetBeforeBothPaths() {
        // a → b → d, a → c → d: d leftmost, b/c share a column, a rightmost.
        let nodes = ["a", "b", "c", "d"].map { node($0) }
        let positions = ERDLayout.layout(
            nodes: nodes,
            edges: [.init(from: "a", to: "b"), .init(from: "a", to: "c"),
                    .init(from: "b", to: "d"), .init(from: "c", to: "d")])
        XCTAssertLessThan(positions["d"]!.x, positions["b"]!.x)
        XCTAssertEqual(positions["b"]!.x, positions["c"]!.x)
        XCTAssertLessThan(positions["b"]!.x, positions["a"]!.x)
    }

    func testCyclesAndSelfReferencesTerminate() {
        let nodes = [node("a"), node("b"), node("tree")]
        let positions = ERDLayout.layout(
            nodes: nodes,
            edges: [.init(from: "a", to: "b"), .init(from: "b", to: "a"),
                    .init(from: "tree", to: "tree")])
        XCTAssertEqual(positions.count, 3)
        // The self-reference is dropped, leaving "tree" isolated.
        XCTAssertNotEqual(positions["tree"], nil)
    }

    func testEdgesToUnknownNodesAreIgnored() {
        let positions = ERDLayout.layout(
            nodes: [node("a")],
            edges: [.init(from: "a", to: "missing")])
        XCTAssertEqual(positions.count, 1)
    }

    func testNoOverlapsOnMixedFixture() {
        var nodes: [ERDLayout.Node] = []
        var edges: [ERDLayout.Edge] = []
        for index in 0..<30 {
            nodes.append(node("t\(index)", w: 160 + CGFloat(index % 5) * 30,
                              h: 80 + CGFloat(index % 7) * 25))
        }
        // A few chains and fans; the rest stays isolated.
        for index in 1..<10 { edges.append(.init(from: "t\(index)", to: "t\(index - 1)")) }
        for index in 11..<15 { edges.append(.init(from: "t\(index)", to: "t10")) }
        let positions = ERDLayout.layout(nodes: nodes, edges: edges)
        XCTAssertEqual(positions.count, nodes.count)

        let all = frames(nodes, positions)
        for (a, frameA) in all {
            for (b, frameB) in all where a < b {
                XCTAssertFalse(frameA.intersects(frameB), "\(a) overlaps \(b)")
            }
        }
    }

    func testCyclicLayoutIsDeterministicAcrossInputOrder() {
        // Where a cycle gets cut decides the depths — the cut point must not
        // depend on the order nodes or edges arrive in.
        let edges = [ERDLayout.Edge(from: "a", to: "b"),
                     ERDLayout.Edge(from: "b", to: "a"),
                     ERDLayout.Edge(from: "c", to: "a")]
        let names = ["a", "b", "c"]
        let first = ERDLayout.layout(nodes: names.map { node($0) }, edges: edges)
        let second = ERDLayout.layout(nodes: names.reversed().map { node($0) },
                                      edges: edges.reversed())
        XCTAssertEqual(first, second)
    }

    func testDuplicateNodeIDsDoNotTrap() {
        let positions = ERDLayout.layout(nodes: [node("a"), node("a"), node("b")],
                                         edges: [.init(from: "b", to: "a")])
        XCTAssertNotNil(positions["a"])
        XCTAssertNotNil(positions["b"])
    }

    func testLayoutIsDeterministic() {
        let nodes = (0..<12).map { node("t\($0)") }.shuffled()
        let edges = [ERDLayout.Edge(from: "t1", to: "t0"),
                     ERDLayout.Edge(from: "t2", to: "t0"),
                     ERDLayout.Edge(from: "t3", to: "t1")]
        let first = ERDLayout.layout(nodes: nodes, edges: edges)
        let second = ERDLayout.layout(nodes: nodes.shuffled(), edges: edges.shuffled())
        XCTAssertEqual(first, second)
    }
}
