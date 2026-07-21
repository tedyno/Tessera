import Foundation
import DBKit

/// State of one ER-diagram tab: a snapshot of a schema's tables, the FK edges
/// between them, and the (draggable) box positions. Rebuilt when the tab is
/// reopened, so it always reflects the schema as introspected at open time.
@MainActor
@Observable
final class DiagramModel {
    /// One single-column FK edge inside the schema. Composite FKs never reach
    /// here — introspection deliberately leaves their `references` nil — and
    /// cross-schema edges are dropped (the column keeps its FK marker only).
    struct Edge: Hashable, Identifiable {
        var fromTable: String
        var fromColumn: String
        var toTable: String
        var toColumn: String
        /// FK column is nullable → a row may reference nothing (0..1).
        var isOptional: Bool
        /// FK column is unique (unique index or sole PK) → 1:1, not N:1.
        var isUnique: Bool
        var id: String { "\(fromTable).\(fromColumn)→\(toTable).\(toColumn)" }
    }

    /// What the diagram covers: the whole schema, or one table plus the tables
    /// it directly references / is referenced by.
    enum Scope: Equatable {
        case schema
        case table(String)
    }

    let schemaName: String
    let scope: Scope
    let entities: [SchemaTable]
    let entitiesByName: [String: SchemaTable]
    let edges: [Edge]
    /// Box sizes are pure text measurement over immutable snapshots — cache
    /// them; edge drawing asks per mouse-drag frame.
    @ObservationIgnored private var sizeCache: [String: CGSize] = [:]

    /// Top-left origins of the boxes, keyed by table name. Seeded by
    /// `performLayout`, then owned by the user's dragging.
    var positions: [String: CGPoint] = [:]
    var selectedTable: String?
    /// "Show in Diagram" scroll target; the canvas clears it once applied.
    var focusTable: String?
    /// Hides tables without any FK edge — the default on big schemas, where the
    /// isolated block would dwarf the connected core. Toggling seeds positions
    /// only for newly revealed tables, preserving the user's arrangement.
    var showOnlyConnected: Bool {
        didSet { performLayout(keepingExisting: true) }
    }
    /// Compact boxes: only PK/FK rows. Box sizes change, so the size cache
    /// resets; positions survive (boxes shrink/grow in place).
    var showKeysOnly = false {
        didSet {
            guard showKeysOnly != oldValue else { return }
            sizeCache.removeAll()
            performLayout(keepingExisting: true)
        }
    }

    init(schemaName: String, namespace: SchemaNamespace, scope: Scope = .schema) {
        self.schemaName = schemaName
        self.scope = scope
        self.entities = namespace.tables
        self.entitiesByName = Dictionary(namespace.tables.map { ($0.name, $0) },
                                         uniquingKeysWith: { first, _ in first })
        let tableNames = Set(namespace.tables.map(\.name))
        self.edges = namespace.tables.flatMap { table in
            let pkColumns = table.columns.filter(\.isPrimaryKey)
            return table.columns.compactMap { column -> Edge? in
                guard let target = column.references,
                      target.schema == schemaName || target.schema.isEmpty,
                      tableNames.contains(target.table) else { return nil }
                let unique = table.indexes.contains { $0.isUnique && $0.columns == [column.name] }
                    || (column.isPrimaryKey && pkColumns.count == 1)
                return Edge(fromTable: table.name, fromColumn: column.name,
                            toTable: target.table, toColumn: target.column,
                            isOptional: column.isNullable, isUnique: unique)
            }
        }
        let connected = Set(edges.flatMap { [$0.fromTable, $0.toTable] })
        self.showOnlyConnected = scope == .schema
            && namespace.tables.count > 150 && !connected.isEmpty
        performLayout()
    }

    private var connectedTables: Set<String> {
        Set(edges.flatMap { [$0.fromTable, $0.toTable] })
    }

    var visibleEntities: [SchemaTable] {
        if case .table(let name) = scope {
            let neighbors = Set(edges
                .filter { $0.fromTable == name || $0.toTable == name }
                .flatMap { [$0.fromTable, $0.toTable] })
            return entities.filter { $0.name == name || neighbors.contains($0.name) }
        }
        guard showOnlyConnected else { return entities }
        let connected = connectedTables
        // With no edges at all the filter would blank the diagram — ignore it.
        guard !connected.isEmpty else { return entities }
        return entities.filter { connected.contains($0.name) }
    }

    var visibleEdges: [Edge] {
        let names = Set(visibleEntities.map(\.name))
        return edges.filter { names.contains($0.fromTable) && names.contains($0.toTable) }
    }

    func size(of table: SchemaTable) -> CGSize {
        if let cached = sizeCache[table.name] { return cached }
        let measured = TableNodeView.preferredSize(for: table, keysOnly: showKeysOnly)
        sizeCache[table.name] = measured
        return measured
    }

    /// `keepingExisting` re-seats only tables without a stored position (the
    /// connected-filter toggle); a full run re-lays everything (Re-layout).
    func performLayout(keepingExisting: Bool = false) {
        let nodes = visibleEntities.map {
            ERDLayout.Node(id: $0.name, size: size(of: $0))
        }
        let fresh = ERDLayout.layout(
            nodes: nodes,
            edges: visibleEdges.map { ERDLayout.Edge(from: $0.fromTable, to: $0.toTable) })
        if keepingExisting {
            positions = fresh.merging(positions) { _, kept in kept }
        } else {
            positions = fresh
        }
    }

    /// Union of all box frames plus a working margin — the canvas size.
    func contentBounds() -> CGRect {
        var union: CGRect?
        for table in visibleEntities {
            guard let origin = positions[table.name] else { continue }
            let frame = CGRect(origin: origin, size: size(of: table))
            union = union?.union(frame) ?? frame
        }
        guard let union else { return CGRect(x: 0, y: 0, width: 600, height: 400) }
        return union.insetBy(dx: -60, dy: -60)
    }
}
