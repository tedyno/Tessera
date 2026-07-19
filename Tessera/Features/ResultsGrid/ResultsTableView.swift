import SwiftUI
import AppKit
import DBKit

/// Row view tinted by its pending change: orange = update, red = delete.
final class DirtyRowView: NSTableRowView {
    enum State { case none, update, delete, insert }
    var state: State = .none
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        let color: NSColor? = switch state {
        case .none: nil
        case .update: NSColor.systemOrange.withAlphaComponent(0.18)
        case .delete: NSColor.systemRed.withAlphaComponent(0.22)
        case .insert: NSColor.systemGreen.withAlphaComponent(0.18)
        }
        if let color { color.setFill(); dirtyRect.fill() }
    }
}

/// Editable text field that remembers its grid coordinates.
final class GridTextField: NSTextField {
    var rowIndex = -1
    var columnIndex = -1
}

/// Two-line column header: the column name above its SQL type (small, grey).
final class TypedHeaderCell: NSTableHeaderCell {
    var typeName = ""

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let inset = cellFrame.insetBy(dx: 5, dy: 3)
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor]
        (stringValue as NSString).draw(
            in: NSRect(x: inset.minX, y: inset.minY, width: inset.width, height: 14),
            withAttributes: nameAttrs)
        guard !typeName.isEmpty else { return }
        let typeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor]
        (typeName as NSString).draw(
            in: NSRect(x: inset.minX, y: inset.minY + 13, width: inset.width, height: 11),
            withAttributes: typeAttrs)
    }
}

/// Forces a taller header so the two-line `TypedHeaderCell` fits; the enclosing
/// clip view otherwise resets the height on every layout pass.
final class TallHeaderView: NSTableHeaderView {
    override var frame: NSRect {
        get { super.frame }
        set { var f = newValue; f.size.height = 30; super.frame = f }
    }
}

struct CellPos: Hashable { let row: Int; let col: Int }

/// Column types whose values read as numbers and are right-aligned in the grid.
/// Exact matches only, so `interval`/`inet`/`text` are never caught by a prefix.
private let numericColumnTypes: Set<String> = [
    "int2", "int4", "int8", "smallint", "integer", "bigint",
    "serial", "bigserial", "smallserial", "serial2", "serial4", "serial8",
    "numeric", "decimal", "real", "double precision", "float4", "float8", "money", "oid",
    "tiny", "short", "int24", "long", "longlong", "float", "double", "newdecimal", "year",
]

private func isNumericColumnType(_ typeName: String) -> Bool {
    numericColumnTypes.contains(typeName.lowercased())
}

/// NSTableView with spreadsheet-style cell selection: click/drag selects a
/// rectangular block of cells, double-click edits, ⌘C/⌘V copy/paste the block.
final class GridTableView: NSTableView {
    var onSelect: ((Int, Int, Bool, Bool) -> Void)?   // row, col, extend(shift), toggle(cmd)
    var onBeginEdit: ((Int, Int) -> Void)?
    var onDeleteRows: (() -> Void)?
    var onAddRow: (() -> Void)?
    var onDuplicateRow: ((Int) -> Void)?
    var onDuplicateSelected: (() -> Void)?
    var onRevertRow: ((Int) -> Void)?
    var onPaste: (() -> Void)?
    var onCopy: (() -> Void)?
    /// Only full-table results (`tab.editSource`) expose the row-editing menu.
    var canEditRows = false
    /// Number of fetched rows; rows at/after this index are pending inserts.
    var fetchedRowCount = 0
    /// Whether a row has a pending edit/delete/insert (for the "Revert Row" item).
    var isRowPending: ((Int) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { // delete / forward-delete
            onDeleteRows?()
        } else {
            super.keyDown(with: event)
        }
    }

    /// ⌘D duplicates the selected row(s) — only when the grid is focused so it doesn't
    /// steal the shortcut from a focused text field elsewhere.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if canEditRows,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "d",
           window?.firstResponder === self {
            onDuplicateSelected?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard canEditRows else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let menu = NSMenu()
        let add = NSMenuItem(title: String(localized: "Add Row"), action: #selector(addRowAction), keyEquivalent: "n")
        add.keyEquivalentModifierMask = .command
        add.target = self
        menu.addItem(add)
        // Duplicate applies only to a fetched row, not a pending-insert row.
        if row >= 0, row < fetchedRowCount {
            let duplicate = NSMenuItem(title: String(localized: "Duplicate Row"),
                                       action: #selector(duplicateRowAction), keyEquivalent: "d")
            duplicate.keyEquivalentModifierMask = .command
            duplicate.target = self
            duplicate.representedObject = row
            menu.addItem(duplicate)
        }
        // Revert a single row's pending change (edit / delete / insert).
        if row >= 0, isRowPending?(row) == true {
            menu.addItem(.separator())
            let revert = NSMenuItem(title: String(localized: "Revert Row"),
                                    action: #selector(revertRowAction), keyEquivalent: "")
            revert.target = self
            revert.representedObject = row
            menu.addItem(revert)
        }
        return menu
    }

    @objc private func addRowAction() { onAddRow?() }
    @objc private func duplicateRowAction(_ sender: NSMenuItem) {
        onDuplicateRow?(sender.representedObject as? Int ?? -1)
    }
    @objc private func revertRowAction(_ sender: NSMenuItem) {
        onRevertRow?(sender.representedObject as? Int ?? -1)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let col = self.column(at: point)
        guard row >= 0, col >= 0 else { super.mouseDown(with: event); return }
        window?.makeFirstResponder(self)
        if event.clickCount >= 2 {
            onBeginEdit?(row, col)
            return
        }
        onSelect?(row, col, event.modifierFlags.contains(.shift), event.modifierFlags.contains(.command))
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let col = self.column(at: point)
        if row >= 0, col >= 0 { onSelect?(row, col, true, false) }
    }

    @objc func paste(_ sender: Any?) { onPaste?() }
    @objc func copy(_ sender: Any?) { onCopy?() }
}

/// Virtualized results grid backed by `NSTableView`. When the result maps to a
/// single table (`tab.editSource`), cells are editable: edits are tracked in
/// `tab.edits`, edited rows are highlighted, and ⌘↩ persists them via UPDATE.
struct ResultsTableView: NSViewRepresentable {
    let tab: QueryTab
    /// Called when a column header is clicked (full-table view sorting).
    var onSort: (String) -> Void = { _ in }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = GridTableView()
        tableView.style = .inset
        tableView.headerView = TallHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = false
        tableView.rowHeight = 18
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.onSelect = { [c = context.coordinator] row, col, extend, toggle in
            c.selectCell(row: row, col: col, extend: extend, toggle: toggle)
        }
        tableView.onBeginEdit = { [c = context.coordinator] row, col in c.beginEdit(row: row, col: col) }
        tableView.onDeleteRows = { [c = context.coordinator] in c.deleteSelectedRows() }
        tableView.onAddRow = { [c = context.coordinator] in c.addRow() }
        tableView.onDuplicateRow = { [c = context.coordinator] row in c.duplicateRow(row) }
        tableView.onDuplicateSelected = { [c = context.coordinator] in c.duplicateSelectedRows() }
        tableView.onRevertRow = { [c = context.coordinator] row in c.revertRow(row) }
        tableView.isRowPending = { [c = context.coordinator] row in c.rowState(row) != .none }
        tableView.onPaste = { [c = context.coordinator] in c.pasteIntoSelection() }
        tableView.onCopy = { [c = context.coordinator] in c.copySelection() }

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        context.coordinator.tableView = tableView
        context.coordinator.onSort = onSort
        context.coordinator.configure(for: tab)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.onSort = onSort
        context.coordinator.configure(for: tab)
    }

    func makeCoordinator() -> Coordinator { Coordinator(tab: tab) }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        private var tab: QueryTab
        weak var tableView: NSTableView?
        var onSort: (String) -> Void = { _ in }
        static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        static let monoItalic = NSFontManager.shared.convert(mono, toHaveTrait: .italicFontMask)
        private var columnsSignature: [String] = []
        private var lastResultVersion = -1
        private var selected: Set<CellPos> = []
        private var anchor: CellPos?

        init(tab: QueryTab) { self.tab = tab }

        // MARK: Cell selection

        private var selectionRows: IndexSet {
            var set = IndexSet()
            for cell in selected { set.insert(cell.row) }
            return set
        }

        func isSelected(row: Int, col: Int) -> Bool {
            selected.contains(CellPos(row: row, col: col))
        }

        /// extend = Shift (rectangle from anchor); toggle = ⌘ (add/remove one cell).
        func selectCell(row: Int, col: Int, extend: Bool, toggle: Bool) {
            let old = selectionRows
            let cell = CellPos(row: row, col: col)
            if toggle {
                if selected.contains(cell) { selected.remove(cell) } else { selected.insert(cell) }
                anchor = cell
            } else if extend, let anchor {
                selected = Self.rectangle(from: anchor, to: cell)
            } else {
                selected = [cell]
                anchor = cell
            }
            reload(rows: old.union(selectionRows))
        }

        private static func rectangle(from a: CellPos, to b: CellPos) -> Set<CellPos> {
            var set: Set<CellPos> = []
            for row in min(a.row, b.row)...max(a.row, b.row) {
                for col in min(a.col, b.col)...max(a.col, b.col) {
                    set.insert(CellPos(row: row, col: col))
                }
            }
            return set
        }

        func beginEdit(row: Int, col: Int) {
            guard tab.isEditable, let tableView, let result, col < result.columns.count else { return }
            // Auto-increment cells on insert rows are DB-generated — not editable.
            if isInsertRow(row),
               tab.editSource?.autoIncrementColumns.contains(result.columns[col].name) == true { return }
            let old = selectionRows
            selected = [CellPos(row: row, col: col)]
            anchor = CellPos(row: row, col: col)
            reload(rows: old.union(selectionRows))
            if let field = tableView.view(atColumn: col, row: row, makeIfNecessary: true) as? GridTextField {
                field.isEditable = true
                tableView.editColumn(col, row: row, with: nil, select: true)
            }
        }

        private func reload(rows: IndexSet) {
            guard let tableView, let result = tab.result else { return }
            tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<result.columns.count))
            for row in rows {
                if let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? DirtyRowView {
                    rowView.state = rowState(row)
                    rowView.needsDisplay = true
                }
            }
        }

        func rowState(_ row: Int) -> DirtyRowView.State {
            if isInsertRow(row) { return .insert }
            if tab.pendingDeletes.contains(row) { return .delete }
            if tab.edits[row] != nil { return .update }
            return .none
        }

        /// Backspace — removes selected insert rows outright; toggles the deletion
        /// mark (red highlight) on selected fetched rows.
        func deleteSelectedRows() {
            guard tab.isEditable else { return }
            let rows = selectionRows
            guard !rows.isEmpty else { return }

            let insertIndices = rows.filter(isInsertRow).map { $0 - fetchedRowCount }.sorted(by: >)
            if !insertIndices.isEmpty {
                for index in insertIndices where index < tab.pendingInserts.count {
                    tab.pendingInserts.remove(at: index)
                }
                selected = selected.filter { !isInsertRow($0.row) }
                anchor = nil
                tableView?.reloadData()
            }

            let fetchedRows = IndexSet(rows.filter { !isInsertRow($0) })
            if !fetchedRows.isEmpty {
                let allMarked = fetchedRows.allSatisfy { tab.pendingDeletes.contains($0) }
                for row in fetchedRows {
                    if allMarked { tab.pendingDeletes.remove(row) } else { tab.pendingDeletes.insert(row) }
                }
                reload(rows: fetchedRows)
            }
        }

        /// Reverts a single row's pending change: removes an insert row, or clears an
        /// edit / delete mark on a fetched row.
        func revertRow(_ row: Int) {
            guard tab.isEditable else { return }
            if isInsertRow(row) {
                let index = row - fetchedRowCount
                guard index < tab.pendingInserts.count else { return }
                tab.pendingInserts.remove(at: index)
                selected = selected.filter { $0.row != row }
                tableView?.reloadData()
                return
            }
            tab.edits[row] = nil
            tab.pendingDeletes.remove(row)
            reload(rows: IndexSet(integer: row))
        }

        /// Appends a blank insert row (green) and scrolls it into view.
        func addRow() {
            guard tab.isEditable else { return }
            tab.pendingInserts.append(PendingInsert())
            tableView?.reloadData()
            let newRow = fetchedRowCount + tab.pendingInserts.count - 1
            tableView?.scrollRowToVisible(newRow)
        }

        /// Copies a fetched row into a new insert row, dropping DB-generated
        /// (auto-increment) columns so the database assigns fresh values.
        func duplicateRow(_ row: Int) {
            guard tab.isEditable, let values = insertValues(from: row) else { return }
            tab.pendingInserts.append(PendingInsert(values: values))
            tableView?.reloadData()
            tableView?.scrollRowToVisible(fetchedRowCount + tab.pendingInserts.count - 1)
        }

        /// ⌘D — duplicates every selected fetched row into new insert rows.
        func duplicateSelectedRows() {
            guard tab.isEditable else { return }
            let rows = selectionRows.filter { !isInsertRow($0) }.sorted()
            guard !rows.isEmpty else { return }
            for row in rows {
                if let values = insertValues(from: row) { tab.pendingInserts.append(PendingInsert(values: values)) }
            }
            tableView?.reloadData()
            tableView?.scrollRowToVisible(fetchedRowCount + tab.pendingInserts.count - 1)
        }

        /// The column→value map for a new insert row copied from a fetched row,
        /// dropping auto-increment columns and NULLs so the DB fills them.
        private func insertValues(from row: Int) -> [String: String]? {
            guard let result = tab.result, row >= 0, row < result.rows.count else { return nil }
            let auto = Set(tab.editSource?.autoIncrementColumns ?? [])
            var values: [String: String] = [:]
            let cells = result.rows[row]
            for (index, column) in result.columns.enumerated() where !auto.contains(column.name) {
                // Prefer a pending edit over the fetched value; skip NULLs (let defaults apply).
                if let edited = tab.edits[row]?[column.name] {
                    values[column.name] = edited
                } else if index < cells.count, let text = cells[index].text {
                    values[column.name] = text
                }
            }
            return values
        }

        /// ⌘V — writes the clipboard string into every selected cell.
        func pasteIntoSelection() {
            guard tab.isEditable, let result = tab.result, !selected.isEmpty,
                  let value = NSPasteboard.general.string(forType: .string) else { return }
            for cell in selected where cell.col < result.columns.count {
                let columnName = result.columns[cell.col].name
                if isInsertRow(cell.row) {
                    let index = cell.row - fetchedRowCount
                    guard index < tab.pendingInserts.count,
                          tab.editSource?.autoIncrementColumns.contains(columnName) != true else { continue }
                    tab.pendingInserts[index].values[columnName] = value
                    continue
                }
                let original = cell.col < result.rows[cell.row].count ? result.rows[cell.row][cell.col].text : nil
                if value == (original ?? "") {
                    tab.edits[cell.row]?[columnName] = nil
                    if tab.edits[cell.row]?.isEmpty == true { tab.edits[cell.row] = nil }
                } else {
                    tab.edits[cell.row, default: [:]][columnName] = value
                }
            }
            reload(rows: selectionRows)
        }

        /// ⌘C — copies the selected cells (rows by newline, columns by tab).
        func copySelection() {
            guard let result = tab.result, !selected.isEmpty else { return }
            let rows = Set(selected.map(\.row)).sorted()
            let lines = rows.map { row -> String in
                let cols = selected.filter { $0.row == row }.map(\.col).sorted()
                return cols.map { col -> String in
                    let columnName = result.columns[col].name
                    if isInsertRow(row) {
                        let index = row - fetchedRowCount
                        return index < tab.pendingInserts.count ? (tab.pendingInserts[index].values[columnName] ?? "") : ""
                    }
                    if let edited = tab.edits[row]?[columnName] { return edited }
                    let cells = result.rows[row]
                    return (col < cells.count ? cells[col].text : nil) ?? ""
                }.joined(separator: "\t")
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        }

        private var result: QueryResult? { tab.result }

        func configure(for tab: QueryTab) {
            self.tab = tab
            guard let tableView, let result = tab.result else { return }
            if let grid = tableView as? GridTableView {
                grid.canEditRows = tab.isEditable
                grid.fetchedRowCount = result.rows.count
            }
            // Reset the cell selection only when the underlying data actually changed
            // (new query / sort / filter / page) — not on the re-render after an edit.
            if tab.resultVersion != lastResultVersion {
                lastResultVersion = tab.resultVersion
                selected = []
                anchor = nil
            }
            let signature = result.columns.map(\.name)
            if signature != columnsSignature {
                columnsSignature = signature
                selected = []
                anchor = nil
                for column in tableView.tableColumns { tableView.removeTableColumn(column) }
                for (index, descriptor) in result.columns.enumerated() {
                    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
                    let header = TypedHeaderCell(textCell: descriptor.name)
                    header.typeName = descriptor.typeName
                    column.headerCell = header
                    column.width = 150
                    column.minWidth = 40
                    column.resizingMask = [.userResizingMask, .autoresizingMask]
                    tableView.addTableColumn(column)
                }
            }
            tableView.reloadData()
            updateSortIndicator(tableView, result)

            // Scroll a requested column into view (from a schema column double-click).
            if let target = tab.scrollToColumn,
               let index = result.columns.firstIndex(where: { $0.name == target }) {
                tableView.scrollColumnToVisible(index)
                let editedTab = tab
                DispatchQueue.main.async { editedTab.scrollToColumn = nil }
            }
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard tab.isEditable, let result = tab.result,
                  let index = Int(tableColumn.identifier.rawValue), index < result.columns.count else { return }
            onSort(result.columns[index].name)
        }

        /// Draws the ascending/descending arrow on the sorted column's header.
        private func updateSortIndicator(_ tableView: NSTableView, _ result: QueryResult) {
            for column in tableView.tableColumns { tableView.setIndicatorImage(nil, in: column) }
            guard let sortColumn = tab.sortColumn,
                  let index = result.columns.firstIndex(where: { $0.name == sortColumn }),
                  index < tableView.tableColumns.count else {
                tableView.highlightedTableColumn = nil
                return
            }
            let column = tableView.tableColumns[index]
            let arrow = tab.sortAscending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"
            tableView.setIndicatorImage(NSImage(named: arrow), in: column)
            tableView.highlightedTableColumn = column
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            (result?.rows.count ?? 0) + tab.pendingInserts.count
        }

        /// Double-clicking a header divider auto-fits the column to its widest value
        /// (Excel-style). Scans up to 1000 fetched rows plus all pending inserts.
        func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
            guard let result, column < result.columns.count else { return 150 }
            let name = result.columns[column].name
            let cellAttrs: [NSAttributedString.Key: Any] =
                [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]
            var maxWidth = (name as NSString)
                .size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width
            func consider(_ text: String) {
                let width = (text as NSString).size(withAttributes: cellAttrs).width
                if width > maxWidth { maxWidth = width }
            }
            for row in 0..<min(result.rows.count, 1000) {
                let cells = result.rows[row]
                consider(tab.edits[row]?[name] ?? (column < cells.count ? cells[column].text : nil) ?? "NULL")
            }
            for insert in tab.pendingInserts { consider(insert.values[name] ?? "") }
            return min(max(maxWidth + 16, 40), 600)
        }

        /// Number of fetched (non-insert) rows; insert rows are appended after these.
        private var fetchedRowCount: Int { result?.rows.count ?? 0 }
        private func isInsertRow(_ row: Int) -> Bool { row >= fetchedRowCount }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = DirtyRowView()
            rowView.state = rowState(row)
            return rowView
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let result,
                  let columnIndex = Int(tableColumn.identifier.rawValue), columnIndex < result.columns.count
            else { return nil }

            let identifier = NSUserInterfaceItemIdentifier("cell")
            let field = (tableView.makeView(withIdentifier: identifier, owner: self) as? GridTextField)
                ?? makeField(identifier: identifier)
            field.rowIndex = row
            field.columnIndex = columnIndex
            // Cells select on click (edit on double-click), so keep them non-editable here.
            field.isEditable = false
            field.isSelectable = false

            let selected = isSelected(row: row, col: columnIndex)
            field.drawsBackground = selected
            field.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.30) : .clear

            let columnName = result.columns[columnIndex].name
            // Numbers read better right-aligned; reset font/alignment on every reuse.
            field.alignment = isNumericColumnType(result.columns[columnIndex].typeName) ? .right : .left
            field.font = Self.mono

            if isInsertRow(row) {
                let insertIndex = row - fetchedRowCount
                let insert = insertIndex < tab.pendingInserts.count ? tab.pendingInserts[insertIndex] : nil
                if tab.editSource?.autoIncrementColumns.contains(columnName) == true {
                    field.stringValue = "(generated)"
                    field.textColor = .tertiaryLabelColor
                } else if let value = insert?.values[columnName] {
                    field.stringValue = value
                    field.textColor = .labelColor
                } else {
                    field.stringValue = ""
                    field.textColor = .labelColor
                }
                return field
            }

            let cells = result.rows[row]
            let original = columnIndex < cells.count ? cells[columnIndex].text : nil
            let value = tab.edits[row]?[columnName] ?? original
            if let value {
                field.stringValue = value
                field.textColor = .labelColor
            } else {
                // SQL NULL rendered in grey italic so it's unmistakable from the
                // literal string "NULL" or an empty string.
                field.stringValue = "NULL"
                field.textColor = .tertiaryLabelColor
                field.font = Self.monoItalic
            }
            return field
        }

        private func makeField(identifier: NSUserInterfaceItemIdentifier) -> GridTextField {
            let field = GridTextField(labelWithString: "")
            field.identifier = identifier
            field.font = Self.mono
            field.lineBreakMode = .byTruncatingTail
            field.isBordered = false
            field.drawsBackground = false
            field.delegate = self
            field.cell?.usesSingleLineMode = true
            return field
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? GridTextField,
                  let result, field.rowIndex >= 0, field.columnIndex < result.columns.count else { return }
            let row = field.rowIndex
            let columnName = result.columns[field.columnIndex].name
            let newValue = field.stringValue

            if isInsertRow(row) {
                let insertIndex = row - fetchedRowCount
                guard insertIndex < tab.pendingInserts.count,
                      tab.editSource?.autoIncrementColumns.contains(columnName) != true else { return }
                tab.pendingInserts[insertIndex].values[columnName] = newValue
                DispatchQueue.main.async { [weak self] in self?.reload(rows: IndexSet(integer: row)) }
                return
            }

            guard row < result.rows.count else { return }
            let original = field.columnIndex < result.rows[row].count ? result.rows[row][field.columnIndex].text : nil

            if newValue == (original ?? "NULL") || newValue == original {
                tab.edits[row]?[columnName] = nil
                if tab.edits[row]?.isEmpty == true { tab.edits[row] = nil }
            } else {
                tab.edits[row, default: [:]][columnName] = newValue
            }
            let editedRow = row
            DispatchQueue.main.async { [weak self] in
                self?.reload(rows: IndexSet(integer: editedRow))
            }
        }
    }
}
