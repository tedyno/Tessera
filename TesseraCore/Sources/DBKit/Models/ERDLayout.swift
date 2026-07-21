import Foundation
import CoreGraphics

/// Deterministic layered layout for the ER diagram: referenced tables land in
/// earlier (left) columns, so FK edges read left-to-right. Pure geometry — the
/// caller measures the boxes and owns any later user dragging.
public enum ERDLayout {
    public struct Node: Sendable, Hashable {
        public var id: String
        public var size: CGSize

        public init(id: String, size: CGSize) {
            self.id = id
            self.size = size
        }
    }

    /// A foreign-key edge: `from` references `to`.
    public struct Edge: Sendable, Hashable {
        public var from: String
        public var to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    /// Top-left origins for every node. Layer = longest reference path from the
    /// node to a table it (transitively) references — a cycle's back edge does
    /// not extend the path, so cyclic schemas terminate. Within a layer, nodes
    /// stack vertically sorted by id; nodes with no edges pack into a trailing
    /// grid block.
    public static func layout(nodes: [Node], edges: [Edge],
                              columnGap: CGFloat = 80, rowGap: CGFloat = 40,
                              isolatedColumns: Int = 4) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let valid = edges.filter { byID[$0.from] != nil && byID[$0.to] != nil && $0.from != $0.to }

        var connected = Set<String>()
        var references: [String: [String]] = [:]     // from → [to]
        for edge in valid {
            connected.insert(edge.from)
            connected.insert(edge.to)
            references[edge.from, default: []].append(edge.to)
        }
        // Traversal order decides where a cycle gets cut (and thus the memoized
        // depths) — sort everything so the same schema always lays out the same
        // way regardless of input order.
        for key in references.keys { references[key]?.sort() }

        // Longest path to a leaf (a table referencing nothing), depth-first with
        // memoization; nodes currently on the stack count as depth 0 so cycles
        // don't recurse forever.
        var depths: [String: Int] = [:]
        var onStack = Set<String>()
        func depth(of id: String) -> Int {
            if let known = depths[id] { return known }
            guard !onStack.contains(id) else { return 0 }
            onStack.insert(id)
            let value = (references[id]?.map { depth(of: $0) + 1 }.max()) ?? 0
            onStack.remove(id)
            depths[id] = value
            return value
        }

        // Seed the memo in sorted order for the same determinism reason.
        for id in connected.sorted() { _ = depth(of: id) }

        // Deduplicated, id-sorted: the barycenter pass indexes layers by id.
        let connectedNodes = connected.sorted().compactMap { byID[$0] }
        var layers: [Int: [Node]] = [:]
        for node in connectedNodes {
            layers[depth(of: node.id), default: []].append(node)
        }

        // Reduce edge crossings: a few barycenter sweeps reorder each layer so
        // nodes sit near the average position of their neighbors in the
        // adjacent layer (classic Sugiyama step, deterministic tie-breaks).
        var adjacency: [String: [String]] = [:]
        for edge in valid {
            adjacency[edge.from, default: []].append(edge.to)
            adjacency[edge.to, default: []].append(edge.from)
        }
        let depthsSorted = layers.keys.sorted()
        func reorder(_ depth: Int, relativeTo reference: [Node]) {
            guard var layer = layers[depth] else { return }
            let position = Dictionary(reference.enumerated().map { ($0.element.id, $0.offset) },
                                      uniquingKeysWith: { first, _ in first })
            let current = Dictionary(layer.enumerated().map { ($0.element.id, $0.offset) },
                                     uniquingKeysWith: { first, _ in first })
            func barycenter(_ node: Node) -> Double {
                let refs = (adjacency[node.id] ?? []).compactMap { position[$0] }
                guard !refs.isEmpty else { return .infinity }
                return Double(refs.reduce(0, +)) / Double(refs.count)
            }
            layer.sort { a, b in
                let (ba, bb) = (barycenter(a), barycenter(b))
                return ba == bb ? current[a.id]! < current[b.id]! : ba < bb
            }
            layers[depth] = layer
        }
        for _ in 0..<3 {
            for (index, depth) in depthsSorted.enumerated() where index > 0 {
                reorder(depth, relativeTo: layers[depthsSorted[index - 1]]!)
            }
            for (index, depth) in depthsSorted.enumerated().reversed()
            where index < depthsSorted.count - 1 {
                reorder(depth, relativeTo: layers[depthsSorted[index + 1]]!)
            }
        }

        var positions: [String: CGPoint] = [:]
        var x: CGFloat = 0
        let tallest = layers.values
            .map { layer in layer.reduce(-rowGap) { $0 + $1.size.height + rowGap } }
            .max() ?? 0
        for layerIndex in depthsSorted {
            let layer = layers[layerIndex]!
            let height = layer.reduce(-rowGap) { $0 + $1.size.height + rowGap }
            var y = (tallest - height) / 2
            for node in layer {
                positions[node.id] = CGPoint(x: x, y: y)
                y += node.size.height + rowGap
            }
            x += (layer.map(\.size.width).max() ?? 0) + columnGap
        }

        // Isolated tables: a simple grid appended after the last layer.
        let isolated = nodes.filter { !connected.contains($0.id) }.sorted { $0.id < $1.id }
        guard !isolated.isEmpty else { return positions }
        let columns = max(isolatedColumns, 1)
        let columnWidth = (isolated.map(\.size.width).max() ?? 0) + columnGap / 2
        var rowY: CGFloat = 0
        var rowHeight: CGFloat = 0
        for (index, node) in isolated.enumerated() {
            let column = index % columns
            if column == 0, index > 0 {
                rowY += rowHeight + rowGap
                rowHeight = 0
            }
            positions[node.id] = CGPoint(x: x + CGFloat(column) * columnWidth, y: rowY)
            rowHeight = max(rowHeight, node.size.height)
        }
        return positions
    }
}
