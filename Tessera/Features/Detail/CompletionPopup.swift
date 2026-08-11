import AppKit
import DBKit

/// A floating, non-activating list of completion suggestions. It only displays —
/// it never edits the text. The text view drives selection (arrow keys) and commits
/// (Tab/Return); this popup just shows candidates and reports clicks.
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var panel: NSPanel?
    private var tableView: NSTableView?
    private var items: [SQLCompletionItem] = []
    private var selectedIndex = 0

    /// Called when the user clicks a row (commit by mouse).
    var onClickCommit: (() -> Void)?

    private let rowHeight: CGFloat = 20
    private let maxVisibleRows = 10
    private let width: CGFloat = 420

    var isVisible: Bool { panel?.isVisible ?? false }
    var selectedItem: SQLCompletionItem? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }
    /// Index of the highlighted row, for callers that map items back to their own
    /// source list (the grid's reference picker) rather than inserting text.
    var selectedRow: Int { selectedIndex }

    /// Shows the list anchored so its top-left sits at `belowPoint` (screen coords).
    func show(items: [SQLCompletionItem], belowPoint: NSPoint, parent: NSWindow) {
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
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? CompletionRowView)
            ?? {
                let view = CompletionRowView()
                view.identifier = identifier
                return view
            }()
        if items.indices.contains(row) { cell.configure(with: items[row]) }
        return cell
    }
}

/// One suggestion row: kind icon, name, grey detail — with colors that flip when
/// the row is the (emphasized) selection.
private final class CompletionRowView: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        title.lineBreakMode = .byTruncatingTail
        // The name is what matters — let the (grey) detail truncate first.
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentHuggingPriority(.required, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(icon)
        addSubview(title)
        addSubview(detail)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var iconKind: SQLCompletionItem.Kind = .keyword

    func configure(with item: SQLCompletionItem) {
        iconKind = item.kind
        icon.image = NSImage(systemSymbolName: Self.symbol(for: item.kind), accessibilityDescription: nil)
        title.stringValue = item.label
        detail.stringValue = item.detail ?? ""
        applyColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let emphasized = backgroundStyle == .emphasized
        title.textColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
        detail.textColor = emphasized
            ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.75)
            : .secondaryLabelColor
        icon.contentTintColor = emphasized
            ? .alternateSelectedControlTextColor
            : Self.tint(for: iconKind)
    }

    private static func symbol(for kind: SQLCompletionItem.Kind) -> String {
        switch kind {
        case .keyword: "textformat"
        case .function: "function"
        case .table: "tablecells"
        case .column: "rectangle.split.3x1"
        case .schema: "circle.grid.2x2"
        case .join: "arrow.triangle.branch"
        }
    }

    private static func tint(for kind: SQLCompletionItem.Kind) -> NSColor {
        switch kind {
        case .keyword: .systemPink
        case .function: .systemBlue
        case .table: .systemTeal
        case .column: .secondaryLabelColor
        case .schema: .systemPurple
        case .join: .systemOrange
        }
    }
}
