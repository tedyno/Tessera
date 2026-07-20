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

/// Column header showing the name followed by its SQL type in small grey text, on
/// one line so it always stays within the standard header height.
final class TypedHeaderCell: NSTableHeaderCell {
    var typeName = ""

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Let AppKit draw the chrome (background, borders, sort indicator) but not its
        // centered title — we render our own name + type instead.
        let title = stringValue
        stringValue = ""
        super.draw(withFrame: cellFrame, in: controlView)
        stringValue = title
        drawTitle(in: cellFrame)
    }

    private func drawTitle(in cellFrame: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: stringValue, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph])
        if !typeName.isEmpty {
            text.append(NSAttributedString(string: "  " + typeName, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: paragraph]))
        }
        // Leave room on the right for the sort indicator; vertically centered.
        let height = text.size().height
        let rect = NSRect(x: cellFrame.minX + 6, y: cellFrame.midY - height / 2,
                          width: max(cellFrame.width - 22, 0), height: height)
        text.draw(in: rect)
    }

    /// The sorted column is drawn via `highlight(_:withFrame:in:)`, not `draw(withFrame:in:)`
    /// — without this override, AppKit's own default implementation takes over for
    /// that one column and shows only the plain name, dropping the type. Chrome
    /// (including the pressed-state background, per `flag`) still comes from super,
    /// with the title blanked out the same way `draw` does it.
    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
        let title = stringValue
        stringValue = ""
        super.highlight(flag, withFrame: cellFrame, in: controlView)
        stringValue = title
        drawTitle(in: cellFrame)
    }
}

struct CellPos: Hashable { let row: Int; let col: Int }

/// Numeric columns are right-aligned and copied unquoted; the classification is
/// shared with the MCP server so both agree on what a number is.
private func isNumericColumnType(_ typeName: String) -> Bool {
    SQLTypes.isNumeric(typeName)
}

/// Clipboard formats offered by the grid's "Copy as" menu.
enum GridCopyFormat { case tsv, csv, json, insert }

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
    var onCopyAs: ((GridCopyFormat) -> Void)?
    var hasSelection: (() -> Bool)?
    /// Menu title for following the foreign key in a cell, or nil when it isn't one.
    var foreignKeyTitle: ((Int, Int) -> String?)?
    var onFollowForeignKey: ((Int, Int) -> Void)?
    /// ⌘↓ — follows the reference in the selected cell; false when it isn't one.
    var onFollowSelectedForeignKey: (() -> Bool)?
    /// Only full-table results (`tab.editSource`) expose the row-editing menu.
    var canEditRows = false
    /// Number of fetched rows; rows at/after this index are pending inserts.
    var fetchedRowCount = 0
    /// Whether a row has a pending edit/delete/insert (for the "Revert Row" item).
    var isRowPending: ((Int) -> Bool)?
    /// Escape — returns whether it was consumed (a ⌘F filter was active and got
    /// cleared); when false, Escape falls through to its normal handling.
    var onEscape: (() -> Bool)?
    /// Arrow keys / Tab — moves the cell selection by (rows, cols); extend = Shift.
    var onMoveSelection: ((Int, Int, Bool) -> Void)?
    /// Return — starts editing the single selected cell; false when it can't.
    var onEditSelected: (() -> Bool)?
    /// ⌥⌫ / context menu — sets every selected cell to SQL NULL.
    var onSetNull: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 123: onMoveSelection?(0, -1, shift)   // ←
        case 124: onMoveSelection?(0, 1, shift)    // →
        case 125: onMoveSelection?(1, 0, shift)    // ↓
        case 126: onMoveSelection?(-1, 0, shift)   // ↑
        case 48:  onMoveSelection?(0, shift ? -1 : 1, false)   // tab / ⇧-tab
        case 36:  // return — edit the selected cell; otherwise keep normal handling
            if onEditSelected?() != true { super.keyDown(with: event) }
        case 53:  // escape
            if onEscape?() != true { super.keyDown(with: event) }
        case 51 where event.modifierFlags.contains(.option):   // ⌥⌫ — set NULL
            onSetNull?()
        case 51, 117: // delete / forward-delete
            onDeleteRows?()
        default:
            super.keyDown(with: event)
        }
    }

    /// ⌘D duplicates the selected row(s) — only when the grid is focused so it doesn't
    /// steal the shortcut from a focused text field elsewhere.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Compare only the modifiers a shortcut is spelled with: arrow keys also carry
        // .function and .numericPad, which would never match a plain `== .command`.
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let isFocused = window?.firstResponder === self

        if canEditRows, modifiers == .command,
           event.charactersIgnoringModifiers == "d", isFocused {
            onDuplicateSelected?()
            return true
        }
        // ⌘↓ follows a foreign key in the selected cell; falls through when the cell
        // isn't one, so the key keeps its normal meaning everywhere else.
        if modifiers == .command, event.keyCode == 125, isFocused,
           onFollowSelectedForeignKey?() == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let menu = NSMenu()

        // Following a reference is the most contextual action, so it leads the menu.
        let clickedColumn = self.column(at: point)
        if row >= 0, clickedColumn >= 0, let title = foreignKeyTitle?(row, clickedColumn) {
            let follow = NSMenuItem(title: title, action: #selector(followForeignKeyAction(_:)),
                                    keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!))
            follow.keyEquivalentModifierMask = .command
            follow.target = self
            follow.representedObject = CellPos(row: row, col: clickedColumn)
            menu.addItem(follow)
            menu.addItem(.separator())
        }

        // Copy is available on any result, editable or not.
        if hasSelection?() == true {
            let copy = NSMenuItem(title: String(localized: "Copy"), action: #selector(copy(_:)), keyEquivalent: "c")
            copy.keyEquivalentModifierMask = .command
            copy.target = self
            menu.addItem(copy)
            let copyAs = NSMenuItem(title: String(localized: "Copy as"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let formats: [(String, GridCopyFormat)] = [
                (String(localized: "CSV"), .csv),
                (String(localized: "JSON"), .json),
                (String(localized: "SQL INSERT"), .insert),
            ]
            for (title, format) in formats {
                let item = NSMenuItem(title: title, action: #selector(copyAsAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = format
                submenu.addItem(item)
            }
            copyAs.submenu = submenu
            menu.addItem(copyAs)
        }

        guard canEditRows else { return menu.items.isEmpty ? nil : menu }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
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
        // ⌥⌫ already does this; without an item the gesture is undiscoverable.
        if hasSelection?() == true {
            let setNull = NSMenuItem(title: String(localized: "Set NULL"),
                                     action: #selector(setNullAction), keyEquivalent: "\u{8}")
            setNull.keyEquivalentModifierMask = .option
            setNull.target = self
            menu.addItem(setNull)
        }
        // Backspace already does this; without an item the gesture is undiscoverable.
        if hasSelection?() == true {
            let delete = NSMenuItem(title: String(localized: "Delete Rows"),
                                    action: #selector(deleteRowsAction), keyEquivalent: "\u{8}")
            delete.keyEquivalentModifierMask = []
            delete.target = self
            menu.addItem(delete)
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
    @objc private func setNullAction() { onSetNull?() }
    @objc private func duplicateRowAction(_ sender: NSMenuItem) {
        onDuplicateRow?(sender.representedObject as? Int ?? -1)
    }
    @objc private func revertRowAction(_ sender: NSMenuItem) {
        onRevertRow?(sender.representedObject as? Int ?? -1)
    }
    @objc private func copyAsAction(_ sender: NSMenuItem) {
        if let format = sender.representedObject as? GridCopyFormat { onCopyAs?(format) }
    }
    @objc private func deleteRowsAction() { onDeleteRows?() }
    @objc private func followForeignKeyAction(_ sender: NSMenuItem) {
        if let cell = sender.representedObject as? CellPos { onFollowForeignKey?(cell.row, cell.col) }
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
    /// Opens the table a foreign key points at, filtered to the referenced row.
    var onFollowForeignKey: (ForeignKeyTarget, String) -> Void = { _, _ in }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = GridTableView()
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        // Let the last column fill any trailing space so its header (name + type)
        // never floats over an empty area with no data column beneath it.
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
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
        tableView.onCopyAs = { [c = context.coordinator] format in c.copySelection(as: format) }
        tableView.hasSelection = { [c = context.coordinator] in c.hasSelection }
        tableView.foreignKeyTitle = { [c = context.coordinator] row, col in
            c.foreignKeyTitle(row: row, col: col)
        }
        tableView.onFollowForeignKey = { [c = context.coordinator] row, col in
            c.followForeignKey(row: row, col: col)
        }
        tableView.onFollowSelectedForeignKey = { [c = context.coordinator] in
            c.followSelectedForeignKey()
        }
        tableView.onEscape = { [c = context.coordinator] in c.cancelSearchIfActive() }
        tableView.onMoveSelection = { [c = context.coordinator] dRow, dCol, extend in
            c.moveSelection(dRow: dRow, dCol: dCol, extend: extend)
        }
        tableView.onEditSelected = { [c = context.coordinator] in c.editSelectedCell() }
        tableView.onSetNull = { [c = context.coordinator] in c.setSelectedToNull() }

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        context.coordinator.tableView = tableView
        context.coordinator.onSort = onSort
        context.coordinator.onFollowForeignKey = onFollowForeignKey
        context.coordinator.configure(for: tab)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.onSort = onSort
        context.coordinator.onFollowForeignKey = onFollowForeignKey
        context.coordinator.configure(for: tab)
    }

    func makeCoordinator() -> Coordinator { Coordinator(tab: tab) }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        private var tab: QueryTab
        weak var tableView: NSTableView?
        var onSort: (String) -> Void = { _ in }
        var onFollowForeignKey: (ForeignKeyTarget, String) -> Void = { _, _ in }
        static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        static let monoItalic = NSFontManager.shared.convert(mono, toHaveTrait: .italicFontMask)
        private var columnsSignature: [String] = []
        private var lastResultVersion = -1
        private var lastSearchQuery = ""
        private var selected: Set<CellPos> = []
        private var anchor: CellPos?
        /// The cell arrow keys move from — the last cell clicked or stepped onto
        /// (unlike `anchor`, which stays put while Shift extends a range from it).
        private var focus: CellPos?
        /// Data-row indices shown, in display order, while a ⌘F filter is active;
        /// nil when unfiltered (display row == data row).
        private var visibleRowMap: [Int]?

        init(tab: QueryTab) { self.tab = tab }

        /// Maps a row index as AppKit sees it (display order) to its index into
        /// `tab.result.rows` (data order) — the same thing when there's no filter.
        private func dataRow(forDisplay display: Int) -> Int {
            guard let visibleRowMap else { return display }
            return display < visibleRowMap.count ? visibleRowMap[display] : display
        }

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
            focus = cell
            reload(rows: old.union(selectionRows))
            updateInspector()
        }

        /// Arrow keys / Tab — steps the selection by (dRow, dCol), clamped to the
        /// grid; Shift extends the rectangle from the anchor instead of moving it.
        func moveSelection(dRow: Int, dCol: Int, extend: Bool) {
            guard let tableView, let result = tab.result, !result.columns.isEmpty else { return }
            let rowCount = visibleRowMap?.count ?? (result.rows.count + tab.pendingInserts.count)
            guard rowCount > 0 else { return }
            let from = focus ?? anchor ?? selected.first ?? CellPos(row: 0, col: 0)
            let cell = selected.isEmpty
                ? CellPos(row: 0, col: 0)   // nothing selected yet — land on the first cell
                : CellPos(row: min(max(from.row + dRow, 0), rowCount - 1),
                          col: min(max(from.col + dCol, 0), result.columns.count - 1))
            let old = selectionRows
            if extend, let anchor {
                selected = Self.rectangle(from: anchor, to: cell)
            } else {
                selected = [cell]
                anchor = cell
            }
            focus = cell
            reload(rows: old.union(selectionRows))
            tableView.scrollRowToVisible(cell.row)
            tableView.scrollColumnToVisible(cell.col)
            updateInspector()
        }

        /// Return — starts editing the focused cell when there's exactly one
        /// selected; false lets the key fall through to its normal handling.
        func editSelectedCell() -> Bool {
            guard tab.isEditable, visibleRowMap == nil,
                  selected.count == 1, let cell = selected.first else { return false }
            beginEdit(row: cell.row, col: cell.col)
            return true
        }

        /// ⌥⌫ / context menu — sets every selected cell to SQL NULL (on an insert
        /// row: clears the value, letting the database default apply).
        func setSelectedToNull() {
            guard tab.isEditable, visibleRowMap == nil, let result = tab.result, !selected.isEmpty else { return }
            for cell in selected where cell.col < result.columns.count {
                let columnName = result.columns[cell.col].name
                guard tab.editSource?.autoIncrementColumns.contains(columnName) != true else { continue }
                if isInsertRow(cell.row) {
                    let index = cell.row - fetchedRowCount
                    if index < tab.pendingInserts.count { tab.pendingInserts[index].values[columnName] = nil }
                    continue
                }
                guard cell.row < result.rows.count else { continue }
                let original = cell.col < result.rows[cell.row].count ? result.rows[cell.row][cell.col].text : nil
                if original == nil {
                    // Already NULL — drop any pending edit instead of recording a no-op.
                    tab.edits[cell.row]?[columnName] = nil
                    if tab.edits[cell.row]?.isEmpty == true { tab.edits[cell.row] = nil }
                } else {
                    tab.edits[cell.row, default: [:]].updateValue(nil, forKey: columnName)
                }
            }
            reload(rows: selectionRows)
            updateInspector()
        }

        /// Mirrors the single selected cell into `tab.inspected` for the value
        /// inspector; clears it when the selection isn't exactly one cell.
        private func updateInspector() {
            guard let result = tab.result, selected.count == 1, let cell = selected.first,
                  cell.col < result.columns.count else {
                if tab.inspected != nil { tab.inspected = nil }
                return
            }
            let row = dataRow(forDisplay: cell.row)
            let column = result.columns[cell.col]
            let value: String?
            if isInsertRow(row) {
                let index = row - fetchedRowCount
                value = index < tab.pendingInserts.count ? tab.pendingInserts[index].values[column.name] : nil
            } else if let edited = tab.edits[row]?[column.name] {
                value = edited
            } else if row < result.rows.count {
                let cells = result.rows[row]
                value = cell.col < cells.count ? cells[cell.col].text : nil
            } else {
                value = nil
            }
            // Diff before writing: a blind set would loop with updateNSView.
            let inspected = InspectedCell(column: column.name, typeName: column.typeName, value: value)
            if tab.inspected != inspected { tab.inspected = inspected }
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
            guard tab.isEditable, visibleRowMap == nil, let tableView, let result, col < result.columns.count else { return }
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

        func rowState(_ displayRow: Int) -> DirtyRowView.State {
            let row = dataRow(forDisplay: displayRow)
            if isInsertRow(row) { return .insert }
            if tab.pendingDeletes.contains(row) { return .delete }
            if tab.edits[row] != nil { return .update }
            return .none
        }

        /// Backspace — removes selected insert rows outright; toggles the deletion
        /// mark (red highlight) on selected fetched rows.
        func deleteSelectedRows() {
            guard tab.isEditable, visibleRowMap == nil else { return }
            let rows = selectionRows
            guard !rows.isEmpty else { return }

            let insertIndices = rows.filter(isInsertRow).map { $0 - fetchedRowCount }.sorted(by: >)
            if !insertIndices.isEmpty {
                for index in insertIndices where index < tab.pendingInserts.count {
                    tab.pendingInserts.remove(at: index)
                }
                selected = selected.filter { !isInsertRow($0.row) }
                anchor = nil; focus = nil
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
            guard tab.isEditable, visibleRowMap == nil else { return }
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
            guard tab.isEditable, visibleRowMap == nil else { return }
            tab.pendingInserts.append(PendingInsert())
            tableView?.reloadData()
            let newRow = fetchedRowCount + tab.pendingInserts.count - 1
            tableView?.scrollRowToVisible(newRow)
        }

        /// Copies a fetched row into a new insert row, dropping DB-generated
        /// (auto-increment) columns so the database assigns fresh values.
        func duplicateRow(_ row: Int) {
            guard tab.isEditable, visibleRowMap == nil, let values = insertValues(from: row) else { return }
            tab.pendingInserts.append(PendingInsert(values: values))
            tableView?.reloadData()
            tableView?.scrollRowToVisible(fetchedRowCount + tab.pendingInserts.count - 1)
        }

        /// ⌘D — duplicates every selected fetched row into new insert rows.
        func duplicateSelectedRows() {
            guard tab.isEditable, visibleRowMap == nil else { return }
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
            guard tab.isEditable, visibleRowMap == nil, let result = tab.result, !selected.isEmpty,
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

        var hasSelection: Bool { !selected.isEmpty }

        /// Escape while the grid (not the search field) has focus — e.g. after
        /// clicking a cell to dismiss the find bar's keyboard focus.
        func cancelSearchIfActive() -> Bool {
            guard tab.isSearchBarVisible else { return false }
            tab.clearSearch()
            return true
        }

        // MARK: Foreign keys

        /// Where a grid column points, when the rows come from a known table and the
        /// schema records a single-column foreign key on it.
        private func foreignKey(forColumn col: Int) -> ForeignKeyTarget? {
            guard let result = tab.result, col < result.columns.count,
                  let schemaName = tab.editSource?.schema ?? tab.dataSchema,
                  let tableName = tab.editSource?.table ?? tab.dataTable,
                  let tree = tab.session?.schema else { return nil }
            let columnName = result.columns[col].name
            return tree.schemas.first { $0.name == schemaName }?
                .tables.first { $0.name == tableName }?
                .columns.first { $0.name == columnName }?
                .references
        }

        /// Title for the "follow this reference" item, or nil when the cell isn't a
        /// foreign key or holds NULL (nothing to look up).
        func foreignKeyTitle(row: Int, col: Int) -> String? {
            guard let target = foreignKey(forColumn: col),
                  let value = cellString(row: row, col: col) else { return nil }
            let shown = value.count > 30 ? value.prefix(30) + "…" : value[...]
            return String(localized: "Open \(target.table) where \(target.column) = \(String(shown))")
        }

        /// ⌘↓ — follows the reference in the one selected cell. Returns false when
        /// there is no single selection or it isn't a foreign key, so the key event
        /// falls through to its normal handling.
        func followSelectedForeignKey() -> Bool {
            guard selected.count == 1, let cell = selected.first,
                  foreignKey(forColumn: cell.col) != nil,
                  cellString(row: cell.row, col: cell.col) != nil else { return false }
            followForeignKey(row: cell.row, col: cell.col)
            return true
        }

        /// Opens the referenced table filtered to the row this cell points at.
        func followForeignKey(row: Int, col: Int) {
            guard let target = foreignKey(forColumn: col), let result = tab.result,
                  col < result.columns.count, let session = tab.session,
                  let value = cellString(row: row, col: col) else { return }
            let literal = SQLTypes.literal(value, typeName: result.columns[col].typeName)
            onFollowForeignKey(target, "\(session.quote(target.column)) = \(literal)")
        }

        /// The raw value of a cell (nil = SQL NULL), preferring a pending edit/insert.
        private func cellString(row: Int, col: Int) -> String? {
            guard let result = tab.result, col < result.columns.count else { return nil }
            let row = dataRow(forDisplay: row)
            let columnName = result.columns[col].name
            if isInsertRow(row) {
                let index = row - fetchedRowCount
                return index < tab.pendingInserts.count ? tab.pendingInserts[index].values[columnName] : nil
            }
            if let edited = tab.edits[row]?[columnName] { return edited }
            guard row < result.rows.count else { return nil }
            let cells = result.rows[row]
            return col < cells.count ? cells[col].text : nil
        }

        /// The selected block as a rectangle: sorted unique rows × sorted unique cols
        /// (the bounding box of the selection), with each cell's value (nil = NULL).
        private func selectionBlock() -> (cols: [Int], rows: [Int])? {
            guard tab.result != nil, !selected.isEmpty else { return nil }
            let cols = Set(selected.map(\.col)).sorted()
            let rows = Set(selected.map(\.row)).sorted()
            return (cols, rows)
        }

        /// ⌘C copies as TSV; the context menu offers CSV / JSON / SQL INSERT.
        func copySelection(as format: GridCopyFormat = .tsv) {
            guard let result = tab.result, let block = selectionBlock() else { return }
            let text: String
            switch format {
            case .tsv:
                // ⌘C honours the exact cells picked (a ⌘-toggled selection can be
                // ragged); the structured formats below use the bounding rectangle.
                text = block.rows.map { row in
                    selected.filter { $0.row == row }.map(\.col).sorted()
                        .map { cellString(row: row, col: $0) ?? "" }.joined(separator: "\t")
                }.joined(separator: "\n")
            case .csv:
                let header = block.cols.map { csvField(result.columns[$0].name) }.joined(separator: ",")
                let body = block.rows.map { row in
                    block.cols.map { csvField(cellString(row: row, col: $0)) }.joined(separator: ",")
                }
                text = ([header] + body).joined(separator: "\n")
            case .json:
                let objects = block.rows.map { row -> [String: Any] in
                    var object: [String: Any] = [:]
                    for col in block.cols {
                        object[result.columns[col].name] = jsonValue(cellString(row: row, col: col), col: col)
                    }
                    return object
                }
                guard let data = try? JSONSerialization.data(withJSONObject: objects,
                                                             options: [.prettyPrinted, .sortedKeys]),
                      let string = String(data: data, encoding: .utf8) else { return }
                text = string
            case .insert:
                let table = tab.editSource.map { "\($0.schema).\($0.table)" }
                    ?? tab.dataTable ?? "table"
                let columnList = block.cols.map { result.columns[$0].name }.joined(separator: ", ")
                text = block.rows.map { row in
                    let values = block.cols.map { sqlLiteral(cellString(row: row, col: $0), col: $0) }
                        .joined(separator: ", ")
                    return "INSERT INTO \(table) (\(columnList)) VALUES (\(values));"
                }.joined(separator: "\n")
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        /// A JSON value for a cell: `null`, a real number for numeric columns (via
        /// `NSDecimalNumber`, so large int8/numeric keep full precision), else a string.
        private func jsonValue(_ value: String?, col: Int) -> Any {
            guard let value else { return NSNull() }
            guard let result = tab.result, col < result.columns.count,
                  isNumericColumnType(result.columns[col].typeName) else { return value }
            if let integer = Int(value) { return integer }
            // POSIX locale so the decimal separator is always ".", not the user's.
            let decimal = NSDecimalNumber(string: value, locale: Locale(identifier: "en_US_POSIX"))
            return decimal == NSDecimalNumber.notANumber ? value : decimal
        }

        private func csvField(_ value: String?) -> String {
            guard let value else { return "" }
            guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
            else { return value }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }

        private func sqlLiteral(_ value: String?, col: Int) -> String {
            let typeName = tab.result.map { col < $0.columns.count ? $0.columns[col].typeName : "" } ?? ""
            return SQLTypes.literal(value, typeName: typeName)
        }

        private var result: QueryResult? { tab.result }

        func configure(for tab: QueryTab) {
            self.tab = tab
            guard let tableView, let result = tab.result else { return }
            visibleRowMap = tab.matchingRowIndices()
            if let grid = tableView as? GridTableView {
                // Editing (and pending-insert rows) is unavailable while a ⌘F filter
                // narrows what's on screen — the row indices it juggles only make
                // sense over the full, unfiltered result.
                grid.canEditRows = tab.isEditable && visibleRowMap == nil
                grid.fetchedRowCount = result.rows.count
            }
            // Reset the cell selection only when the underlying data actually changed
            // (new query / sort / filter / page) — not on the re-render after an edit.
            if tab.resultVersion != lastResultVersion {
                lastResultVersion = tab.resultVersion
                selected = []
                anchor = nil; focus = nil
            }
            // Display row indices shift whenever the ⌘F filter text changes, so a
            // held selection would silently point at the wrong cells.
            if tab.searchQuery != lastSearchQuery {
                lastSearchQuery = tab.searchQuery
                selected = []
                anchor = nil; focus = nil
            }
            let signature = result.columns.map(\.name)
            if signature != columnsSignature {
                columnsSignature = signature
                selected = []
                anchor = nil; focus = nil
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
            // Clearing the inspector here (during updateNSView) would mutate observed
            // state mid-render; defer it, and only if nothing got selected meanwhile.
            if selected.isEmpty, tab.inspected != nil {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.selected.isEmpty, self.tab.inspected != nil else { return }
                    self.tab.inspected = nil
                }
            }

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
            if let visibleRowMap { return visibleRowMap.count }
            return (result?.rows.count ?? 0) + tab.pendingInserts.count
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
                let original = column < cells.count ? cells[column].text : nil
                consider((tab.edits[row]?[name] ?? original) ?? "NULL")
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

            let dataRowIndex = dataRow(forDisplay: row)
            let identifier = NSUserInterfaceItemIdentifier("cell")
            let field = (tableView.makeView(withIdentifier: identifier, owner: self) as? GridTextField)
                ?? makeField(identifier: identifier)
            field.rowIndex = dataRowIndex
            field.columnIndex = columnIndex
            // Cells select on click (edit on double-click), so keep them non-editable here.
            field.isEditable = false
            field.isSelectable = false

            // Selection is tracked in display-row space (it comes straight from
            // mouse events), so compare against the un-mapped `row`, not `dataRowIndex`.
            let selected = isSelected(row: row, col: columnIndex)
            field.drawsBackground = selected
            field.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.30) : .clear

            let columnName = result.columns[columnIndex].name
            // Numbers read better right-aligned; reset font/alignment on every reuse.
            field.alignment = isNumericColumnType(result.columns[columnIndex].typeName) ? .right : .left
            field.font = Self.mono

            if isInsertRow(dataRowIndex) {
                let insertIndex = dataRowIndex - fetchedRowCount
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

            let cells = result.rows[dataRowIndex]
            let original = columnIndex < cells.count ? cells[columnIndex].text : nil
            let value = tab.edits[dataRowIndex]?[columnName] ?? original
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
