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
        Self.collectRefs(profileID, in: workspaces.flatMap(\.children), into: &out)
        return out
    }

    // MARK: Mutations

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
        for i in workspaces.indices {
            var children = workspaces[i].children
            if let removed = Self.remove(id, from: &children) {
                workspaces[i].children = children
                return removed
            }
        }
        return nil
    }

    /// Appends `node` under the container identified by `parentID` (a workspace,
    /// project or folder). Returns `false` if the parent was not found.
    @discardableResult
    public mutating func append(_ node: OrganizerNode, toParent parentID: UUID) -> Bool {
        insert(node, toParent: parentID, at: nil)
    }

    @discardableResult
    public mutating func insert(_ node: OrganizerNode, toParent parentID: UUID, at index: Int?) -> Bool {
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
