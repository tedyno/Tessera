import SwiftUI
import AppKit
import DBKit

/// Virtualized results grid backed by `NSTableView` (recycles cell views), so it
/// stays smooth with large result sets where SwiftUI's `Table` struggles. Columns
/// are rebuilt from the `QueryResult` at runtime.
struct ResultsTableView: NSViewRepresentable {
    let result: QueryResult

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = false
        tableView.rowHeight = 18
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        context.coordinator.tableView = tableView
        context.coordinator.configure(for: result)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.configure(for: result)
    }

    func makeCoordinator() -> Coordinator { Coordinator(result: result) }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var result: QueryResult
        weak var tableView: NSTableView?
        private var columnsSignature: [String] = []

        init(result: QueryResult) { self.result = result }

        func configure(for result: QueryResult) {
            self.result = result
            guard let tableView else { return }
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
        }

        func numberOfRows(in tableView: NSTableView) -> Int { result.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn,
                  let columnIndex = Int(tableColumn.identifier.rawValue),
                  row < result.rows.count else { return nil }

            let cells = result.rows[row]
            let cell = columnIndex < cells.count ? cells[columnIndex] : Cell.null

            let identifier = NSUserInterfaceItemIdentifier("cell")
            let field: NSTextField
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
                field = reused
            } else {
                field = NSTextField(labelWithString: "")
                field.identifier = identifier
                field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                field.lineBreakMode = .byTruncatingTail
                field.cell?.usesSingleLineMode = true
            }

            if let text = cell.text {
                field.stringValue = text
                field.textColor = .labelColor
            } else {
                field.stringValue = "NULL"
                field.textColor = .tertiaryLabelColor
            }
            return field
        }
    }
}
