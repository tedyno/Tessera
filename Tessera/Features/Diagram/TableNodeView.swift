import AppKit
import DBKit

/// One entity box on the ER canvas: table name header + column rows with
/// PK/FK markers. Pure drawing — the canvas owns all mouse handling, so hit
/// testing is disabled here.
final class TableNodeView: NSView {
    static let headerHeight: CGFloat = 26
    static let rowHeight: CGFloat = 18
    static let hPadding: CGFloat = 8
    static let iconWidth: CGFloat = 14
    /// Column rows rendered before the "… N more" line takes over.
    static let maxRows = 20

    private static let headerFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let nameFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let typeFont = NSFont.systemFont(ofSize: 10)

    let table: SchemaTable
    var isSelected = false {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }
    /// Compact mode: only PK/FK rows, the rest collapses into the count line.
    var keysOnly = false {
        didSet { if keysOnly != oldValue { needsDisplay = true } }
    }

    init(table: SchemaTable) {
        self.table = table
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override var isFlipped: Bool { true }
    /// The canvas resolves clicks itself (selection, dragging, double-click).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Rows actually rendered; the rest collapses into the trailing count line.
    static func displayedColumns(for table: SchemaTable, keysOnly: Bool) -> [SchemaColumn] {
        let source = keysOnly
            ? table.columns.filter { $0.isPrimaryKey || $0.isForeignKey }
            : table.columns
        return Array(source.prefix(maxRows))
    }

    private static func hiddenCount(for table: SchemaTable, keysOnly: Bool) -> Int {
        table.columns.count - displayedColumns(for: table, keysOnly: keysOnly).count
    }

    static func preferredSize(for table: SchemaTable, keysOnly: Bool) -> CGSize {
        var width = (table.name as NSString).size(withAttributes: [.font: headerFont]).width
        let displayed = displayedColumns(for: table, keysOnly: keysOnly)
        for column in displayed {
            let name = (column.name as NSString).size(withAttributes: [.font: nameFont]).width
            let type = (column.dataType as NSString).size(withAttributes: [.font: typeFont]).width
            width = max(width, iconWidth + name + 12 + type)
        }
        let rows = CGFloat(displayed.count + (hiddenCount(for: table, keysOnly: keysOnly) > 0 ? 1 : 0))
        return CGSize(width: min(max(width + 2 * hPadding, 160), 280),
                      height: headerHeight + max(rows, 1) * rowHeight + 6)
    }

    /// Vertical midline of a column's row, for edge attachment; columns hidden
    /// behind the overflow line (or unknown) anchor at the header instead.
    static func anchorY(forColumn name: String, in table: SchemaTable, keysOnly: Bool) -> CGFloat {
        guard let index = displayedColumns(for: table, keysOnly: keysOnly)
            .firstIndex(where: { $0.name == name }) else { return headerHeight / 2 }
        return headerHeight + CGFloat(index) * rowHeight + rowHeight / 2
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)

        NSColor.controlBackgroundColor.setFill()
        card.fill()

        NSGraphicsContext.current?.saveGraphicsState()
        card.addClip()
        headerColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        let title = table.name as NSString
        title.draw(
            at: NSPoint(x: Self.hPadding,
                        y: (Self.headerHeight - Self.headerFont.capHeight) / 2 - 4),
            withAttributes: [.font: Self.headerFont, .foregroundColor: NSColor.labelColor])

        var y = Self.headerHeight
        for column in Self.displayedColumns(for: table, keysOnly: keysOnly) {
            drawRow(column, atY: y)
            y += Self.rowHeight
        }
        let hidden = table.columns.count
            - Self.displayedColumns(for: table, keysOnly: keysOnly).count
        if hidden > 0 {
            let more = String(localized: "\(hidden) more columns") as NSString
            more.draw(at: NSPoint(x: Self.hPadding + Self.iconWidth, y: y + 2),
                      withAttributes: [.font: Self.typeFont,
                                       .foregroundColor: NSColor.tertiaryLabelColor])
        }

        card.lineWidth = isSelected ? 2 : 1
        (isSelected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        card.stroke()
    }

    private var headerColor: NSColor {
        table.kind == .view
            ? NSColor.systemPurple.withAlphaComponent(0.18)
            : NSColor.windowBackgroundColor
    }

    private func drawRow(_ column: SchemaColumn, atY y: CGFloat) {
        if let icon = rowIcon(for: column) {
            let size: CGFloat = 10
            icon.draw(in: NSRect(x: Self.hPadding, y: y + (Self.rowHeight - size) / 2,
                                 width: size, height: size))
        }
        let name = column.name as NSString
        name.draw(at: NSPoint(x: Self.hPadding + Self.iconWidth, y: y + 2),
                  withAttributes: [.font: Self.nameFont,
                                   .foregroundColor: NSColor.labelColor])

        let type = column.dataType as NSString
        let typeWidth = type.size(withAttributes: [.font: Self.typeFont]).width
        type.draw(at: NSPoint(x: bounds.width - Self.hPadding - typeWidth, y: y + 3),
                  withAttributes: [.font: Self.typeFont,
                                   .foregroundColor: NSColor.secondaryLabelColor])
    }

    private func rowIcon(for column: SchemaColumn) -> NSImage? {
        // Both key kinds share the key glyph; color tells them apart (and a
        // column that is both PK and FK shows the PK gold).
        let color: NSColor
        if column.isPrimaryKey {
            color = .systemOrange
        } else if column.isForeignKey {
            color = .systemTeal
        } else {
            return nil
        }
        let image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [color]))
        return image
    }
}
