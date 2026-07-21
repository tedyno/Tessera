import SwiftUI
import AppKit
import DBKit

/// One row of the AppKit schema tree. Reference type because `NSOutlineView`
/// items are objects; `key` is the stable identity that survives rebuilds
/// (expansion state and reveal targets are keyed on it).
final class SchemaOutlineNode {
    enum Kind { case database, schema, table, indexGroup, column, index }

    let kind: Kind
    let key: String
    let title: String
    let schema: String
    let table: String?
    let columnInfo: SchemaColumn?
    let indexInfo: SchemaIndex?
    let isView: Bool
    var children: [SchemaOutlineNode]

    init(kind: Kind, key: String, title: String, schema: String = "", table: String? = nil,
         columnInfo: SchemaColumn? = nil, indexInfo: SchemaIndex? = nil,
         isView: Bool = false, children: [SchemaOutlineNode] = []) {
        self.kind = kind
        self.key = key
        self.title = title
        self.schema = schema
        self.table = table
        self.columnInfo = columnInfo
        self.indexInfo = indexInfo
        self.isView = isView
        self.children = children
    }
}

/// NSOutlineView subclass: right-click menus, ⌘↩, a pointer cursor, and the
/// keyboard entry point of the speed search (typing on the focused tree jumps
/// the selection — arrows walk matches, Esc/Return end it).
final class SchemaTreeView: NSOutlineView {
    var contextMenuProvider: (@MainActor (Int) -> NSMenu?)?
    var onCommandReturn: (() -> Void)?
    var speedIsActive: (() -> Bool)?
    var onSpeedChar: ((Character) -> Void)?
    var onSpeedBackspace: (() -> Void)?
    var onSpeedCancel: (() -> Void)?
    var onSpeedCommit: (() -> Void)?
    var onSpeedStep: ((Int) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return contextMenuProvider?(row(at: point))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers == .command, event.keyCode == 36, window?.firstResponder === self {
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let active = speedIsActive?() == true
        switch event.keyCode {
        case 53 where active: onSpeedCancel?(); return    // Esc
        case 51 where active: onSpeedBackspace?(); return // Backspace
        case 36 where active: onSpeedCommit?(); return    // Return
        case 125 where active: onSpeedStep?(1); return    // ↓
        case 126 where active: onSpeedStep?(-1); return   // ↑
        default: break
        }
        // A plain printable character starts (or extends) the speed search.
        if event.modifierFlags.intersection([.command, .control, .option, .function]).isEmpty,
           let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
           scalar.properties.isAlphabetic || CharacterSet.decimalDigits.contains(scalar)
             || "_$.".unicodeScalars.contains(scalar) {
            onSpeedChar?(Character(scalar))
            return
        }
        super.keyDown(with: event)
    }

    /// A pointing-hand cursor over each row — AppKit gives list rows no cursor
    /// feedback by default. Scoped to actual row rects so it doesn't bleed into
    /// the empty space below the last item.
    override func resetCursorRects() {
        super.resetCursorRects()
        let rows = rows(in: visibleRect)
        for row in rows.lowerBound..<rows.upperBound {
            addCursorRect(rect(ofRow: row), cursor: .pointingHand)
        }
    }
}

/// Row view that can tint itself as a speed-search match — softer than the
/// selection highlight, so the active item still stands out among the matches.
final class SchemaRowView: NSTableRowView {
    var isSpeedMatch = false {
        didSet { if isSpeedMatch != oldValue { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        // Also under the selected row: the selection pill is rounded, and without
        // the tint behind it the corners would punch visible holes in the row.
        guard isSpeedMatch else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        bounds.fill()
    }
}

/// Column 2 rendered natively: the schema of the active connection as an
/// `NSOutlineView` — full-row hit testing, reliable programmatic scrolling and
/// AppKit performance on large schemas, none of which SwiftUI's `List` managed.
struct SchemaOutlineView: NSViewRepresentable {
    var tree: DatabaseTree?
    var hiddenSchemas: Set<String> = []
    /// Lowercased name filter from the bottom bar; empty shows everything.
    var query: String = ""
    var reveal: SchemaRevealTarget?
    var engine: DatabaseKind?
    var databases: [String] = []

    var onSwitchDatabase: (String) -> Void = { _ in }
    var onNewQueryTab: () -> Void = { }
    var onOpenTable: (_ schema: String, _ table: String) -> Void = { _, _ in }
    var onOpenColumn: (_ schema: String, _ table: String, _ column: String) -> Void = { _, _, _ in }
    var onOpenTables: (_ tables: [(schema: String, table: String)]) -> Void = { _ in }
    var onDumpTable: (_ schema: String, _ table: String) -> Void = { _, _ in }
    var onDumpTables: (_ schema: String, _ tables: [String]) -> Void = { _, _ in }
    var onDumpSchema: (_ schema: String) -> Void = { _ in }
    var onDumpSchemas: (_ schemas: [String]) -> Void = { _ in }
    var onDumpDatabase: () -> Void = { }
    var onRevealDatabaseFile: () -> Void = { }
    var onDDL: (DDLOperation) -> Void = { _ in }
    /// Mirrors the speed search for the indicator bar: (term, position, matches).
    var onSpeedSearch: (String, Int, Int) -> Void = { _, _, _ in }
    /// Bump to cancel a running speed search from outside (the bar's ✕ button).
    var speedCancelToken: Int = 0

    func makeNSView(context: Context) -> NSScrollView {
        let outline = SchemaTreeView()
        outline.style = .sourceList
        outline.headerView = nil
        outline.rowHeight = 22
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        outline.allowsMultipleSelection = true
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        let coordinator = context.coordinator
        outline.contextMenuProvider = { row in coordinator.menu(forRow: row) }
        outline.target = coordinator
        outline.doubleAction = #selector(Coordinator.doubleClick(_:))
        outline.onCommandReturn = { coordinator.openSelection() }
        outline.speedIsActive = { !coordinator.speedTerm.isEmpty }
        outline.onSpeedChar = { coordinator.speedChar($0) }
        outline.onSpeedBackspace = { coordinator.speedBackspace() }
        outline.onSpeedCancel = { coordinator.speedEnd() }
        outline.onSpeedCommit = { coordinator.speedEnd() }
        outline.onSpeedStep = { coordinator.speedStep($0) }

        let scrollView = NSScrollView()
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        coordinator.outlineView = outline
        apply(to: coordinator)
        coordinator.sync(tree: tree, hidden: hiddenSchemas, query: query)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        apply(to: context.coordinator)
        context.coordinator.sync(tree: tree, hidden: hiddenSchemas, query: query)
        context.coordinator.applyReveal(reveal)
        if context.coordinator.lastCancelToken != speedCancelToken {
            context.coordinator.lastCancelToken = speedCancelToken
            context.coordinator.speedEnd()
        }
    }

    private func apply(to coordinator: Coordinator) {
        coordinator.engine = engine
        coordinator.databases = databases
        coordinator.onSwitchDatabase = onSwitchDatabase
        coordinator.onNewQueryTab = onNewQueryTab
        coordinator.onOpenTable = onOpenTable
        coordinator.onOpenColumn = onOpenColumn
        coordinator.onOpenTables = onOpenTables
        coordinator.onDumpTable = onDumpTable
        coordinator.onDumpTables = onDumpTables
        coordinator.onDumpSchema = onDumpSchema
        coordinator.onDumpSchemas = onDumpSchemas
        coordinator.onDumpDatabase = onDumpDatabase
        coordinator.onRevealDatabaseFile = onRevealDatabaseFile
        coordinator.onDDL = onDDL
        coordinator.onSpeedSearch = onSpeedSearch
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        weak var outlineView: SchemaTreeView?

        var engine: DatabaseKind?
        var databases: [String] = []
        var onSwitchDatabase: (String) -> Void = { _ in }
        var onNewQueryTab: () -> Void = { }
        var onOpenTable: (_ schema: String, _ table: String) -> Void = { _, _ in }
        var onOpenColumn: (_ schema: String, _ table: String, _ column: String) -> Void = { _, _, _ in }
        var onOpenTables: (_ tables: [(schema: String, table: String)]) -> Void = { _ in }
        var onDumpTable: (_ schema: String, _ table: String) -> Void = { _, _ in }
        var onDumpTables: (_ schema: String, _ tables: [String]) -> Void = { _, _ in }
        var onDumpSchema: (_ schema: String) -> Void = { _ in }
        var onDumpSchemas: (_ schemas: [String]) -> Void = { _ in }
        var onDumpDatabase: () -> Void = { }
        var onRevealDatabaseFile: () -> Void = { }
        var onDDL: (DDLOperation) -> Void = { _ in }
        var onSpeedSearch: (String, Int, Int) -> Void = { _, _, _ in }

        private var root: SchemaOutlineNode?
        private var databaseName = ""
        private var lastHash: Int?
        private var lastReveal: SchemaRevealTarget?
        /// True while the filter forces everything open — expansion changes then
        /// aren't the user's and must not be recorded.
        private var filtering = false

        /// Expansion persisted across rebuilds. Schemas start open (opt-out set),
        /// tables and index groups start closed (opt-in sets).
        private var collapsedSchemas: Set<String> = []
        private var expandedKeys: Set<String> = []
        private var databaseCollapsed = false

        // MARK: Build

        func sync(tree: DatabaseTree?, hidden: Set<String>, query: String) {
            var hasher = Hasher()
            hasher.combine(tree)
            hasher.combine(hidden)
            hasher.combine(query)
            let hash = hasher.finalize()
            guard hash != lastHash else { return }
            lastHash = hash
            filtering = !query.isEmpty
            rebuild(tree: tree, hidden: hidden, query: query)
        }

        private func rebuild(tree: DatabaseTree?, hidden: Set<String>, query: String) {
            guard let tree else {
                root = nil
                outlineView?.reloadData()
                return
            }
            databaseName = tree.databaseName

            func tableMatches(_ table: SchemaTable) -> Bool {
                guard !query.isEmpty else { return true }
                if table.name.lowercased().contains(query) { return true }
                return table.columns.contains { $0.name.lowercased().contains(query) }
            }

            var schemaNodes: [SchemaOutlineNode] = []
            for namespace in tree.schemas where !hidden.contains(namespace.name) {
                let tables = namespace.tables.filter(tableMatches)
                if !query.isEmpty, tables.isEmpty, !namespace.name.lowercased().contains(query) {
                    continue
                }
                let tableNodes = tables.map { table -> SchemaOutlineNode in
                    let tableKey = "t:\(namespace.name).\(table.name)"
                    var children = table.columns.map { column in
                        SchemaOutlineNode(kind: .column,
                                          key: "c:\(namespace.name).\(table.name).\(column.name)",
                                          title: column.name, schema: namespace.name,
                                          table: table.name, columnInfo: column)
                    }
                    if !table.indexes.isEmpty {
                        children.append(SchemaOutlineNode(
                            kind: .indexGroup, key: "ti:\(namespace.name).\(table.name)",
                            title: String(localized: "Indexes"),
                            schema: namespace.name, table: table.name,
                            children: table.indexes.map { index in
                                SchemaOutlineNode(kind: .index,
                                                  key: "i:\(namespace.name).\(table.name).\(index.name)",
                                                  title: index.name, schema: namespace.name,
                                                  table: table.name, indexInfo: index)
                            }))
                    }
                    return SchemaOutlineNode(kind: .table, key: tableKey, title: table.name,
                                             schema: namespace.name, table: table.name,
                                             isView: table.kind == .view, children: children)
                }
                schemaNodes.append(SchemaOutlineNode(kind: .schema, key: "s:\(namespace.name)",
                                                     title: namespace.name, schema: namespace.name,
                                                     children: tableNodes))
            }
            root = SchemaOutlineNode(kind: .database, key: "db", title: tree.databaseName,
                                     children: schemaNodes)
            outlineView?.reloadData()
            restoreExpansion()
        }

        private func restoreExpansion() {
            guard let outlineView, let root else { return }
            if filtering {
                outlineView.expandItem(root, expandChildren: true)
                return
            }
            if !databaseCollapsed { outlineView.expandItem(root) }
            for schema in root.children {
                if !collapsedSchemas.contains(schema.key) { outlineView.expandItem(schema) }
                for table in schema.children where expandedKeys.contains(table.key) {
                    outlineView.expandItem(table)
                    for group in table.children where group.kind == .indexGroup
                        && expandedKeys.contains(group.key) {
                        outlineView.expandItem(group)
                    }
                }
            }
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? SchemaOutlineNode else { return root == nil ? 0 : 1 }
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? SchemaOutlineNode else { return root! }
            return node.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? SchemaOutlineNode else { return false }
            return !node.children.isEmpty
        }

        // MARK: Expansion tracking

        func outlineViewItemDidExpand(_ notification: Notification) {
            outlineView?.window?.invalidateCursorRects(for: outlineView!)
            guard !filtering,
                  let node = notification.userInfo?["NSObject"] as? SchemaOutlineNode else { return }
            switch node.kind {
            case .database: databaseCollapsed = false
            case .schema: collapsedSchemas.remove(node.key)
            case .table, .indexGroup: expandedKeys.insert(node.key)
            default: break
            }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !filtering,
                  let node = notification.userInfo?["NSObject"] as? SchemaOutlineNode else { return }
            switch node.kind {
            case .database: databaseCollapsed = true
            case .schema: collapsedSchemas.insert(node.key)
            case .table, .indexGroup: expandedKeys.remove(node.key)
            default: break
            }
        }

        // MARK: Cells

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let identifier = NSUserInterfaceItemIdentifier("schemaRow")
            let row = (outlineView.makeView(withIdentifier: identifier, owner: self) as? SchemaRowView)
                ?? { let view = SchemaRowView(); view.identifier = identifier; return view }()
            row.isSpeedMatch = (item as? SchemaOutlineNode).map { speedMatchKeys.contains($0.key) } ?? false
            return row
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?,
                         item: Any) -> NSView? {
            guard let node = item as? SchemaOutlineNode else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("schemaCell")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
                ?? Self.makeCellView(identifier: identifier)
            configure(cell, for: node)
            return cell
        }

        private static func makeCellView(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier

            let icon = NSImageView()
            icon.setContentHuggingPriority(.required, for: .horizontal)

            let title = NSTextField(labelWithString: "")
            title.font = .systemFont(ofSize: 13)
            title.lineBreakMode = .byTruncatingTail
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let badges = NSTextField(labelWithString: "")
            badges.font = .systemFont(ofSize: 9, weight: .bold)
            badges.setContentHuggingPriority(.required, for: .horizontal)
            badges.identifier = NSUserInterfaceItemIdentifier("badges")

            let detail = NSTextField(labelWithString: "")
            detail.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byTruncatingTail
            detail.alignment = .right
            detail.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            detail.identifier = NSUserInterfaceItemIdentifier("detail")

            let spacer = NSView()
            spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

            let stack = NSStackView(views: [icon, title, badges, spacer, detail])
            stack.orientation = .horizontal
            stack.spacing = 5
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.imageView = icon
            cell.textField = title
            return cell
        }

        private func configure(_ cell: NSTableCellView, for node: SchemaOutlineNode) {
            let badges = cell.subviews.first?.subviews.first { $0.identifier?.rawValue == "badges" }
                as? NSTextField ?? cell.viewWithTag(0) as? NSTextField
            let badgeField = (cell.subviews.compactMap { $0 as? NSStackView }.first?
                .arrangedSubviews.first { $0.identifier?.rawValue == "badges" }) as? NSTextField ?? badges
            let detailField = (cell.subviews.compactMap { $0 as? NSStackView }.first?
                .arrangedSubviews.first { $0.identifier?.rawValue == "detail" }) as? NSTextField

            cell.textField?.stringValue = node.title
            cell.textField?.textColor = .labelColor
            cell.textField?.font = .systemFont(ofSize: 13)
            badgeField?.attributedStringValue = NSAttributedString()
            detailField?.stringValue = ""
            cell.toolTip = nil

            let symbol: String
            var tint = NSColor.secondaryLabelColor
            switch node.kind {
            case .database:
                symbol = "cylinder.split.1x2"
                tint = .controlAccentColor
                cell.textField?.textColor = .controlAccentColor
            case .schema:
                symbol = "circle.grid.2x2"
            case .table:
                symbol = node.isView ? "eye" : "tablecells"
                if node.isView { cell.textField?.textColor = .secondaryLabelColor }
                cell.toolTip = String(localized: "Double-click to SELECT *")
            case .indexGroup:
                symbol = "number"
                cell.textField?.font = .systemFont(ofSize: 11)
                cell.textField?.textColor = .secondaryLabelColor
            case .index:
                symbol = "number.square"
                if let index = node.indexInfo {
                    detailField?.stringValue = index.columns.joined(separator: ", ")
                    if index.isUnique {
                        badgeField?.attributedStringValue = Self.badgeString([("UNIQUE", .systemBlue)])
                    }
                }
            case .column:
                symbol = "circle.fill"
                if let column = node.columnInfo {
                    tint = column.isPrimaryKey ? .systemYellow
                        : (column.isForeignKey ? .systemPurple : .tertiaryLabelColor)
                    cell.textField?.font = .systemFont(ofSize: 12)
                    detailField?.stringValue = column.dataType
                    var parts: [(String, NSColor)] = []
                    if column.isPrimaryKey { parts.append(("PK", .systemOrange)) }
                    if column.isForeignKey { parts.append(("FK", .systemPurple)) }
                    if !column.isNullable { parts.append(("NOT NULL", .systemGray)) }
                    badgeField?.attributedStringValue = Self.badgeString(parts)
                }
            }
            let size: CGFloat = node.kind == .column ? 7 : 13
            cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
            cell.imageView?.contentTintColor = tint
        }

        private static func badgeString(_ parts: [(String, NSColor)]) -> NSAttributedString {
            let result = NSMutableAttributedString()
            for (index, part) in parts.enumerated() {
                if index > 0 { result.append(NSAttributedString(string: " ")) }
                result.append(NSAttributedString(
                    string: part.0,
                    attributes: [.foregroundColor: part.1,
                                 .font: NSFont.systemFont(ofSize: 9, weight: .bold)]))
            }
            return result
        }

        // MARK: Actions

        @objc func doubleClick(_ sender: Any?) {
            guard let outlineView, outlineView.clickedRow >= 0,
                  let node = outlineView.item(atRow: outlineView.clickedRow) as? SchemaOutlineNode
            else { return }
            switch node.kind {
            case .table:
                if let table = node.table { onOpenTable(node.schema, table) }
            case .column:
                if let table = node.table, let column = node.columnInfo {
                    onOpenColumn(node.schema, table, column.name)
                }
            default:
                // Containers toggle on double-click, like Finder.
                if outlineView.isItemExpanded(node) { outlineView.collapseItem(node) }
                else { outlineView.expandItem(node) }
            }
        }

        /// ⌘↩ — opens every selected table.
        func openSelection() {
            let tables = selectedNodes().filter { $0.kind == .table }
            guard !tables.isEmpty else { return }
            onOpenTables(tables.compactMap { node in node.table.map { (node.schema, $0) } })
        }

        private func selectedNodes() -> [SchemaOutlineNode] {
            guard let outlineView else { return [] }
            return outlineView.selectedRowIndexes.compactMap {
                outlineView.item(atRow: $0) as? SchemaOutlineNode
            }
        }

        // MARK: Context menus

        func menu(forRow row: Int) -> NSMenu? {
            guard let outlineView, row >= 0,
                  let node = outlineView.item(atRow: row) as? SchemaOutlineNode else { return nil }
            // Right-clicking inside the selection acts on the whole selection;
            // outside it, on the clicked row alone (and moves the selection there,
            // matching AppKit convention).
            if !outlineView.selectedRowIndexes.contains(row) {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            let menu = NSMenu()

            switch node.kind {
            case .database:
                if databases.count > 1 {
                    let switchItem = NSMenuItem(title: String(localized: "Switch Database"),
                                                action: nil, keyEquivalent: "")
                    let submenu = NSMenu()
                    for database in databases {
                        let item = NSMenuItem(title: database,
                                              action: #selector(switchDatabaseAction(_:)),
                                              keyEquivalent: "")
                        item.target = self
                        item.representedObject = database
                        if database == databaseName { item.state = .on }
                        submenu.addItem(item)
                    }
                    switchItem.submenu = submenu
                    menu.addItem(switchItem)
                    menu.addItem(.separator())
                }
                add(menu, String(localized: "New Query Tab"), #selector(newQueryTabAction), key: "t")
                menu.addItem(.separator())
                if engine?.isFileBased == true {
                    add(menu, String(localized: "Reveal in Finder"), #selector(revealFileAction))
                } else {
                    add(menu, String(localized: "Dump Database…"), #selector(dumpDatabaseAction))
                }

            case .schema:
                let schemas = selectedNodes().filter { $0.kind == .schema }.map(\.schema)
                if schemas.count > 1 {
                    if engine?.isFileBased != true {
                        let item = add(menu, String(localized: "Dump \(schemas.count) Schemas…"),
                                       #selector(dumpSchemasAction))
                        item.representedObject = schemas
                    }
                } else {
                    add(menu, String(localized: "New Query Tab"), #selector(newQueryTabAction), key: "t")
                    menu.addItem(.separator())
                    add(menu, String(localized: "Create Table…"), #selector(createTableAction), node: node)
                    if engine?.isFileBased != true {
                        menu.addItem(.separator())
                        add(menu, String(localized: "Dump Schema…"), #selector(dumpSchemaAction), node: node)
                    }
                }

            case .table:
                let tables = selectedNodes().filter { $0.kind == .table }
                if tables.count > 1 {
                    let refs = tables.compactMap { n in n.table.map { (schema: n.schema, table: $0) } }
                    let openItem = add(menu, String(localized: "Open \(tables.count) Tables"),
                                       #selector(openTablesAction))
                    openItem.representedObject = refs.map { [$0.schema, $0.table] }
                    let schemas = Set(refs.map(\.schema))
                    if schemas.count == 1, let schema = schemas.first, engine?.isFileBased != true {
                        let dumpItem = add(menu, String(localized: "Dump \(tables.count) Tables…"),
                                           #selector(dumpTablesAction))
                        dumpItem.representedObject = [schema] + refs.map(\.table)
                    }
                } else {
                    add(menu, String(localized: "Open"), #selector(openTableAction), node: node)
                    menu.addItem(.separator())
                    add(menu, String(localized: "Add Column…"), #selector(addColumnAction), node: node)
                    add(menu, String(localized: "Create Index…"), #selector(createIndexAction), node: node)
                    add(menu, String(localized: "Rename Table…"), #selector(renameTableAction), node: node)
                    menu.addItem(.separator())
                    add(menu, String(localized: "Truncate Table…"), #selector(truncateTableAction), node: node)
                    add(menu, String(localized: "Drop Table…"), #selector(dropTableAction), node: node)
                    if engine?.isFileBased != true {
                        menu.addItem(.separator())
                        add(menu, String(localized: "Dump Table…"), #selector(dumpTableAction), node: node)
                    }
                }

            case .column:
                add(menu, String(localized: "Rename Column…"), #selector(renameColumnAction), node: node)
                if supports(.changeColumnType) {
                    add(menu, String(localized: "Change Type…"), #selector(changeTypeAction), node: node)
                }
                if supports(.setNullability), let column = node.columnInfo {
                    add(menu,
                        column.isNullable ? String(localized: "Require NOT NULL")
                                          : String(localized: "Allow NULL"),
                        #selector(toggleNullabilityAction), node: node)
                }
                menu.addItem(.separator())
                add(menu, String(localized: "Drop Column…"), #selector(dropColumnAction), node: node)

            case .index:
                add(menu, String(localized: "Drop Index…"), #selector(dropIndexAction), node: node)

            case .indexGroup:
                return nil
            }
            return menu.items.isEmpty ? nil : menu
        }

        private func supports(_ operation: SchemaDDL.Operation) -> Bool {
            engine.map { SchemaDDL.supports(operation, for: $0) } ?? true
        }

        @discardableResult
        private func add(_ menu: NSMenu, _ title: String, _ action: Selector,
                         key: String = "", node: SchemaOutlineNode? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            if !key.isEmpty { item.keyEquivalentModifierMask = .command }
            item.target = self
            item.representedObject = node
            menu.addItem(item)
            return item
        }

        private func node(from sender: NSMenuItem) -> SchemaOutlineNode? {
            sender.representedObject as? SchemaOutlineNode
        }

        @objc private func switchDatabaseAction(_ sender: NSMenuItem) {
            if let database = sender.representedObject as? String { onSwitchDatabase(database) }
        }
        @objc private func newQueryTabAction(_ sender: NSMenuItem) { onNewQueryTab() }
        @objc private func revealFileAction(_ sender: NSMenuItem) { onRevealDatabaseFile() }
        @objc private func dumpDatabaseAction(_ sender: NSMenuItem) { onDumpDatabase() }
        @objc private func dumpSchemaAction(_ sender: NSMenuItem) {
            if let node = node(from: sender) { onDumpSchema(node.schema) }
        }
        @objc private func dumpSchemasAction(_ sender: NSMenuItem) {
            if let schemas = sender.representedObject as? [String] { onDumpSchemas(schemas) }
        }
        @objc private func createTableAction(_ sender: NSMenuItem) {
            if let node = node(from: sender) { onDDL(.createTable(schema: node.schema)) }
        }
        @objc private func openTableAction(_ sender: NSMenuItem) {
            if let node = node(from: sender), let table = node.table { onOpenTable(node.schema, table) }
        }
        @objc private func openTablesAction(_ sender: NSMenuItem) {
            guard let pairs = sender.representedObject as? [[String]] else { return }
            onOpenTables(pairs.compactMap { $0.count == 2 ? (schema: $0[0], table: $0[1]) : nil })
        }
        @objc private func dumpTableAction(_ sender: NSMenuItem) {
            if let node = node(from: sender), let table = node.table { onDumpTable(node.schema, table) }
        }
        @objc private func dumpTablesAction(_ sender: NSMenuItem) {
            guard let list = sender.representedObject as? [String], list.count > 1 else { return }
            onDumpTables(list[0], Array(list.dropFirst()))
        }
        @objc private func addColumnAction(_ sender: NSMenuItem) {
            if let node = node(from: sender), let table = node.table {
                onDDL(.addColumn(schema: node.schema, table: table))
            }
        }
        @objc private func createIndexAction(_ sender: NSMenuItem) {
            if let node = node(from: sender), let table = node.table {
                onDDL(.createIndex(schema: node.schema, table: table, columns: []))
            }
        }
        @objc private func renameTableAction(_ sender: NSMenuItem) {
            if let node = node(from: sender), let table = node.table {
                onDDL(.renameTable(schema: node.schema, table: table))
            }
        }
        @objc private func truncateTableAction(_ sender: NSMenuItem) {
            if let node = node(from: sender), let table = node.table {
                onDDL(.truncateTable(schema: node.schema, table: table))
            }
        }
        @objc private func dropTableAction(_ sender: NSMenuItem) {
            if let node = node(from: sender), let table = node.table {
                onDDL(.dropTable(schema: node.schema, table: table))
            }
        }
        @objc private func renameColumnAction(_ sender: NSMenuItem) {
            if let node = node(from: sender), let table = node.table, let column = node.columnInfo {
                onDDL(.renameColumn(schema: node.schema, table: table, column: column.name))
            }
        }
        @objc private func changeTypeAction(_ sender: NSMenuItem) {
            if let node = node(from: sender), let table = node.table, let column = node.columnInfo {
                onDDL(.changeColumnType(schema: node.schema, table: table,
                                        column: column.name, currentType: column.dataType))
            }
        }
        @objc private func toggleNullabilityAction(_ sender: NSMenuItem) {
            if let node = node(from: sender), let table = node.table, let column = node.columnInfo {
                onDDL(.setNullability(schema: node.schema, table: table, column: column.name,
                                      type: column.dataType, makeNullable: !column.isNullable))
            }
        }
        @objc private func dropColumnAction(_ sender: NSMenuItem) {
            if let node = node(from: sender), let table = node.table, let column = node.columnInfo {
                onDDL(.dropColumn(schema: node.schema, table: table, column: column.name))
            }
        }
        @objc private func dropIndexAction(_ sender: NSMenuItem) {
            if let node = node(from: sender), let table = node.table, let index = node.indexInfo {
                onDDL(.dropIndex(schema: node.schema, table: table, index: index.name))
            }
        }

        // MARK: Speed search

        private(set) var speedTerm = ""
        private var speedMatches: [SchemaOutlineNode] = []
        private var speedIndex = 0
        /// Keys of the current matches, for the soft row tint.
        private var speedMatchKeys: Set<String> = []
        /// Last seen value of the representable's cancel token.
        var lastCancelToken = 0

        /// Database, schema and table nodes in display order — including tables
        /// inside collapsed schemas; jumping expands the path, like PhpStorm.
        private func speedCandidates() -> [SchemaOutlineNode] {
            guard let root else { return [] }
            var out: [SchemaOutlineNode] = [root]
            for schema in root.children {
                out.append(schema)
                out.append(contentsOf: schema.children.filter { $0.kind == .table })
            }
            return out
        }

        func speedChar(_ character: Character) {
            speedTerm.append(character)
            speedRetarget()
        }

        func speedBackspace() {
            speedTerm.removeLast()
            if speedTerm.isEmpty { speedEnd() } else { speedRetarget() }
        }

        /// Esc/Return — the search ends, the selection stays where it landed.
        func speedEnd() {
            speedTerm = ""
            speedMatches = []
            speedIndex = 0
            speedMatchKeys = []
            refreshMatchTint()
            onSpeedSearch("", 0, 0)
        }

        func speedStep(_ delta: Int) {
            guard !speedMatches.isEmpty else { return }
            speedIndex = (speedIndex + delta + speedMatches.count) % speedMatches.count
            jump(to: speedMatches[speedIndex])
            onSpeedSearch(speedTerm, speedIndex + 1, speedMatches.count)
        }

        private func speedRetarget() {
            let term = speedTerm.lowercased()
            // Prefix-only: "us" finds "users", never "status" — matching anywhere
            // in the name made the jumps feel random.
            speedMatches = speedCandidates().filter { $0.title.lowercased().hasPrefix(term) }
            speedIndex = 0
            speedMatchKeys = Set(speedMatches.map(\.key))
            refreshMatchTint()
            if !speedMatches.isEmpty { jump(to: speedMatches[speedIndex]) }
            onSpeedSearch(speedTerm, speedMatches.isEmpty ? 0 : 1, speedMatches.count)
        }

        /// Re-tints the realized rows; rows scrolled in later pick the flag up
        /// from `rowViewForItem`.
        private func refreshMatchTint() {
            guard let outlineView else { return }
            outlineView.enumerateAvailableRowViews { rowView, row in
                guard let rowView = rowView as? SchemaRowView else { return }
                let node = outlineView.item(atRow: row) as? SchemaOutlineNode
                rowView.isSpeedMatch = node.map { speedMatchKeys.contains($0.key) } ?? false
            }
        }

        private func jump(to node: SchemaOutlineNode) {
            guard let outlineView, let root else { return }
            outlineView.expandItem(root)
            if node.kind == .table,
               let schema = root.children.first(where: { $0.key == "s:\(node.schema)" }) {
                outlineView.expandItem(schema)
            }
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { return }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        }

        // MARK: Reveal (from spotlight)

        func applyReveal(_ target: SchemaRevealTarget?) {
            guard let target, target != lastReveal else { return }
            lastReveal = target
            guard let outlineView, let root else { return }
            outlineView.expandItem(root)
            guard let schema = root.children.first(where: { $0.key == "s:\(target.schema)" })
            else { return }
            outlineView.expandItem(schema)
            var node: SchemaOutlineNode = schema
            if let table = target.table,
               let tableNode = schema.children.first(where: { $0.key == "t:\(target.schema).\(table)" }) {
                node = tableNode
                if let column = target.column {
                    outlineView.expandItem(tableNode)
                    if let columnNode = tableNode.children.first(where: {
                        $0.key == "c:\(target.schema).\(table).\(column)"
                    }) {
                        node = columnNode
                    }
                }
            }
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { return }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        }
    }
}
