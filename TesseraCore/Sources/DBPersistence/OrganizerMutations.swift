import Foundation

extension OrganizerNode {
    /// Replaces this node's children (no-op for connection leaves).
    mutating func setChildren(_ children: [OrganizerNode]) {
        switch self {
        case .project(var p): p.children = children; self = .project(p)
        case .folder(var f): f.children = children; self = .folder(f)
        case .connection: break
        }
    }

    /// A container can hold children (projects and folders); connections cannot.
    public var isContainer: Bool {
        switch self {
        case .project, .folder: true
        case .connection: false
        }
    }

    public var displayName: String? {
        switch self {
        case .project(let p): p.name
        case .folder(let f): f.name
        case .connection: nil
        }
    }
}

extension OrganizerDocument {

    // MARK: Lookup

    public func node(id: UUID) -> OrganizerNode? {
        if let found = Self.find(id, in: looseConnections) { return found }
        for workspace in workspaces {
            if let found = Self.find(id, in: workspace.children) { return found }
        }
        return nil
    }

    /// The `profileID` if `id` refers to a connection node, else `nil`.
    public func profileID(forNode id: UUID) -> UUID? {
        if case .connection(let ref)? = node(id: id) { return ref.profileID }
        return nil
    }

    /// All connection refs in the document that point at `profileID`.
    public func refs(toProfile profileID: UUID) -> [ConnectionRef] {
        var out: [ConnectionRef] = []
        Self.collectRefs(profileID, in: looseConnections, into: &out)
        Self.collectRefs(profileID, in: workspaces.flatMap(\.children), into: &out)
        return out
    }

    /// The parent container id and index of `id`, or `nil` if not found.
    public func location(of id: UUID) -> (parent: UUID, index: Int)? {
        if let index = looseConnections.firstIndex(where: { $0.id == id }) {
            return (Self.looseParentID, index)
        }
        for workspace in workspaces {
            if let index = workspace.children.firstIndex(where: { $0.id == id }) {
                return (workspace.id, index)
            }
            if let location = Self.location(of: id, in: workspace.children) { return location }
        }
        return nil
    }

    private static func location(of id: UUID, in nodes: [OrganizerNode]) -> (UUID, Int)? {
        for node in nodes {
            if let children = node.children {
                if let index = children.firstIndex(where: { $0.id == id }) { return (node.id, index) }
                if let found = location(of: id, in: children) { return found }
            }
        }
        return nil
    }

    /// All node ids nested under `id` (excluding `id` itself). Used to prevent
    /// dropping a container into its own subtree.
    public func descendants(of id: UUID) -> Set<UUID> {
        guard let node = node(id: id), let children = node.children else { return [] }
        var out: Set<UUID> = []
        Self.collectIDs(children, into: &out)
        return out
    }

    // MARK: Mutations

    /// The breadcrumb of ancestor names (workspace → … → folder) leading to the
    /// first connection referencing `profileID`.
    public func path(toProfile profileID: UUID) -> [String] {
        if looseConnections.contains(where: {
            if case .connection(let ref) = $0 { return ref.profileID == profileID }
            return false
        }) { return [] }
        for workspace in workspaces {
            if let path = Self.path(toProfile: profileID, in: workspace.children, ancestors: [workspace.name]) {
                return path
            }
        }
        return []
    }

    private static func path(toProfile profileID: UUID, in nodes: [OrganizerNode], ancestors: [String]) -> [String]? {
        for node in nodes {
            switch node {
            case .connection(let ref):
                if ref.profileID == profileID { return ancestors }
            case .project(let p):
                if let found = path(toProfile: profileID, in: p.children, ancestors: ancestors + [p.name]) { return found }
            case .folder(let f):
                if let found = path(toProfile: profileID, in: f.children, ancestors: ancestors + [f.name]) { return found }
            }
        }
        return nil
    }

    public mutating func setColor(_ color: String?, forFolder id: UUID) {
        for i in workspaces.indices {
            var children = workspaces[i].children
            if Self.setColor(color, forFolder: id, in: &children) {
                workspaces[i].children = children
                return
            }
        }
    }

    private static func setColor(_ color: String?, forFolder id: UUID, in nodes: inout [OrganizerNode]) -> Bool {
        for i in nodes.indices {
            if case .folder(var folder) = nodes[i] {
                if folder.id == id { folder.color = color; nodes[i] = .folder(folder); return true }
                var children = folder.children
                if setColor(color, forFolder: id, in: &children) {
                    folder.children = children
                    nodes[i] = .folder(folder)
                    return true
                }
            } else if var children = nodes[i].children {
                if setColor(color, forFolder: id, in: &children) {
                    nodes[i].setChildren(children)
                    return true
                }
            }
        }
        return false
    }

    public mutating func rename(_ id: UUID, to name: String) {
        for i in workspaces.indices {
            if workspaces[i].id == id { workspaces[i].name = name; return }
            var children = workspaces[i].children
            if Self.rename(id, to: name, in: &children) {
                workspaces[i].children = children
                return
            }
        }
    }

    @discardableResult
    public mutating func remove(_ id: UUID) -> OrganizerNode? {
        if let index = looseConnections.firstIndex(where: { $0.id == id }) {
            return looseConnections.remove(at: index)
        }
        for i in workspaces.indices {
            var children = workspaces[i].children
            if let removed = Self.remove(id, from: &children) {
                workspaces[i].children = children
                return removed
            }
        }
        return nil
    }

    /// Every profile referenced by `id` or anything nested under it — what a delete
    /// would orphan if it didn't clean up.
    public func profileIDs(inSubtreeOf id: UUID) -> [UUID] {
        if id == Self.looseParentID { return Self.collectProfileIDs(in: looseConnections) }
        if let workspace = workspaces.first(where: { $0.id == id }) {
            return Self.collectProfileIDs(in: workspace.children)
        }
        guard let node = node(id: id) else { return [] }
        if case .connection(let ref) = node { return [ref.profileID] }
        return Self.collectProfileIDs(in: node.children ?? [])
    }

    private static func collectProfileIDs(in nodes: [OrganizerNode]) -> [UUID] {
        var found: [UUID] = []
        for node in nodes {
            if case .connection(let ref) = node { found.append(ref.profileID) }
            found.append(contentsOf: collectProfileIDs(in: node.children ?? []))
        }
        return found
    }

    /// Removes a workspace. Its children move into `target` when given, so deleting a
    /// workspace need not take its connections with it; a workspace has no parent to
    /// promote them to, hence the explicit destination.
    @discardableResult
    public mutating func removeWorkspace(_ id: UUID, movingChildrenInto target: UUID?) -> Bool {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return false }
        let children = workspaces[index].children
        workspaces.remove(at: index)
        guard let target, let destination = workspaces.firstIndex(where: { $0.id == target })
        else { return true }
        workspaces[destination].children.append(contentsOf: children)
        return true
    }

    /// Removes a container but keeps what was inside it, moving its children into the
    /// container's own parent at the position it occupied. Returns false when `id`
    /// isn't a container, or isn't in the tree.
    @discardableResult
    public mutating func removeKeepingChildren(_ id: UUID) -> Bool {
        guard let location = location(of: id), let node = node(id: id),
              let children = node.children else { return false }
        guard remove(id) != nil else { return false }
        // Insert in order at the spot the container held, so the layout barely moves.
        for (offset, child) in children.enumerated() {
            insert(child, toParent: location.parent, at: location.index + offset)
        }
        return true
    }

    /// Appends `node` under the container identified by `parentID` (a workspace,
    /// project or folder). Returns `false` if the parent was not found.
    @discardableResult
    public mutating func append(_ node: OrganizerNode, toParent parentID: UUID) -> Bool {
        insert(node, toParent: parentID, at: nil)
    }

    /// Moves several nodes under a new parent as one contiguous block, preserving
    /// their relative order — used for a multi-selection drag. `move(nodeID:toParent:at:)`
    /// intentionally isn't just called once per id here: its index-adjustment math
    /// assumes a single in-place reorder, and applying it independently per item
    /// would let the dragged group drift out of order as each one shifts the count.
    /// Returns `false` if any node had to fall back to `fallbackParent` (the intended
    /// parent rejected it, or it changed shape between validation and this call) —
    /// mirroring `move`'s single-item semantics of "false = didn't land where dropped."
    @discardableResult
    public mutating func moveBatch(nodeIDs: [UUID], toParent parentID: UUID,
                                    at index: Int? = nil, fallback fallbackParent: UUID) -> Bool {
        // A folder being moved already carries its own children — drop any id
        // that's nested under another id in the same batch, so it isn't moved twice.
        let roots = nodeIDs.filter { id in
            !nodeIDs.contains { other in other != id && descendants(of: other).contains(id) }
        }
        // Same cycle/no-op guard as the single-item `move`.
        let candidates = roots.filter { $0 != parentID && !descendants(of: $0).contains(parentID) }
        guard !candidates.isEmpty else { return false }

        // Captured before anything is removed — the index adjustment below must
        // reflect the pre-move tree, not a target that's shifting as we go.
        let originalLocations = candidates.reduce(into: [UUID: (parent: UUID, index: Int)]()) { dict, id in
            dict[id] = location(of: id)
        }

        var removedNodes: [OrganizerNode] = []
        for id in candidates {
            if let removed = remove(id) { removedNodes.append(removed) }
        }
        guard !removedNodes.isEmpty else { return false }

        var adjustedIndex = index
        if let index {
            let shift = originalLocations.values.filter { $0.parent == parentID && $0.index < index }.count
            adjustedIndex = index - shift
        }

        var allPlaced = true
        for (offset, node) in removedNodes.enumerated() {
            let at = adjustedIndex.map { $0 + offset }
            if !insert(node, toParent: parentID, at: at) {
                allPlaced = false
                _ = insert(node, toParent: fallbackParent, at: nil)
            }
        }
        return allPlaced
    }

    @discardableResult
    public mutating func insert(_ node: OrganizerNode, toParent parentID: UUID, at index: Int?) -> Bool {
        if parentID == Self.looseParentID {
            // Only connections live at the loose level; there is no folder to open.
            guard case .connection = node else { return false }
            looseConnections.insert(node, at: min(index ?? looseConnections.count, looseConnections.count))
            return true
        }
        for i in workspaces.indices {
            if workspaces[i].id == parentID {
                var children = workspaces[i].children
                children.insert(node, at: min(index ?? children.count, children.count))
                workspaces[i].children = children
                return true
            }
            var children = workspaces[i].children
            if Self.insert(node, toParent: parentID, at: index, in: &children) {
                workspaces[i].children = children
                return true
            }
        }
        return false
    }

    // MARK: Recursion helpers

    private static func find(_ id: UUID, in nodes: [OrganizerNode]) -> OrganizerNode? {
        for node in nodes {
            if node.id == id { return node }
            if let children = node.children, let found = find(id, in: children) { return found }
        }
        return nil
    }

    private static func collectIDs(_ nodes: [OrganizerNode], into out: inout Set<UUID>) {
        for node in nodes {
            out.insert(node.id)
            if let children = node.children { collectIDs(children, into: &out) }
        }
    }

    private static func collectRefs(_ profileID: UUID, in nodes: [OrganizerNode], into out: inout [ConnectionRef]) {
        for node in nodes {
            if case .connection(let ref) = node, ref.profileID == profileID { out.append(ref) }
            if let children = node.children { collectRefs(profileID, in: children, into: &out) }
        }
    }

    private static func rename(_ id: UUID, to name: String, in nodes: inout [OrganizerNode]) -> Bool {
        for i in nodes.indices {
            if nodes[i].id == id, nodes[i].isContainer {
                switch nodes[i] {
                case .project(var p): p.name = name; nodes[i] = .project(p)
                case .folder(var f): f.name = name; nodes[i] = .folder(f)
                case .connection: break
                }
                return true
            }
            if var children = nodes[i].children {
                if rename(id, to: name, in: &children) {
                    nodes[i].setChildren(children)
                    return true
                }
            }
        }
        return false
    }

    private static func remove(_ id: UUID, from nodes: inout [OrganizerNode]) -> OrganizerNode? {
        if let index = nodes.firstIndex(where: { $0.id == id }) {
            return nodes.remove(at: index)
        }
        for i in nodes.indices {
            if var children = nodes[i].children {
                if let removed = remove(id, from: &children) {
                    nodes[i].setChildren(children)
                    return removed
                }
            }
        }
        return nil
    }

    private static func insert(_ node: OrganizerNode, toParent parentID: UUID, at index: Int?, in nodes: inout [OrganizerNode]) -> Bool {
        for i in nodes.indices {
            if nodes[i].id == parentID, nodes[i].isContainer {
                var children = nodes[i].children ?? []
                children.insert(node, at: min(index ?? children.count, children.count))
                nodes[i].setChildren(children)
                return true
            }
            if var children = nodes[i].children {
                if insert(node, toParent: parentID, at: index, in: &children) {
                    nodes[i].setChildren(children)
                    return true
                }
            }
        }
        return false
    }
}
