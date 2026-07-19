import SwiftUI
import AppKit
import DBKit

/// Row view that tints its background when the row has unsaved edits.
final class DirtyRowView: NSTableRowView {
    var isDirty = false
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isDirty {
            NSColor.systemYellow.withAlphaComponent(0.18).setFill()
            dirtyRect.fill()
        }
    }
}

/// Editable text field that remembers its grid coordinates.
final class GridTextField: NSTextField {
    var rowIndex = -1
    var columnIndex = -1
}

struct CellPos: Hashable { let row: Int; let col: Int }

/// NSTableView with spreadsheet-style cell selection: click/drag selects a
/// rectangular block of cells, double-click edits, ⌘C/⌘V copy/paste the block.
final class GridTableView: NSTableView {
    var onSelect: ((Int, Int, Bool) -> Void)?   // row, col, extend
    var onBeginEdit: ((Int, Int) -> Void)?
    var onPaste: (() -> Void)?
    var onCopy: (() -> Void)?

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
        onSelect?(row, col, event.modifierFlags.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let col = self.column(at: point)
        if row >= 0, col >= 0 { onSelect?(row, col, true) }
    }

    @objc func paste(_ sender: Any?) { onPaste?() }
    @objc func copy(_ sender: Any?) { onCopy?() }
}

/// Virtualized results grid backed by `NSTableView`. When the result maps to a
/// single table (`tab.editSource`), cells are editable: edits are tracked in
/// `tab.edits`, edited rows are highlighted, and ⌘↩ persists them via UPDATE.
struct ResultsTableView: NSViewRepresentable {
    let tab: QueryTab

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = GridTableView()
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = false
        tableView.rowHeight = 18
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.onSelect = { [c = context.coordinator] row, col, extend in c.selectCell(row: row, col: col, extend: extend) }
        tableView.onBeginEdit = { [c = context.coordinator] row, col in c.beginEdit(row: row, col: col) }
        tableView.onPaste = { [c = context.coordinator] in c.pasteIntoSelection() }
        tableView.onCopy = { [c = context.coordinator] in c.copySelection() }

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        context.coordinator.tableView = tableView
        context.coordinator.configure(for: tab)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.configure(for: tab)
    }

    func makeCoordinator() -> Coordinator { Coordinator(tab: tab) }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        private var tab: QueryTab
        weak var tableView: NSTableView?
        private var columnsSignature: [String] = []
        private var anchor: CellPos?
        private var focus: CellPos?

        init(tab: QueryTab) { self.tab = tab }

        // MARK: Cell selection

        private var selectionRows: IndexSet {
            guard let anchor, let focus else { return [] }
            return IndexSet(integersIn: min(anchor.row, focus.row)...max(anchor.row, focus.row))
        }
        private var selectionCols: ClosedRange<Int>? {
            guard let anchor, let focus else { return nil }
            return min(anchor.col, focus.col)...max(anchor.col, focus.col)
        }
        func isSelected(row: Int, col: Int) -> Bool {
            guard let cols = selectionCols else { return false }
            return selectionRows.contains(row) && cols.contains(col)
        }

        func selectCell(row: Int, col: Int, extend: Bool) {
            let old = selectionRows
            if extend, anchor != nil {
                focus = CellPos(row: row, col: col)
            } else {
                anchor = CellPos(row: row, col: col)
                focus = anchor
            }
            reload(rows: old.union(selectionRows))
        }

        func beginEdit(row: Int, col: Int) {
            guard tab.isEditable, let tableView else { return }
            anchor = CellPos(row: row, col: col); focus = anchor
            if let field = tableView.view(atColumn: col, row: row, makeIfNecessary: true) as? GridTextField {
                field.isEditable = true
                tableView.editColumn(col, row: row, with: nil, select: true)
            }
        }

        private func reload(rows: IndexSet) {
            guard let tableView, let result = tab.result else { return }
            tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<result.columns.count))
        }

        /// ⌘V — writes the clipboard string into every selected cell.
        func pasteIntoSelection() {
            guard tab.isEditable, let result = tab.result, let cols = selectionCols,
                  let value = NSPasteboard.general.string(forType: .string) else { return }
            let rows = selectionRows
            guard !rows.isEmpty else { return }
            for row in rows where row < result.rows.count {
                for col in cols where col < result.columns.count {
                    let columnName = result.columns[col].name
                    let original = col < result.rows[row].count ? result.rows[row][col].text : nil
                    if value == (original ?? "") {
                        tab.edits[row]?[columnName] = nil
                        if tab.edits[row]?.isEmpty == true { tab.edits[row] = nil }
                    } else {
                        tab.edits[row, default: [:]][columnName] = value
                    }
                }
            }
            reload(rows: rows)
        }

        /// ⌘C — copies the selected block (tab/newline separated).
        func copySelection() {
            guard let result = tab.result, let cols = selectionCols else { return }
            let rows = selectionRows
            guard !rows.isEmpty else { return }
            let lines = rows.map { row -> String in
                cols.map { col -> String in
                    if let edited = tab.edits[row]?[result.columns[col].name] { return edited }
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
            let signature = result.columns.map(\.name)
            if signature != columnsSignature {
                columnsSignature = signature
                anchor = nil
                focus = nil
                for column in tableView.tableColumns { tableView.removeTableColumn(column) }
                for (index, descriptor) in result.columns.enumerated() {
                    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
                    column.title = descriptor.name
                    column.width = 150
                    column.minWidth = 40
                    tableView.addTableColumn(column)
                }
            }
            tableView.reloadData()

            // Scroll a requested column into view (from a schema column double-click).
            if let target = tab.scrollToColumn,
               let index = result.columns.firstIndex(where: { $0.name == target }) {
                tableView.scrollColumnToVisible(index)
                let editedTab = tab
                DispatchQueue.main.async { editedTab.scrollToColumn = nil }
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { result?.rows.count ?? 0 }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = DirtyRowView()
            rowView.isDirty = tab.edits[row] != nil
            return rowView
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let result,
                  let columnIndex = Int(tableColumn.identifier.rawValue), row < result.rows.count else { return nil }

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
            let cells = result.rows[row]
            let original = columnIndex < cells.count ? cells[columnIndex].text : nil
            let value = tab.edits[row]?[columnName] ?? original
            if let value {
                field.stringValue = value
                field.textColor = .labelColor
            } else {
                field.stringValue = "NULL"
                field.textColor = .tertiaryLabelColor
            }
            return field
        }

        private func makeField(identifier: NSUserInterfaceItemIdentifier) -> GridTextField {
            let field = GridTextField(labelWithString: "")
            field.identifier = identifier
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.lineBreakMode = .byTruncatingTail
            field.isBordered = false
            field.drawsBackground = false
            field.delegate = self
            field.cell?.usesSingleLineMode = true
            return field
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? GridTextField,
                  let result, field.rowIndex >= 0, field.rowIndex < result.rows.count,
                  field.columnIndex < result.columns.count else { return }
            let row = field.rowIndex
            let columnName = result.columns[field.columnIndex].name
            let original = field.columnIndex < result.rows[row].count ? result.rows[row][field.columnIndex].text : nil
            let newValue = field.stringValue

            if newValue == (original ?? "NULL") || newValue == original {
                tab.edits[row]?[columnName] = nil
                if tab.edits[row]?.isEmpty == true { tab.edits[row] = nil }
            } else {
                tab.edits[row, default: [:]][columnName] = newValue
            }
            let editedRow = row
            DispatchQueue.main.async { [weak self] in
                self?.tableView?.reloadData(forRowIndexes: IndexSet(integer: editedRow),
                                            columnIndexes: IndexSet(integersIn: 0..<(self?.result?.columns.count ?? 0)))
            }
        }
    }
}
