import Foundation
import DBKit

// `SplitAxis`, `DropEdge`, and the pure tiling algorithm now live in TesseraCore
// (`PaneLayout`); the reference-type `PaneNode` tree below is the rendering mirror.

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

    /// The subtree's group ids — a fraction-independent identity, so SwiftUI keeps a
    /// pane's view (and its live NSTableView) across a `reconcile` that rebuilds nodes
    /// but leaves the group arrangement unchanged.
    var groupIDs: [UUID] {
        if let group { return [group.id] }
        return children.flatMap(\.groupIDs)
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

    // MARK: Layout bridge

    /// The pure value-tree view of this subtree (structure keyed by group id).
    func toLayout() -> PaneLayout {
        if let group { return .leaf(group.id) }
        return .split(axis: axis ?? .horizontal, children: children.map { $0.toLayout() }, fractions: fractions)
    }

    /// Rebuilds a node tree to match `layout`, reusing `existing` nodes whose subtree
    /// is unchanged (identity — and their live NSViews/grid state — is preserved) and
    /// looking up group content by id in `groups`.
    static func reconcile(_ existing: PaneNode?, to layout: PaneLayout,
                          groups: [UUID: TabGroup]) -> PaneNode {
        if let existing, existing.toLayout() == layout { return existing }
        switch layout {
        case .leaf(let groupID):
            // Reuse the existing leaf for this group wherever it sits in the old
            // subtree (a collapse moves it up a level) — keeps its live NSView/grid.
            if let reused = existing?.leaf(groupID: groupID) { return reused }
            return PaneNode(group: groups[groupID] ?? TabGroup(id: groupID))
        case .split(let axis, let childLayouts, let fractions):
            let existingChildren = existing?.children ?? []
            let rebuilt = childLayouts.enumerated().map { index, childLayout -> PaneNode in
                let match = existingChildren.first { $0.toLayout() == childLayout }
                    ?? (index < existingChildren.count ? existingChildren[index] : nil)
                return reconcile(match, to: childLayout, groups: groups)
            }
            return PaneNode(axis: axis, children: rebuilt, fractions: fractions)
        }
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

    /// Group content by id, for reconciling a computed `PaneLayout` back to nodes.
    private var groupMap: [UUID: TabGroup] {
        Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func group(containing tabID: UUID) -> TabGroup? {
        root.leaf(containing: tabID)?.group
    }

    /// Splits the pane holding `targetGroupID` and drops `tabID` into a new group
    /// on `edge`. The tab is first removed from wherever it currently lives.
    func splitDropping(tabID: UUID, targetGroupID: UUID, edge: DropEdge) {
        // Validate the target before mutating, or a target that vanished mid-drag
        // would leave the tab pulled from its old group but dropped nowhere.
        guard root.toLayout().contains(targetGroupID) else { return }
        remove(tabID: tabID)   // pull it out of its old group (may collapse a pane)
        guard root.toLayout().contains(targetGroupID) else { return }
        let newGroup = TabGroup(tabIDs: [tabID], activeID: tabID)
        var groups = groupMap
        groups[newGroup.id] = newGroup
        let layout = root.toLayout().splitting(targetGroupID, with: newGroup.id, on: edge)
        root = PaneNode.reconcile(root, to: layout, groups: groups)
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
        if let layout = root.toLayout().removing(groupID) {
            root = PaneNode.reconcile(root, to: layout, groups: groupMap)
            if focusedGroupID == groupID { focusedGroupID = groups.first?.id }
        } else {
            // The last pane — reset to a single empty group rather than nothing.
            let fresh = TabGroup()
            root = PaneNode(group: fresh)
            focusedGroupID = fresh.id
        }
        return ids
    }
}
