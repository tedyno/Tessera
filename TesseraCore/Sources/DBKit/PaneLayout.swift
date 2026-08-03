import Foundation

/// Which way a split lays its children out.
public enum SplitAxis: String, Codable, Sendable {
    case horizontal   // children side by side, left → right
    case vertical     // children stacked, top → bottom
}

/// Which edge of a pane a dragged tab was dropped on — the new group lands there.
public enum DropEdge: Sendable {
    case left, right, top, bottom

    public var axis: SplitAxis { self == .left || self == .right ? .horizontal : .vertical }
    /// Whether the new group goes before the existing one along the axis.
    public var insertsFirst: Bool { self == .left || self == .top }
}

/// The detail area's pane arrangement as a pure value tree keyed by tab-group id: a
/// leaf is one group, a split holds ordered children with fractional sizes. The
/// tiling algorithm (split, remove-with-collapse, fraction normalization) lives here
/// so it can be unit-tested; the app keeps a matching `@Observable` node tree for
/// rendering and reconciles it against the result.
public indirect enum PaneLayout: Equatable, Sendable {
    case leaf(UUID)                                                  // a tab group
    case split(axis: SplitAxis, children: [PaneLayout], fractions: [Double])

    /// Every group id in this subtree, left-to-right / top-to-bottom.
    public var groupIDs: [UUID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, let children, _): return children.flatMap(\.groupIDs)
        }
    }

    public func contains(_ groupID: UUID) -> Bool { groupIDs.contains(groupID) }

    /// Splits the leaf holding `target` into two — `newGroup` on `edge`, the current
    /// group opposite it — at 50/50. Returns the tree unchanged if `target` isn't a
    /// leaf somewhere within.
    public func splitting(_ target: UUID, with newGroup: UUID, on edge: DropEdge) -> PaneLayout {
        switch self {
        case .leaf(let id):
            guard id == target else { return self }
            let ordered = edge.insertsFirst ? [PaneLayout.leaf(newGroup), .leaf(id)]
                                            : [PaneLayout.leaf(id), .leaf(newGroup)]
            return .split(axis: edge.axis, children: ordered, fractions: [0.5, 0.5])
        case .split(let axis, let children, let fractions):
            return .split(axis: axis,
                          children: children.map { $0.splitting(target, with: newGroup, on: edge) },
                          fractions: fractions)
        }
    }

    /// Removes the leaf for `groupID`, dropping its fraction, collapsing a split left
    /// with a single child, and normalizing the rest. Returns nil only when the whole
    /// subtree *was* that leaf (the caller decides what replaces it).
    public func removing(_ groupID: UUID) -> PaneLayout? {
        switch self {
        case .leaf(let id):
            return id == groupID ? nil : self
        case .split(let axis, var children, var fractions):
            if let index = children.firstIndex(where: {
                if case .leaf(let id) = $0 { return id == groupID } else { return false }
            }) {
                children.remove(at: index)
                if !fractions.isEmpty { fractions.remove(at: min(index, fractions.count - 1)) }
            } else {
                for (index, child) in children.enumerated() {
                    if case .split = child, let replacement = child.removing(groupID) {
                        children[index] = replacement
                    }
                }
            }
            fractions = Self.normalizedFractions(fractions, count: children.count)
            // A split with one child collapses into that child.
            return children.count == 1 ? children[0] : .split(axis: axis, children: children, fractions: fractions)
        }
    }

    /// Fractions summing to ~1 for `count` children — an equal split when the count
    /// doesn't match, otherwise the existing fractions rescaled.
    public static func normalizedFractions(_ fractions: [Double], count: Int) -> [Double] {
        guard count > 0 else { return [] }
        if fractions.count != count { return Array(repeating: 1.0 / Double(count), count: count) }
        let total = fractions.reduce(0, +)
        return total > 0 ? fractions.map { $0 / total } : fractions
    }
}
