import AppKit

/// A floating, non-activating list of completion suggestions. It only displays —
/// it never edits the text. The text view drives selection (arrow keys) and commits
/// (Tab); this popup just shows candidates and reports clicks.
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var panel: NSPanel?
    private var tableView: NSTableView?
    private var items: [String] = []
    private var selectedIndex = 0

    /// Called when the user clicks a row (commit by mouse).
    var onClickCommit: (() -> Void)?

    private let rowHeight: CGFloat = 18
    private let maxVisibleRows = 10
    private let width: CGFloat = 260

    var isVisible: Bool { panel?.isVisible ?? false }
    var selectedItem: String? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }

    /// Shows the list anchored so its top-left sits at `belowPoint` (screen coords).
    func show(items: [String], belowPoint: NSPoint, parent: NSWindow) {
        self.items = items
        selectedIndex = 0
        let panel = panel ?? makePanel()
        self.panel = panel

        let height = min(CGFloat(items.count), CGFloat(maxVisibleRows)) * rowHeight + 2
        panel.setContentSize(NSSize(width: width, height: height))
        panel.setFrameTopLeftPoint(belowPoint)

        tableView?.reloadData()
        select(0)

        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        select((selectedIndex + delta + items.count) % items.count)
    }

    private func select(_ index: Int) {
        selectedIndex = index
        tableView?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView?.scrollRowToVisible(index)
    }

    // MARK: Building

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 100),
                            styleMask: [.nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isMovable = false
        panel.backgroundColor = .clear

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.borderType = .lineBorder
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 5

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = rowHeight
        table.backgroundColor = .controlBackgroundColor
        table.selectionHighlightStyle = .regular
        table.intercellSpacing = NSSize(width: 0, height: 0)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        column.width = width - 4
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)

        scrollView.documentView = table
        panel.contentView = scrollView
        tableView = table
        return panel
    }

    @objc private func rowClicked() {
        guard let row = tableView?.clickedRow, row >= 0 else { return }
        selectedIndex = row
        onClickCommit?()
    }

    // MARK: Table data

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let field = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField)
            ?? {
                let f = NSTextField(labelWithString: "")
                f.identifier = identifier
                f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                f.lineBreakMode = .byTruncatingTail
                f.drawsBackground = false
                return f
            }()
        field.stringValue = items.indices.contains(row) ? items[row] : ""
        return field
    }
}
