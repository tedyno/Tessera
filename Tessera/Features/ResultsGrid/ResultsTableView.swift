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

/// NSTableView that routes ⌘C/⌘V to the coordinator for multi-cell copy/paste.
final class GridTableView: NSTableView {
    var onPaste: (() -> Void)?
    var onCopy: (() -> Void)?
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
        tableView.allowsMultipleSelection = true
        tableView.rowHeight = 18
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.action = #selector(Coordinator.tableClicked)
        tableView.onPaste = { [coordinator = context.coordinator] in coordinator.pasteIntoSelection() }
        tableView.onCopy = { [coordinator = context.coordinator] in coordinator.copySelection() }

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
        /// The column last clicked; multi-paste targets this column.
        private var focusedColumn = 0

        init(tab: QueryTab) { self.tab = tab }

        @objc func tableClicked() {
            if let column = tableView?.clickedColumn, column >= 0 { focusedColumn = column }
        }

        /// ⌘V — writes the clipboard string into `focusedColumn` for every selected row.
        func pasteIntoSelection() {
            guard tab.isEditable, let result = tab.result, let tableView,
                  focusedColumn < result.columns.count,
                  let value = NSPasteboard.general.string(forType: .string) else { return }
            let rows = tableView.selectedRowIndexes
            guard !rows.isEmpty else { return }
            let columnName = result.columns[focusedColumn].name
            for row in rows where row < result.rows.count {
                let original = focusedColumn < result.rows[row].count ? result.rows[row][focusedColumn].text : nil
                if value == (original ?? "") {
                    tab.edits[row]?[columnName] = nil
                    if tab.edits[row]?.isEmpty == true { tab.edits[row] = nil }
                } else {
                    tab.edits[row, default: [:]][columnName] = value
                }
            }
            tableView.reloadData(forRowIndexes: rows,
                                 columnIndexes: IndexSet(integersIn: 0..<result.columns.count))
        }

        /// ⌘C — copies `focusedColumn` values of the selected rows (newline-separated).
        func copySelection() {
            guard let result = tab.result, let tableView, focusedColumn < result.columns.count else { return }
            let rows = tableView.selectedRowIndexes
            guard !rows.isEmpty else { return }
            let columnName = result.columns[focusedColumn].name
            let lines = rows.map { row -> String in
                if let edited = tab.edits[row]?[columnName] { return edited }
                let cells = result.rows[row]
                return (focusedColumn < cells.count ? cells[focusedColumn].text : nil) ?? ""
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
            field.isEditable = tab.isEditable

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
