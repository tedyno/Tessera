import Foundation

/// One pane's tab group: an ordered list of tab ids plus which one is active.
/// The `QueryTab` objects themselves stay owned by `QueryConsoleModel.tabs`; a
/// group only records membership and order, so the run/commit/persistence logic
/// keyed off the flat tab list is untouched by tiling.
@MainActor
@Observable
final class TabGroup: Identifiable {
    let id: UUID
    var tabIDs: [UUID]
    var activeID: UUID?
    /// Whether this pane shows the value inspector below its grid — per pane, so
    /// the global status-bar toggle acts on whichever pane has focus.
    var showInspector = false

    init(id: UUID = UUID(), tabIDs: [UUID] = [], activeID: UUID? = nil) {
        self.id = id
        self.tabIDs = tabIDs
        self.activeID = activeID ?? tabIDs.first
    }
}

/// Which way a split lays its children out.
enum SplitAxis: String, Codable, Sendable {
    case horizontal   // children side by side, left → right
    case vertical     // children stacked, top → bottom
}

/// Which edge of a pane a dragged tab was dropped on — the new group lands there.
enum DropEdge {
    case left, right, top, bottom

    var axis: SplitAxis { self == .left || self == .right ? .horizontal : .vertical }
    /// Whether the new group goes before the existing one along the axis.
    var insertsFirst: Bool { self == .left || self == .top }
}

/// A node in the recursive pane tree: either a leaf holding one `TabGroup`, or a
/// split holding ordered children with fractional sizes that sum to 1.
@MainActor
@Observable
final class PaneNode: Identifiable {
    let id: UUID
    private(set) var group: TabGroup?
    private(set) var axis: SplitAxis?
    private(set) var children: [PaneNode]
    /// One fraction per child (sums to ~1); the split's on-screen size is divided
    /// in these proportions, and the draggable dividers rewrite adjacent pairs.
    var fractions: [Double]

    init(group: TabGroup) {
        self.id = UUID()
        self.group = group
        self.axis = nil
        self.children = []
        self.fractions = []
    }

    init(axis: SplitAxis, children: [PaneNode], fractions: [Double]) {
        self.id = UUID()
        self.group = nil
        self.axis = axis
        self.children = children
        self.fractions = fractions
    }

    var isLeaf: Bool { group != nil }

    /// Every group in this subtree, left-to-right / top-to-bottom.
    var allGroups: [TabGroup] {
        if let group { return [group] }
        return children.flatMap(\.allGroups)
    }

    /// The leaf holding `tabID`, if any.
    func leaf(containing tabID: UUID) -> PaneNode? {
        if let group, group.tabIDs.contains(tabID) { return self }
        for child in children {
            if let found = child.leaf(containing: tabID) { return found }
        }
        return nil
    }

    func leaf(groupID: UUID) -> PaneNode? {
        if group?.id == groupID { return self }
        for child in children {
            if let found = child.leaf(groupID: groupID) { return found }
        }
        return nil
    }

    // MARK: Mutation

    /// Turns this leaf into a split of two leaves — the incoming group on `edge`,
    /// the current group opposite it — at 50/50. Only valid on a leaf.
    func split(with newGroup: TabGroup, on edge: DropEdge) {
        guard let current = group else { return }
        let mine = PaneNode(group: current)
        let theirs = PaneNode(group: newGroup)
        let ordered = edge.insertsFirst ? [theirs, mine] : [mine, theirs]
        group = nil
        axis = edge.axis
        children = ordered
        fractions = [0.5, 0.5]
    }

    /// Removes the child leaf holding `groupID` from this split. Returns the node
    /// that should replace `self` when the split collapses to a single child, or
    /// `nil` to keep `self`. Recurses into child splits.
    @discardableResult
    func removingGroup(_ groupID: UUID) -> PaneNode? {
        guard axis != nil else { return self }   // leaves handled by the parent
        // Drop a matching direct child leaf.
        if let index = children.firstIndex(where: { $0.group?.id == groupID }) {
            children.remove(at: index)
            fractions.remove(at: min(index, fractions.count - 1))
        } else {
            // Recurse; a child split may collapse into its surviving grandchild.
            for (index, child) in children.enumerated() where child.axis != nil {
                if let replacement = child.removingGroup(groupID) {
                    children[index] = replacement
                }
            }
        }
        normalizeFractions()
        // Collapse: a split with one child becomes that child.
        return children.count == 1 ? children[0] : self
    }

    private func normalizeFractions() {
        guard !children.isEmpty else { return }
        if fractions.count != children.count {
            fractions = Array(repeating: 1.0 / Double(children.count), count: children.count)
            return
        }
        let total = fractions.reduce(0, +)
        if total > 0 { fractions = fractions.map { $0 / total } }
    }
}

/// The tiling layout for the detail area: a pane tree plus which group has focus.
/// Owns no `QueryTab` objects — it arranges the ids that `QueryConsoleModel` holds.
@MainActor
@Observable
final class WorkspaceLayout {
    var root: PaneNode
    /// The group the keyboard/schema focus follows — its active tab is the app's
    /// active tab. Defaults to the first group.
    var focusedGroupID: UUID?

    init(root: PaneNode? = nil) {
        let group = TabGroup()
        self.root = root ?? PaneNode(group: group)
        self.focusedGroupID = self.root.allGroups.first?.id
    }

    var groups: [TabGroup] { root.allGroups }
    var focusedGroup: TabGroup? { groups.first { $0.id == focusedGroupID } ?? groups.first }

    func group(containing tabID: UUID) -> TabGroup? {
        root.leaf(containing: tabID)?.group
    }

    /// Splits the pane holding `targetGroupID` and drops `tabID` into a new group
    /// on `edge`. The tab is first removed from wherever it currently lives.
    func splitDropping(tabID: UUID, targetGroupID: UUID, edge: DropEdge) {
        // Validate the target before mutating, or a target that vanished mid-drag
        // would leave the tab pulled from its old group but dropped nowhere.
        guard root.leaf(groupID: targetGroupID) != nil else { return }
        remove(tabID: tabID)   // pull it out of its old group (may collapse a pane)
        guard let target = root.leaf(groupID: targetGroupID) else { return }
        let newGroup = TabGroup(tabIDs: [tabID], activeID: tabID)
        target.split(with: newGroup, on: edge)
        focusedGroupID = newGroup.id
    }

    /// Adds `tabID` to `groupID` (or the focused group), as its active tab.
    func add(tabID: UUID, to groupID: UUID? = nil) {
        let group = (groupID.flatMap { id in groups.first { $0.id == id } }) ?? focusedGroup
        guard let group else { return }
        if !group.tabIDs.contains(tabID) { group.tabIDs.append(tabID) }
        group.activeID = tabID
        focusedGroupID = group.id
    }

    /// Removes `tabID` from its group; if that empties the group, closes the pane.
    func remove(tabID: UUID) {
        guard let group = group(containing: tabID) else { return }
        group.tabIDs.removeAll { $0 == tabID }
        if group.activeID == tabID { group.activeID = group.tabIDs.last }
        if group.tabIDs.isEmpty { closeGroup(group.id) }
    }

    /// Closes a whole pane (and its group). Returns the tab ids that were in it, so
    /// the caller can close those `QueryTab` objects too.
    @discardableResult
    func closeGroup(_ groupID: UUID) -> [UUID] {
        guard let leaf = root.leaf(groupID: groupID) else { return [] }
        let ids = leaf.group?.tabIDs ?? []
        if root.group?.id == groupID {
            // The last pane — reset to a single empty group rather than nothing.
            let fresh = TabGroup()
            root = PaneNode(group: fresh)
            focusedGroupID = fresh.id
        } else if let replacement = root.removingGroup(groupID) {
            root = replacement
            if focusedGroupID == groupID { focusedGroupID = groups.first?.id }
        }
        return ids
    }
}
