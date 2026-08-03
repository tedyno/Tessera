import SwiftUI
import AppKit
import DBKit

/// Row view tinted by its pending change: orange = update, red = delete.
final class DirtyRowView: NSTableRowView {
    enum State { case none, update, delete, insert }
    var state: State = .none

    /// Cell views keep their text-sized height, which reads as gaps between
    /// rows in the comfortable density — stretch them to the full row height
    /// (the centred text cell keeps the glyphs on the middle line).
    override func layout() {
        super.layout()
        for view in subviews {
            var frame = view.frame
            if frame.height != bounds.height {
                frame.origin.y = 0
                frame.size.height = bounds.height
                view.frame = frame
            }
        }
    }

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

/// Vertically centres single-line text when the cell is taller than the text
/// (comfortable row density) — the default cell pins it to the top.
final class CenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var inset = super.drawingRect(forBounds: rect)
        let height = cellSize(forBounds: rect).height
        if inset.height > height {
            inset.origin.y += (inset.height - height) / 2
            inset.size.height = height
        }
        return inset
    }

    /// Editing uses the raw cell frame, pinning the field editor's text to the
    /// top — hand it the same centred rect drawing uses.
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView,
                   editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView,
                     editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }

    /// The default implementation fills the background only inside
    /// `drawingRect` — shrunk to the text line above — which left the
    /// selection highlight as a thin band. Fill the whole cell frame instead.
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        if drawsBackground, let backgroundColor {
            backgroundColor.setFill()
            cellFrame.fill()
            drawsBackground = false
            drawInterior(withFrame: cellFrame, in: controlView)
            drawsBackground = true
            return
        }
        drawInterior(withFrame: cellFrame, in: controlView)
    }
}

/// Column header showing the name followed by its SQL type in small grey text, on
/// one line so it always stays within the standard header height.
final class TypedHeaderCell: NSTableHeaderCell {
    var typeName = ""
    /// Accent-tints the name while a local value filter is active.
    var isFiltered = false

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        // No system bezel: the header stays transparent over the gradient
        // backdrop, separated from the rows by a hairline.
        NSColor.separatorColor.withAlphaComponent(0.6).setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1,
               width: cellFrame.width, height: 1).fill()
        drawTitle(in: cellFrame)
    }

    private func drawTitle(in cellFrame: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: stringValue, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: isFiltered ? NSColor.controlAccentColor : NSColor.labelColor,
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
    /// that one column and shows only the plain name, dropping the type. The
    /// pressed state gets a subtle translucent fill instead of system chrome.
    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
        if flag {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            cellFrame.fill()
        }
        draw(withFrame: cellFrame, in: controlView)
    }
}

/// Header strip without the opaque system background: only the (transparent)
/// column cells and the sort-indicator arrow draw, so the app's gradient
/// backdrop shows through the header like everywhere else.
final class ClearHeaderView: NSTableHeaderView {
    /// Builds the right-click menu for a column (local filter entry).
    var menuProvider: ((Int) -> NSMenu?)?
    /// Column index → 1-based sort priority, drawn next to the arrow when a
    /// multi-column sort is active (empty otherwise).
    var sortPriorities: [Int: Int] = [:]

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return menuProvider?(column(at: point)) ?? super.menu(for: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let tableView else { return }
        // Rows scroll *under* the header — a fully transparent header lets them
        // bleed through the labels. Near-opaque in the chosen backdrop's own base
        // colour, so the header tracks whichever theme is active (a fixed navy
        // would clash with every non-Aurora backdrop).
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let base = BackdropStyle.current.baseColor(for: dark ? .dark : .light)
        NSColor(base).withAlphaComponent(0.94).setFill()
        dirtyRect.fill()
        for (index, column) in tableView.tableColumns.enumerated() {
            let rect = headerRect(ofColumn: index)
            guard rect.intersects(dirtyRect) else { continue }
            column.headerCell.draw(withFrame: rect, in: self)
            if let image = tableView.indicatorImage(in: column) {
                // The system indicator is a template image — tint it, or it
                // renders black on the dark backdrop.
                let size = image.size
                let tinted = NSImage(size: size, flipped: false) { frame in
                    image.draw(in: frame)
                    NSColor.secondaryLabelColor.set()
                    frame.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: rect.maxX - size.width - 5,
                                       y: rect.midY - size.height / 2,
                                       width: size.width, height: size.height),
                            from: .zero, operation: .sourceOver, fraction: 1,
                            respectFlipped: true, hints: nil)
                // Priority number for a multi-column sort, just left of the arrow.
                if let rank = sortPriorities[index] {
                    let badge = NSAttributedString(string: String(rank), attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold),
                        .foregroundColor: NSColor.secondaryLabelColor])
                    let badgeSize = badge.size()
                    badge.draw(at: NSPoint(x: rect.maxX - size.width - 6 - badgeSize.width,
                                           y: rect.midY - badgeSize.height / 2))
                }
            }
        }
    }
}

struct CellPos: Hashable { let row: Int; let col: Int }

/// Numeric columns are right-aligned and copied unquoted; the classification is
/// shared with the MCP server so both agree on what a number is.
private func isNumericColumnType(_ typeName: String) -> Bool {
    SQLTypes.isNumeric(typeName)
}

/// Date/time columns route their editing through the value-editor sheet,
/// which offers the date picker next to the raw text.
func isTemporalColumnType(_ typeName: String) -> Bool {
    let type = typeName.lowercased()
    return type.contains("timestamp") || type.contains("datetime")
        || type == "date" || type.hasPrefix("time")
}

/// Clipboard formats offered by the grid's "Copy as" menu.
enum GridCopyFormat { case tsv, csv, json, insert }

/// NSTableView with spreadsheet-style cell selection: click/drag selects a
/// rectangular block of cells, double-click edits, ⌘C/⌘V copy/paste the block.
final class GridTableView: NSTableView {
    var onSelect: ((Int, Int, Bool, Bool) -> Void)?   // row, col, extend(shift), toggle(cmd)
    /// Clicking the grid gives its pane focus (tiled layout).
    var onFocus: (() -> Void)?
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
    /// Returns false when there's nothing to move over (empty grid) so the key can
    /// keep its normal meaning (e.g. Tab cycling window focus).
    var onMoveSelection: ((Int, Int, Bool) -> Bool)?
    /// Return — starts editing the single selected cell; false when it can't.
    var onEditSelected: (() -> Bool)?
    /// ⌥⌫ / context menu — sets every selected cell to SQL NULL.
    var onSetNull: (() -> Void)?
    /// ⌘Z / ⇧⌘Z over the grid's pending changes; false = nothing to undo/redo.
    var onUndo: (() -> Bool)?
    var onRedo: (() -> Bool)?
    var hasUndo: (() -> Bool)?
    var hasRedo: (() -> Bool)?
    /// Typing a printable character on a cell starts editing it, spreadsheet-style,
    /// with the typed text replacing the value; false = not applicable, keep the beep.
    var onTypeToEdit: ((String) -> Bool)?
    /// ⇧↩ — opens the multiline value editor for the single selected cell.
    var onOpenValueEditor: (() -> Bool)?
    /// Context menu: opens the value editor for a clicked cell; the title callback
    /// says "Edit Value…" or "View Value…" (nil = result rows can't be inspected).
    var onOpenValueEditorAt: ((Int, Int) -> Void)?
    var valueEditorMenuTitle: ((Int, Int) -> String?)?

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 123: if onMoveSelection?(0, -1, shift) != true { super.keyDown(with: event) }   // ←
        case 124: if onMoveSelection?(0, 1, shift) != true { super.keyDown(with: event) }    // →
        case 125: if onMoveSelection?(1, 0, shift) != true { super.keyDown(with: event) }    // ↓
        case 126: if onMoveSelection?(-1, 0, shift) != true { super.keyDown(with: event) }   // ↑
        case 48:  // tab / ⇧-tab — keeps focus-cycling when the grid has nothing to move over
            if onMoveSelection?(0, shift ? -1 : 1, false) != true { super.keyDown(with: event) }
        case 36:  // return — edit in cell; ⇧↩ opens the multiline value editor
            if shift {
                if onOpenValueEditor?() != true { super.keyDown(with: event) }
            } else if onEditSelected?() != true {
                super.keyDown(with: event)
            }
        case 53:  // escape
            if onEscape?() != true { super.keyDown(with: event) }
        case 51 where event.modifierFlags.contains(.option):   // ⌥⌫ — set NULL
            onSetNull?()
        case 51, 117: // delete / forward-delete
            onDeleteRows?()
        default:
            if isTypedText(event), let text = event.characters, onTypeToEdit?(text) == true { return }
            super.keyDown(with: event)
        }
    }

    /// Whether the event is a plain printable keystroke (no ⌘/⌃, not a function or
    /// control key) — the kind that should start a spreadsheet-style cell edit.
    private func isTypedText(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.function),
              let scalar = event.characters?.unicodeScalars.first else { return false }
        return !CharacterSet.controlCharacters.contains(scalar)
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
        // ⌘Z / ⇧⌘Z undo the grid's pending changes while it's focused; when there's
        // nothing to undo they fall through to the regular responder chain.
        if canEditRows, isFocused, event.charactersIgnoringModifiers?.lowercased() == "z" {
            if modifiers == .command, onUndo?() == true { return true }
            if modifiers == [.command, .shift], onRedo?() == true { return true }
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

        if row >= 0, clickedColumn >= 0, let title = valueEditorMenuTitle?(row, clickedColumn) {
            let item = NSMenuItem(title: title, action: #selector(openValueEditorAction(_:)),
                                  keyEquivalent: "\r")
            item.keyEquivalentModifierMask = .shift
            item.target = self
            item.representedObject = CellPos(row: row, col: clickedColumn)
            menu.addItem(item)
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
        if hasUndo?() == true {
            let undo = NSMenuItem(title: String(localized: "Undo Edit"), action: #selector(undoAction), keyEquivalent: "z")
            undo.keyEquivalentModifierMask = .command
            undo.target = self
            menu.addItem(undo)
        }
        if hasRedo?() == true {
            let redo = NSMenuItem(title: String(localized: "Redo Edit"), action: #selector(redoAction), keyEquivalent: "z")
            redo.keyEquivalentModifierMask = [.command, .shift]
            redo.target = self
            menu.addItem(redo)
        }
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
    @objc private func undoAction() { _ = onUndo?() }
    @objc private func redoAction() { _ = onRedo?() }
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
    @objc private func openValueEditorAction(_ sender: NSMenuItem) {
        guard let pos = sender.representedObject as? CellPos else { return }
        onOpenValueEditorAt?(pos.row, pos.col)
    }

    @objc private func followForeignKeyAction(_ sender: NSMenuItem) {
        if let cell = sender.representedObject as? CellPos { onFollowForeignKey?(cell.row, cell.col) }
    }

    /// The cell the last drag-select event targeted, so a drag that stays within
    /// one cell doesn't rebuild the whole rectangular selection on every mouse move.
    private var lastDragCell: CellPos?

    override func mouseDown(with event: NSEvent) {
        onFocus?()   // give this pane focus in a tiled layout
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let col = self.column(at: point)
        guard row >= 0, col >= 0 else { super.mouseDown(with: event); return }
        window?.makeFirstResponder(self)
        lastDragCell = CellPos(row: row, col: col)
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
        guard row >= 0, col >= 0 else { return }
        // Extending the selection rebuilds a Set of every enclosed cell; skip it
        // while the pointer is still inside the cell it last targeted.
        let cell = CellPos(row: row, col: col)
        guard cell != lastDragCell else { return }
        lastDragCell = cell
        onSelect?(row, col, true, false)
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
    /// Discards this tab's uncommitted edits — bound to Escape when they exist.
    var onDiscardPending: () -> Void = {}
    /// Clicking the grid gives its pane focus (tiled layout).
    var onFocus: () -> Void = {}
    /// Row height: 18 (compact) or 24 (comfortable), from the density toggle.
    var rowHeight: CGFloat = 18

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = GridTableView()
        tableView.style = .inset
        // Transparent grid: the app's gradient backdrop shows through, with
        // hand-rolled translucent zebra striping (the system's alternating
        // colours are opaque).
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        let headerView = ClearHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: 24))
        headerView.menuProvider = { [c = context.coordinator] column in
            c.headerMenu(column: column)
        }
        tableView.headerView = headerView
        // Let the last column fill any trailing space so its header (name + type)
        // never floats over an empty area with no data column beneath it.
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = false
        tableView.rowHeight = rowHeight
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.onFocus = onFocus
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
        tableView.onEscape = { [c = context.coordinator] in c.handleEscape() }
        tableView.onMoveSelection = { [c = context.coordinator] dRow, dCol, extend in
            c.moveSelection(dRow: dRow, dCol: dCol, extend: extend)
        }
        tableView.onEditSelected = { [c = context.coordinator] in c.editSelectedCell() }
        tableView.onTypeToEdit = { [c = context.coordinator] text in c.typeToEdit(text) }
        tableView.onOpenValueEditor = { [c = context.coordinator] in c.openValueEditorForSelection() }
        tableView.onOpenValueEditorAt = { [c = context.coordinator] row, col in
            c.openValueEditor(row: row, col: col)
        }
        tableView.valueEditorMenuTitle = { [c = context.coordinator] row, col in
            c.valueEditorMenuTitle(row: row, col: col)
        }
        tableView.onSetNull = { [c = context.coordinator] in c.setSelectedToNull() }
        tableView.onUndo = { [c = context.coordinator] in c.undoEdits() }
        tableView.onRedo = { [c = context.coordinator] in c.redoEdits() }
        tableView.hasUndo = { [c = context.coordinator] in c.tabCanUndo }
        tableView.hasRedo = { [c = context.coordinator] in c.tabCanRedo }

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        // Late width: the first configure happens before layout gives the clip
        // its real size, so re-spread the columns when the frame settles.
        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.scrollFrameChanged(_:)),
            name: NSView.frameDidChangeNotification, object: scrollView)

        context.coordinator.tableView = tableView
        context.coordinator.onSort = onSort
        context.coordinator.onFollowForeignKey = onFollowForeignKey
        context.coordinator.onDiscardPending = onDiscardPending
        context.coordinator.installEscapeMonitor()
        context.coordinator.configure(for: tab)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        (nsView.documentView as? GridTableView)?.onFocus = onFocus
        context.coordinator.onSort = onSort
        context.coordinator.onFollowForeignKey = onFollowForeignKey
        context.coordinator.onDiscardPending = onDiscardPending
        if let table = nsView.documentView as? NSTableView, table.rowHeight != rowHeight,
           !context.coordinator.isEditingActive {
            table.rowHeight = rowHeight
            table.reloadData()
        }
        context.coordinator.configure(for: tab)
    }

    func makeCoordinator() -> Coordinator { Coordinator(tab: tab) }

    /// The grid is being torn down (tab/window closed): release the app-wide
    /// event monitor and popovers, or they'd outlive the coordinator.
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        private var tab: QueryTab
        weak var tableView: NSTableView?
        var onSort: (String) -> Void = { _ in }
        var onFollowForeignKey: (ForeignKeyTarget, String) -> Void = { _, _ in }
        var onDiscardPending: () -> Void = {}
        static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        static let monoItalic = NSFontManager.shared.convert(mono, toHaveTrait: .italicFontMask)
        private var columnsSignature: [String] = []
        private var lastResultVersion = -1
        private var lastSearchQuery = ""
        private var lastValueFilters: [String: Set<String?>] = [:]
        private var lastLocalSortColumn: Int?
        private var lastLocalSortAscending = true
        private var lastFingerprint: Int?
        /// True while a cell edit session is live — configure() must not reload the
        /// table then (the live-preview mutations would otherwise retrigger it and
        /// kill the very session that made them).
        private(set) var isEditingActive = false
        private var selected: Set<CellPos> = []
        private var anchor: CellPos?
        /// The cell arrow keys move from — the last cell clicked or stepped onto
        /// (unlike `anchor`, which stays put while Shift extends a range from it).
        private var focus: CellPos?
        /// Data-row indices shown, in display order, while a ⌘F filter is active;
        /// nil when unfiltered (display row == data row).
        private var visibleRowMap: [Int]?

        /// Everything `visibleRowMap` depends on. `configure` recomputes the map
        /// only when this changes, so purely visual mutations (selection, hover,
        /// inspector) don't trigger a full-result rescan.
        private struct VisibleMapKey: Equatable {
            var tab: ObjectIdentifier
            var searchQuery: String
            var valueFilters: [String: Set<String?>]
            var sortColumn: Int?
            var sortAscending: Bool
            var resultVersion: Int
        }
        private var lastVisibleMapKey: VisibleMapKey?

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
        /// False = empty grid, let the key keep its normal meaning.
        @discardableResult
        func moveSelection(dRow: Int, dCol: Int, extend: Bool) -> Bool {
            guard let tableView, let result = tab.result, !result.columns.isEmpty else { return false }
            let rowCount = visibleRowMap?.count ?? (result.rows.count + tab.pendingInserts.count)
            guard rowCount > 0 else { return false }
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
            return true
        }

        /// Return — starts editing the focused cell when there's exactly one
        /// selected; false lets the key fall through to its normal handling.
        func editSelectedCell() -> Bool {
            guard tab.isEditable, visibleRowMap == nil,
                  selected.count == 1, let cell = selected.first else { return false }
            beginEdit(row: cell.row, col: cell.col)
            return true
        }

        /// Context-menu title for the value editor, nil when there is no result.
        /// Per cell: an auto-increment cell on an insert row only views.
        func valueEditorMenuTitle(row: Int, col: Int) -> String? {
            guard tab.result != nil else { return nil }
            return cellAllowsValueEditing(row: row, col: col)
                ? String(localized: "Edit Value…")
                : String(localized: "View Value…")
        }

        /// Mirrors `beginEdit`'s rule: auto-increment columns are blocked only on
        /// insert rows (updating a fetched row's generated key is legal SQL).
        private func cellAllowsValueEditing(row: Int, col: Int) -> Bool {
            guard tab.isEditable, visibleRowMap == nil,
                  let result = tab.result, col < result.columns.count else { return false }
            let dataRow = dataRow(forDisplay: row)
            return !(isInsertRow(dataRow)
                     && tab.editSource?.autoIncrementColumns.contains(result.columns[col].name) == true)
        }

        /// ⇧↩ — opens the value editor on the single selected cell.
        func openValueEditorForSelection() -> Bool {
            guard selected.count == 1, let cell = selected.first else { return false }
            openValueEditor(row: cell.row, col: cell.col)
            return true
        }

        /// Opens the multiline value-editor sheet for a cell (display coordinates):
        /// selects the cell, then hands the current value to the detail view.
        func openValueEditor(row: Int, col: Int) {
            guard let result = tab.result, col < result.columns.count else { return }
            let old = selectionRows
            selected = [CellPos(row: row, col: col)]
            anchor = CellPos(row: row, col: col)
            focus = CellPos(row: row, col: col)
            reload(rows: old.union(selectionRows))
            updateInspector()

            let column = result.columns[col]
            let value = cellString(row: row, col: col)
            let dataRow = dataRow(forDisplay: row)
            tab.valueEditor = ValueEditorTarget(
                row: dataRow, columnName: column.name, typeName: column.typeName,
                text: value ?? "", isNull: value == nil,
                isEditable: cellAllowsValueEditing(row: row, col: col),
                isInsertRow: isInsertRow(dataRow),
                resultVersion: tab.resultVersion)
        }

        var tabCanUndo: Bool { tab.isEditable && visibleRowMap == nil && tab.canUndoEdits }
        var tabCanRedo: Bool { tab.isEditable && visibleRowMap == nil && tab.canRedoEdits }

        /// ⌘Z — steps the grid's pending changes back one snapshot. The selection is
        /// cleared because restored state can have a different row count.
        func undoEdits() -> Bool {
            guard tabCanUndo else { return false }
            tab.undoEdits()
            resetSelectionAfterHistoryStep()
            return true
        }

        func redoEdits() -> Bool {
            guard tabCanRedo else { return false }
            tab.redoEdits()
            resetSelectionAfterHistoryStep()
            return true
        }

        private func resetSelectionAfterHistoryStep() {
            selected = []
            anchor = nil
            focus = nil
            tableView?.reloadData()
            updateInspector()
        }

        /// ⌥⌫ / context menu — sets every selected cell to SQL NULL (on an insert
        /// row: clears the value, letting the database default apply).
        func setSelectedToNull() {
            guard tab.isEditable, visibleRowMap == nil, let result = tab.result, !selected.isEmpty else { return }
            tab.captureEditSnapshot()
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

        /// Returns the field editor when editing actually started. Native in-cell
        /// editing: the cell's own text field becomes first responder — with
        /// `configure` no longer reloading the table on every observed change, the
        /// cell view is guaranteed live, and AppKit never recycles a view mid-edit.
        @discardableResult
        func beginEdit(row: Int, col: Int, allowSheet: Bool = true) -> NSText? {
            // A multiline value can't be edited in the single-line field — route
            // it to the value-editor sheet instead, before any editability guard:
            // on a read-only result the sheet still opens as a viewer. (typeToEdit
            // opts out: typed text replaces the value, so its shape doesn't matter.)
            if allowSheet, cellString(row: row, col: col)?.contains("\n") == true {
                openValueEditor(row: row, col: col)
                return nil
            }
            guard tab.isEditable, visibleRowMap == nil, let tableView, let result, col < result.columns.count
            else { return nil }
            // Auto-increment cells on insert rows are DB-generated — not editable.
            if isInsertRow(row),
               tab.editSource?.autoIncrementColumns.contains(result.columns[col].name) == true { return nil }
            let old = selectionRows
            selected = [CellPos(row: row, col: col)]
            anchor = CellPos(row: row, col: col)
            focus = CellPos(row: row, col: col)
            // Repaint rows losing their highlight, but never the row being edited —
            // its live view is what the editing session attaches to.
            var repaint = old.union(selectionRows)
            repaint.remove(row)
            reload(rows: repaint)

            guard let field = tableView.view(atColumn: col, row: row, makeIfNecessary: false) as? GridTextField,
                  field.window != nil else { return nil }
            field.isEditable = true
            field.isSelectable = true
            tableView.window?.makeFirstResponder(field)
            let editor = field.currentEditor()
            editor?.selectAll(nil)
            isEditingActive = editor != nil
            tab.isEditingCell = editor != nil   // pauses auto-refresh for this tab
            // Date/time cells get a picker popover under the cell — the raw
            // text stays editable in place, both stay in sync.
            if let editor, allowSheet, isTemporalColumnType(result.columns[col].typeName) {
                showDatePopover(row: row, col: col, editor: editor,
                                typeName: result.columns[col].typeName)
            }
            return editor
        }

        /// Called from `dismantleNSView` — the NSEvent monitors and popovers
        /// are not tied to the view hierarchy and would leak past it.
        func teardown() {
            closeDatePopover()
            filterPopover?.close()
            filterPopover = nil
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            escapeMonitor = nil
            // Drop the scroll frame/bounds observers so they don't outlive the grid.
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: Escape → discard edits

        private var escapeMonitor: Any?

        /// Discards this tab's uncommitted edits on Escape regardless of where focus
        /// sits — the table's own keyDown only fires when it is first responder, but
        /// a row can be added from the toolbar with focus elsewhere. Installed once;
        /// scoped to the grid's window, and it steps aside while a text field is
        /// editing (the cell editor and the find bar keep Escape for their own cancel).
        func installEscapeMonitor() {
            guard escapeMonitor == nil else { return }
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.keyCode == 53, self.tab.hasEdits,
                      let window = self.tableView?.window, event.window === window,
                      !(window.firstResponder is NSText) else { return event }
                self.discardPendingAndReload()
                return nil   // consumed
            }
        }

        /// Clears the tab's pending edits and repaints the grid — SwiftUI won't
        /// re-run `updateNSView` here (the results view doesn't observe the edit
        /// state), so the reload has to be explicit or the reverted rows stay
        /// highlighted.
        func discardPendingAndReload() {
            onDiscardPending()
            selected = []
            anchor = nil
            focus = nil
            tableView?.reloadData()
            updateInspector()
        }

        // MARK: Local column filter

        private var filterPopover: NSPopover?

        /// Right-click menu for a column header: the local value filter.
        func headerMenu(column: Int) -> NSMenu? {
            guard let result = tab.result, column >= 0, column < result.columns.count
            else { return nil }
            let menu = NSMenu()
            let item = NSMenuItem(title: String(localized: "Local Filter…"),
                                  action: #selector(openLocalFilterAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column
            item.state = tab.localValueFilters[result.columns[column].name] != nil ? .on : .off
            menu.addItem(item)
            if !tab.localValueFilters.isEmpty {
                let clear = NSMenuItem(title: String(localized: "Clear Local Filters"),
                                       action: #selector(clearLocalFiltersAction(_:)),
                                       keyEquivalent: "")
                clear.target = self
                menu.addItem(clear)
            }
            return menu
        }

        @objc private func openLocalFilterAction(_ sender: NSMenuItem) {
            guard let column = sender.representedObject as? Int else { return }
            openLocalFilter(column: column)
        }

        @objc private func clearLocalFiltersAction(_ sender: NSMenuItem) {
            tab.localValueFilters = [:]
        }

        /// PhpStorm-style popover: distinct values of the column with counts;
        /// checked values keep their rows, applied live.
        private func openLocalFilter(column: Int) {
            guard let tableView, let result = tab.result, column < result.columns.count,
                  let header = tableView.headerView else { return }
            filterPopover?.close()
            let name = result.columns[column].name
            var counts: [String?: Int] = [:]
            for row in result.rows where column < row.count {
                counts[row[column].text, default: 0] += 1
            }
            let values = counts
                .map { (value: $0.key, count: $0.value) }
                .sorted { a, b in
                    a.count != b.count ? a.count > b.count : (a.value ?? "") < (b.value ?? "")
                }
            let tab = self.tab
            let view = ColumnFilterView(
                columnName: name,
                values: values,
                initialSelection: tab.localValueFilters[name] ?? [],
                onChange: { selection in
                    tab.localValueFilters[name] = selection.isEmpty ? nil : selection
                })
            let popover = NSPopover()
            popover.contentViewController = NSHostingController(rootView: view)
            popover.behavior = .transient
            popover.show(relativeTo: header.headerRect(ofColumn: column), of: header,
                         preferredEdge: .maxY)
            filterPopover = popover
        }

        // MARK: In-cell date picker popover

        private var datePopover: NSPopover?
        private weak var datePicker: NSDatePicker?
        private weak var dateEditor: NSText?
        private var dateEditorObserver: NSObjectProtocol?
        private var dateClickMonitor: Any?
        private var isSyncingDateText = false
        /// Whether the edited value used the ISO `T`/`Z` shape, to write back alike.
        private var dateEditorUsesISO = false
        /// The (data-row, column) the popover edits, valid past the in-cell
        /// editing session's death, plus the one-snapshot-per-session flag.
        private var dateTargetRow = -1
        private var dateTargetColumn = ""
        private var dateSnapshotTaken = false
        /// Result the popover was opened against — a commit against a newer
        /// result would hit whatever row moved into `dateTargetRow`.
        private var dateResultVersion = -1
        /// The picker's current value: shown as a cell preview while the
        /// popover is up, committed as ONE pending edit when it closes.
        private var datePendingValue: String?

        private func showDatePopover(row: Int, col: Int, editor: NSText, typeName: String) {
            closeDatePopover()
            guard let tableView, let result = tab.result, col < result.columns.count else { return }
            dateTargetRow = dataRow(forDisplay: row)
            dateTargetColumn = result.columns[col].name
            dateSnapshotTaken = false
            dateResultVersion = tab.resultVersion
            let type = typeName.lowercased()
            let picker = NSDatePicker()
            picker.datePickerStyle = .textFieldAndStepper
            picker.timeZone = TimeZone(identifier: "UTC")
            // sv_SE renders ISO-like (yyyy-MM-dd, 24 h) — matching the raw
            // value instead of a 12-hour AM/PM surprise.
            picker.locale = Locale(identifier: "sv_SE")
            picker.isBezeled = false
            picker.drawsBackground = false
            if type.contains("timestamp") || type.contains("datetime") {
                picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
            } else if type == "date" {
                picker.datePickerElements = [.yearMonthDay]
            } else {
                picker.datePickerElements = [.hourMinuteSecond]
            }
            dateEditorUsesISO = editor.string.contains("T")
            picker.dateValue = Self.parseTemporal(editor.string) ?? Date()
            picker.target = self
            picker.action = #selector(datePickerChanged(_:))
            picker.sizeToFit()
            // Tab cycles through the picker's own date segments instead of
            // escaping the popover.
            picker.nextKeyView = picker

            let padding: CGFloat = 10
            let container = NSView(frame: NSRect(x: 0, y: 0,
                                                 width: picker.frame.width + padding * 2,
                                                 height: picker.frame.height + padding * 2))
            picker.setFrameOrigin(NSPoint(x: padding, y: padding))
            container.addSubview(picker)
            let controller = NSViewController()
            controller.view = container

            let popover = NSPopover()
            popover.contentViewController = controller
            // Not transient: it must survive clicks back into the cell text;
            // it closes with the editing session instead.
            popover.behavior = .applicationDefined
            popover.show(relativeTo: tableView.frameOfCell(atColumn: col, row: row),
                         of: tableView, preferredEdge: .maxY)
            datePopover = popover
            datePicker = picker
            dateEditor = editor
            dateEditorObserver = NotificationCenter.default.addObserver(
                forName: NSText.didChangeNotification, object: editor, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.dateEditorTextChanged() }
            }
            // `.applicationDefined` never closes itself; a click outside both
            // the popover and the edited cell commits the previewed value,
            // Esc cancels it.
            dateClickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .keyDown]
            ) { [weak self] event in
                guard let self, let popover = self.datePopover else { return event }
                if event.type == .keyDown {
                    switch event.keyCode {
                    case 53:   // Esc — discard the preview
                        self.closeDatePopover(commit: false)
                        return self.isEditingActive ? event : nil
                    case 36, 76:   // Return / keypad Enter — commit the preview
                        self.closeDatePopover(commit: true)
                        // A live in-cell session still commits its typed text
                        // through the normal path; otherwise swallow the key.
                        return self.isEditingActive ? event : nil
                    default:
                        return event
                    }
                }
                if event.window === popover.contentViewController?.view.window { return event }
                if let editor = self.dateEditor, event.window === editor.window {
                    let point = editor.convert(event.locationInWindow, from: nil)
                    if editor.bounds.contains(point) { return event }
                }
                self.closeDatePopover(commit: true)
                if self.isEditingActive, let tableView = self.tableView {
                    tableView.window?.makeFirstResponder(tableView)
                }
                return event
            }
        }

        /// `commit: true` turns the previewed value into one pending edit;
        /// `false` (Esc) discards the preview.
        func closeDatePopover(commit: Bool = false) {
            if let dateEditorObserver {
                NotificationCenter.default.removeObserver(dateEditorObserver)
            }
            dateEditorObserver = nil
            if let dateClickMonitor {
                NSEvent.removeMonitor(dateClickMonitor)
            }
            dateClickMonitor = nil
            let hadPopover = datePopover != nil
            datePopover?.close()
            datePopover = nil
            datePicker = nil
            dateEditor = nil
            guard hadPopover else { return }
            if !isEditingActive { tab.isEditingCell = false }
            let previewed = datePendingValue
            datePendingValue = nil
            if commit, let previewed {
                applyDateEdit(previewed)
            } else if previewed != nil, dateTargetRow >= 0 {
                // Drop the preview from the cell.
                reload(rows: IndexSet(integer: dateTargetRow))
            }
        }

        @objc private func datePickerChanged(_ sender: NSDatePicker) {
            // Adjusting the picker only previews — the cell shows the value
            // live, but nothing lands in pending changes until the popover
            // closes (one edit per session, not one per stepper click).
            let formatted = Self.formatTemporal(sender.dateValue,
                                                elements: sender.datePickerElements,
                                                iso: dateEditorUsesISO)
            datePendingValue = formatted
            reload(rows: IndexSet(integer: dateTargetRow))
        }

        /// Applies a picker value as a pending edit — the same rules the
        /// end-of-editing commit uses, one undo snapshot per popover session.
        private func applyDateEdit(_ value: String) {
            let row = dateTargetRow
            let columnName = dateTargetColumn
            // The result was replaced while the popover was up (auto-refresh,
            // a late run) — the captured row would hit the wrong record now.
            guard tab.resultVersion == dateResultVersion else { return }
            guard let result = tab.result, row >= 0 else { return }

            if isInsertRow(row) {
                let insertIndex = row - fetchedRowCount
                guard insertIndex < tab.pendingInserts.count else { return }
                if tab.pendingInserts[insertIndex].values[columnName] != value {
                    takeDateSnapshotIfNeeded()
                    tab.pendingInserts[insertIndex].values[columnName] = value
                }
                reload(rows: IndexSet(integer: row))
                return
            }

            guard row < result.rows.count,
                  let columnIndex = result.columns.firstIndex(where: { $0.name == columnName })
            else { return }
            let original = columnIndex < result.rows[row].count
                ? result.rows[row][columnIndex].text : nil
            if value == original {
                if tab.edits[row]?[columnName] != nil {
                    takeDateSnapshotIfNeeded()
                    tab.edits[row]?[columnName] = nil
                    if tab.edits[row]?.isEmpty == true { tab.edits[row] = nil }
                }
            } else if tab.edits[row]?[columnName] != .some(.some(value)) {
                takeDateSnapshotIfNeeded()
                tab.edits[row, default: [:]][columnName] = value
            }
            reload(rows: IndexSet(integer: row))
            DispatchQueue.main.async { [weak self] in self?.updateInspector() }
        }

        private func takeDateSnapshotIfNeeded() {
            guard !dateSnapshotTaken else { return }
            dateSnapshotTaken = true
            tab.captureEditSnapshot()
        }

        private func dateEditorTextChanged() {
            guard !isSyncingDateText, let editor = dateEditor, let picker = datePicker else { return }
            if let date = Self.parseTemporal(editor.string) {
                picker.dateValue = date
            }
        }

        static func parseTemporal(_ string: String) -> Date? {
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: trimmed) { return date }
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: trimmed) { return date }
            for pattern in ["yyyy-MM-dd HH:mm:ss.SSSZZZZZ", "yyyy-MM-dd HH:mm:ssZZZZZ",
                            "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss",
                            "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
                            "HH:mm:ss.SSS", "HH:mm:ss", "HH:mm"] {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(identifier: "UTC")
                formatter.dateFormat = pattern
                if let date = formatter.date(from: trimmed) { return date }
            }
            return nil
        }

        static func formatTemporal(_ date: Date, elements: NSDatePicker.ElementFlags,
                                   iso: Bool) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            if elements.contains(.yearMonthDay), elements.contains(.hourMinuteSecond) {
                formatter.dateFormat = iso ? "yyyy-MM-dd'T'HH:mm:ss'Z'" : "yyyy-MM-dd HH:mm:ss"
            } else if elements.contains(.yearMonthDay) {
                formatter.dateFormat = "yyyy-MM-dd"
            } else {
                formatter.dateFormat = "HH:mm:ss"
            }
            return formatter.string(from: date)
        }

        /// Cells a multi-selection edit session will write into on commit.
        private var bulkEditTargets: Set<CellPos>?

        /// Typing a printable character on the selection starts editing with that
        /// character replacing the content (spreadsheet-style). With several cells
        /// selected, the value typed into the focused cell lands in all of them.
        func typeToEdit(_ text: String) -> Bool {
            guard tab.isEditable, visibleRowMap == nil, !selected.isEmpty else { return false }
            let targets = selected
            let cell = focus ?? anchor ?? selected.min { ($0.row, $0.col) < ($1.row, $1.col) }!
            guard let editor = beginEdit(row: cell.row, col: cell.col, allowSheet: false) as? NSTextView else {
                bulkEditTargets = nil
                return false
            }
            if targets.count > 1 {
                // One snapshot for the whole session — Escape reverts the live
                // preview below in a single undo step.
                tab.captureEditSnapshot()
                bulkEditTargets = targets
            } else {
                bulkEditTargets = nil
            }
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            // Programmatic string changes post no controlTextDidChange — seed the
            // live preview for the first character by hand.
            propagateBulkPreview(text, excluding: cell)
            return true
        }

        /// Live preview while a multi-cell typing session runs: what's in the editor
        /// lands in every other selected cell on each keystroke. The edited row is
        /// never reloaded — that would recycle the view hosting the session.
        private func propagateBulkPreview(_ value: String, excluding edited: CellPos) {
            guard let targets = bulkEditTargets else { return }
            var rows = IndexSet()
            for cell in targets where cell != edited {
                setCell(cell, to: value)
                rows.insert(cell.row)
            }
            rows.remove(edited.row)
            reload(rows: rows)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard bulkEditTargets != nil, let field = notification.object as? GridTextField else { return }
            propagateBulkPreview(field.stringValue,
                                 excluding: CellPos(row: field.rowIndex, col: field.columnIndex))
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
            tab.captureEditSnapshot()

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
            tab.captureEditSnapshot()
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
            tab.captureEditSnapshot()
            tab.pendingInserts.append(PendingInsert())
            tableView?.reloadData()
            let newRow = fetchedRowCount + tab.pendingInserts.count - 1
            tableView?.scrollRowToVisible(newRow)
        }

        /// Copies a fetched row into a new insert row, dropping DB-generated
        /// (auto-increment) columns so the database assigns fresh values.
        func duplicateRow(_ row: Int) {
            guard tab.isEditable, visibleRowMap == nil, let values = insertValues(from: row) else { return }
            tab.captureEditSnapshot()
            tab.pendingInserts.append(PendingInsert(values: values))
            tableView?.reloadData()
            tableView?.scrollRowToVisible(fetchedRowCount + tab.pendingInserts.count - 1)
        }

        /// ⌘D — duplicates every selected fetched row into new insert rows.
        func duplicateSelectedRows() {
            guard tab.isEditable, visibleRowMap == nil else { return }
            let rows = selectionRows.filter { !isInsertRow($0) }.sorted()
            guard !rows.isEmpty else { return }
            tab.captureEditSnapshot()
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

        /// Writes one value into one cell, mirroring how a manual edit is recorded:
        /// insert rows update their pending values (auto-increment stays untouched),
        /// fetched rows record an edit — or drop it when the value matches the original.
        private func setCell(_ cell: CellPos, to value: String) {
            guard let result = tab.result, cell.col < result.columns.count else { return }
            let columnName = result.columns[cell.col].name
            guard tab.editSource?.autoIncrementColumns.contains(columnName) != true else { return }
            if isInsertRow(cell.row) {
                let index = cell.row - fetchedRowCount
                guard index < tab.pendingInserts.count else { return }
                tab.pendingInserts[index].values[columnName] = value
                return
            }
            guard cell.row < result.rows.count else { return }
            let original = cell.col < result.rows[cell.row].count ? result.rows[cell.row][cell.col].text : nil
            if value == (original ?? "") {
                tab.edits[cell.row]?[columnName] = nil
                if tab.edits[cell.row]?.isEmpty == true { tab.edits[cell.row] = nil }
            } else {
                tab.edits[cell.row, default: [:]][columnName] = value
            }
        }

        /// ⌘V — a single clipboard value fills every selected cell; a multi-cell TSV
        /// block (what ⌘C produces) spreads row-by-row, column-by-column from the
        /// selection's top-left corner, so copy 4 rows → paste 4 rows.
        func pasteIntoSelection() {
            guard tab.isEditable, visibleRowMap == nil, let result = tab.result, !selected.isEmpty,
                  let value = NSPasteboard.general.string(forType: .string) else { return }
            var matrix = value.components(separatedBy: "\n").map { $0.components(separatedBy: "\t") }
            if matrix.last == [""] { matrix.removeLast() }   // trailing newline
            guard !matrix.isEmpty else { return }
            tab.captureEditSnapshot()

            if matrix.count == 1, matrix[0].count == 1 {
                for cell in selected { setCell(cell, to: matrix[0][0]) }
                reload(rows: selectionRows)
                return
            }

            let startRow = selected.map(\.row).min() ?? 0
            let startCol = selected.map(\.col).min() ?? 0
            let rowCount = result.rows.count + tab.pendingInserts.count
            var pasted: Set<CellPos> = []
            for (rowOffset, rowValues) in matrix.enumerated() {
                let row = startRow + rowOffset
                guard row < rowCount else { break }
                for (colOffset, cellValue) in rowValues.enumerated() {
                    let col = startCol + colOffset
                    guard col < result.columns.count else { break }
                    let cell = CellPos(row: row, col: col)
                    setCell(cell, to: cellValue)
                    pasted.insert(cell)
                }
            }
            // Select the pasted block so what just changed is visible at a glance.
            let old = selectionRows
            selected = pasted
            anchor = pasted.min { ($0.row, $0.col) < ($1.row, $1.col) }
            focus = anchor
            reload(rows: old.union(selectionRows))
            updateInspector()
        }

        var hasSelection: Bool { !selected.isEmpty }

        /// Escape while the grid (not the search field) has focus: first dismiss the
        /// find bar, otherwise discard the tab's uncommitted edits (undoable via ⌘Z).
        /// Returns false when there's nothing to cancel, so Escape keeps its default.
        func handleEscape() -> Bool {
            if tab.isSearchBarVisible {
                tab.clearSearch()
                return true
            }
            if tab.hasEdits {
                discardPendingAndReload()
                return true
            }
            return false
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
            // The open date popover previews its value in the cell without
            // touching pending edits.
            if let preview = datePendingValue, datePopover != nil,
               row == dateTargetRow, columnName == dateTargetColumn {
                return preview
            }
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
            // One coordinator serves every tab (the representable keeps its identity
            // across tab switches). Switching tabs must first close out any live
            // editing session — committing into the tab it belongs to, while
            // `self.tab` still points there — and drop the old tab's selection, or
            // an edit/Backspace would land on the new tab's rows by position.
            if tab !== self.tab {
                if isEditingActive {
                    tableView?.window?.makeFirstResponder(tableView)
                }
                isEditingActive = false
                self.tab.isEditingCell = false
                bulkEditTargets = nil
                selected = []
                anchor = nil; focus = nil
                // Popovers belong to the outgoing tab — a surviving date
                // popover would commit into the new tab's rows.
                closeDatePopover()
                filterPopover?.close()
                filterPopover = nil
            }
            self.tab = tab
            guard let tableView, let result = tab.result else { return }
            // Recompute the filter/sort display map only when an input actually
            // changed. `configure` runs on *every* observed mutation of the tab
            // (cell selection, inspector, hover…), and this scan is O(rows) with
            // locale-aware matching — recomputing it per invalidation stalls large
            // results. The key covers everything the map depends on; anything else
            // (selection, inspector) leaves the cached map untouched.
            let mapKey = VisibleMapKey(tab: ObjectIdentifier(tab),
                                       searchQuery: tab.searchQuery,
                                       valueFilters: tab.localValueFilters,
                                       sortColumn: tab.localSortColumn,
                                       sortAscending: tab.localSortAscending,
                                       resultVersion: tab.resultVersion)
            if mapKey != lastVisibleMapKey {
                lastVisibleMapKey = mapKey
                visibleRowMap = tab.matchingRowIndices()
                // Local per-column value filters (header right-click) stack on the
                // ⌘F filter. Like it, they park editing while active.
                if !tab.localValueFilters.isEmpty {
                    let base = visibleRowMap ?? Array(result.rows.indices)
                    visibleRowMap = GridDisplay.valueFiltered(base, rows: result.rows,
                                                              columns: result.columns,
                                                              filters: tab.localValueFilters)
                }
                // Client-side sort (console results): permute the display order on
                // top of any ⌘F filter. Like the filter, it parks editing — the
                // row juggling only makes sense over the raw result order.
                if let sortColumn = tab.localSortColumn, sortColumn < result.columns.count {
                    let base = visibleRowMap ?? Array(result.rows.indices)
                    visibleRowMap = GridDisplay.sorted(base, rows: result.rows, column: sortColumn,
                                                       ascending: tab.localSortAscending,
                                                       numeric: isNumericColumnType(result.columns[sortColumn].typeName))
                }
            }
            if let grid = tableView as? GridTableView {
                // Editing (and pending-insert rows) is unavailable while a ⌘F filter
                // narrows what's on screen — the row indices it juggles only make
                // sense over the full, unfiltered result.
                grid.canEditRows = tab.isEditable && visibleRowMap == nil
                grid.fetchedRowCount = fetchedRowCount
            }
            // Reset the cell selection only when the underlying data actually changed
            // (new query / sort / filter / page) — not on the re-render after an edit.
            if tab.resultVersion != lastResultVersion {
                lastResultVersion = tab.resultVersion
                selected = []
                anchor = nil; focus = nil
            }
            // Display row indices shift whenever the ⌘F filter text changes, so a
            // held selection would silently point at the wrong cells. Local
            // value filters and the client-side sort shift them identically.
            if tab.searchQuery != lastSearchQuery {
                lastSearchQuery = tab.searchQuery
                selected = []
                anchor = nil; focus = nil
            }
            if tab.localValueFilters != lastValueFilters
                || tab.localSortColumn != lastLocalSortColumn
                || tab.localSortAscending != lastLocalSortAscending {
                lastValueFilters = tab.localValueFilters
                lastLocalSortColumn = tab.localSortColumn
                lastLocalSortAscending = tab.localSortAscending
                selected = []
                anchor = nil; focus = nil
                DispatchQueue.main.async { [weak self] in self?.updateInspector() }
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
                resetColumnSpread()
            }
            spreadColumnsIfNeeded()
            // Reload only when the data under the grid actually changed. SwiftUI
            // re-invokes updateNSView on every observed mutation — including ones a
            // reload must NOT interrupt, like the inspector update from the click
            // that precedes typing: a full reloadData tears down row views (they
            // re-materialize only on the next draw pass) and kills any editing
            // session, which is exactly how in-cell editing kept breaking.
            var hasher = Hasher()
            hasher.combine(ObjectIdentifier(tab))
            hasher.combine(tab.resultVersion)
            hasher.combine(tab.searchQuery)
            hasher.combine(signature)
            hasher.combine(tab.pendingDeletes)
            hasher.combine(tab.edits)
            hasher.combine(tab.sortOrder)
            hasher.combine(tab.localSortColumn)
            hasher.combine(tab.localSortAscending)
            hasher.combine(tab.localValueFilters)
            for insert in tab.pendingInserts {
                hasher.combine(insert.id)
                hasher.combine(insert.values)
            }
            let fingerprint = hasher.finalize()
            // While an edit session is live, skip (and don't record) the reload — the
            // live-preview writes change `edits` on every keystroke, and reloading
            // would kill the session doing the typing. The skipped reload happens on
            // the first configure after the session ends.
            if fingerprint != lastFingerprint, !isEditingActive {
                lastFingerprint = fingerprint
                tableView.reloadData()
                updateSortIndicator(tableView, result)
                // Accent-tint headers whose column carries a local filter.
                for (index, column) in tableView.tableColumns.enumerated()
                where index < result.columns.count {
                    if let cell = column.headerCell as? TypedHeaderCell {
                        let filtered = tab.localValueFilters[result.columns[index].name] != nil
                        if cell.isFiltered != filtered {
                            cell.isFiltered = filtered
                            tableView.headerView?.needsDisplay = true
                        }
                    }
                }
            }
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
            guard let result = tab.result,
                  let index = Int(tableColumn.identifier.rawValue), index < result.columns.count else { return }
            if tab.kind == .data || tab.isEditable {
                // Table-backed results (editable or read-only windowed) re-run with
                // ORDER BY on the server — a data view owns its generated SQL.
                onSort(result.columns[index].name)
            } else {
                // Arbitrary query results sort the fetched rows client-side —
                // ORDER BY can't be injected into hand-written SQL.
                if tab.localSortColumn == index {
                    if tab.localSortAscending { tab.localSortAscending = false }
                    else { tab.localSortColumn = nil }
                } else {
                    tab.localSortColumn = index
                    tab.localSortAscending = true
                }
            }
        }

        /// Column-spread state: hands off once the user resizes any column.
        private var userAdjustedColumns = false
        private var suppressColumnResizeTracking = false
        private var lastSpreadKey = ""
        private var pendingSpread: DispatchWorkItem?

        /// Content-aware column widths: each column gets what its widest
        /// sampled value (or header) needs, and any leftover viewport space is
        /// split evenly — never dumped into one bloated last column while
        /// values elsewhere stay truncated. Wider-than-viewport content keeps
        /// its fitted widths and scrolls. Re-run when the viewport or the data
        /// changes, until the user resizes a column by hand.
        func spreadColumnsIfNeeded() {
            guard let tableView, !userAdjustedColumns,
                  let clip = tableView.enclosingScrollView?.contentView,
                  let result else { return }
            let width = clip.bounds.width
            let count = tableView.tableColumns.count
            guard width > 0, count > 0, count == result.columns.count else { return }
            let key = "\(Int(width))-\(tab.resultVersion)-\(count)"
            guard key != lastSpreadKey else { return }
            lastSpreadKey = key

            let charWidth = ("0" as NSString).size(withAttributes: [.font: Self.mono]).width
            var ideal: [CGFloat] = []
            for (index, column) in result.columns.enumerated() {
                var characters = 0
                for row in result.rows.prefix(300) where index < row.count {
                    characters = max(characters, row[index].text?.count ?? 4)
                }
                let content = CGFloat(characters) * charWidth + 14
                let header = CGFloat(column.name.count) * 7
                    + CGFloat(column.typeName.count) * 6 + 34
                ideal.append(min(max(content, header, 60), 420))
            }
            let total = ideal.reduce(0, +) + tableView.intercellSpacing.width * CGFloat(count)
            if total < width {
                let extra = (width - total) / CGFloat(count)
                for index in ideal.indices { ideal[index] += extra }
            }
            suppressColumnResizeTracking = true
            for (index, column) in tableView.tableColumns.enumerated() where index < ideal.count {
                column.width = ideal[index].rounded(.down)
            }
            suppressColumnResizeTracking = false
        }

        /// Fired by the scroll view's frame-change notification. A divider or window
        /// resize fires this every pixel; re-spreading the columns on each one reflows
        /// the grid and flickers, so coalesce and run once the size settles.
        @objc func scrollFrameChanged(_ notification: Notification) {
            pendingSpread?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.spreadColumnsIfNeeded() }
            pendingSpread = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            // Programmatic width changes (autoresizing, the spread itself)
            // post the same notification — only a live drag in the header
            // counts as the user taking over.
            guard !suppressColumnResizeTracking,
                  let header = tableView?.headerView, header.resizedColumn != -1 else { return }
            userAdjustedColumns = true
        }

        /// New column set: the spread starts over from scratch.
        func resetColumnSpread() {
            userAdjustedColumns = false
            lastSpreadKey = ""
        }
        /// Draws the sort arrow on every sorted column's header, plus a priority
        /// number (1, 2, …) when more than one column drives the sort. Server-side
        /// multi-column sort (table views) wins; otherwise the single client-side
        /// sort of a plain query result.
        private func updateSortIndicator(_ tableView: NSTableView, _ result: QueryResult) {
            for column in tableView.tableColumns { tableView.setIndicatorImage(nil, in: column) }
            var priorities: [Int: Int] = [:]   // column index → 1-based rank

            if !tab.sortOrder.isEmpty {
                for (rank, key) in tab.sortOrder.enumerated() {
                    guard let index = result.columns.firstIndex(where: { $0.name == key.column }),
                          index < tableView.tableColumns.count else { continue }
                    let arrow = key.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"
                    tableView.setIndicatorImage(NSImage(named: arrow), in: tableView.tableColumns[index])
                    priorities[index] = rank + 1
                }
                // Highlight the primary column only.
                tableView.highlightedTableColumn = tab.sortOrder.first
                    .flatMap { key in result.columns.firstIndex(where: { $0.name == key.column }) }
                    .map { tableView.tableColumns[$0] }
            } else if let local = tab.localSortColumn, local < tableView.tableColumns.count {
                let arrow = tab.localSortAscending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"
                tableView.setIndicatorImage(NSImage(named: arrow), in: tableView.tableColumns[local])
                tableView.highlightedTableColumn = tableView.tableColumns[local]
            } else {
                tableView.highlightedTableColumn = nil
            }
            // Show the numbers only when a multi-column sort makes priority meaningful.
            (tableView.headerView as? ClearHeaderView)?.sortPriorities =
                priorities.count > 1 ? priorities : [:]
            tableView.headerView?.needsDisplay = true
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
            // Translucent zebra stripe — labelColor adapts to light/dark.
            rowView.backgroundColor = row.isMultiple(of: 2)
                ? .clear
                : NSColor.labelColor.withAlphaComponent(0.04)
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
            field.cell = CenteredTextFieldCell(textCell: "")
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
            // Keyboard commits dismiss the date popover: Return/Tab keep the
            // previewed value, Esc discards it. A click INTO the popover also
            // ends the session (movement 0) but must leave it open — the
            // picker keeps previewing.
            let endMovement = notification.userInfo?["NSTextMovement"] as? Int ?? 0
            if endMovement == NSTextMovement.cancel.rawValue {
                closeDatePopover(commit: false)
            } else if endMovement != 0 {
                closeDatePopover(commit: true)
            }
            // Reset the session flags before any early exit — a stuck
            // `isEditingActive` would silently disable grid reloads for good.
            // An open date popover keeps the tab "editing": auto-refresh
            // replacing the result under the preview would retarget the edit.
            isEditingActive = false
            tab.isEditingCell = datePopover != nil
            guard let field = notification.object as? GridTextField,
                  let result, field.rowIndex >= 0, field.columnIndex < result.columns.count else {
                bulkEditTargets = nil
                return
            }
            let row = field.rowIndex
            let columnName = result.columns[field.columnIndex].name
            let newValue = field.stringValue
            let movement = notification.userInfo?["NSTextMovement"] as? Int ?? 0
            // Back to a plain label until the next explicit edit — an editable field
            // left behind would swallow the grid's own click handling.
            field.isEditable = false
            field.isSelectable = false

            // Editing starts by making the field first responder, so a keyboard
            // commit (Return/Tab; nonzero NSTextMovement) hands focus back to the
            // grid — a click into another control keeps its own focus.
            if movement != 0 {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let tableView = self.tableView else { return }
                    tableView.window?.makeFirstResponder(tableView)
                }
            }

            // A multi-selection typing session: the keystrokes already live-previewed
            // into every selected cell; commit just writes the final value (the
            // session's snapshot was captured when it armed). Escape reverts the
            // whole preview through that snapshot in one step.
            if let targets = bulkEditTargets {
                bulkEditTargets = nil
                let editedCell = CellPos(row: row, col: field.columnIndex)
                if movement == NSTextMovement.cancel.rawValue {
                    tab.revertLastSnapshot()   // not undoEdits — redo must not resurrect the preview
                } else {
                    for cell in targets { setCell(cell, to: newValue) }
                }
                let old = selectionRows
                selected = targets.union([editedCell])
                reload(rows: old.union(selectionRows))
                DispatchQueue.main.async { [weak self] in self?.updateInspector() }
                return
            }

            if isInsertRow(row) {
                let insertIndex = row - fetchedRowCount
                guard insertIndex < tab.pendingInserts.count,
                      tab.editSource?.autoIncrementColumns.contains(columnName) != true else { return }
                if tab.pendingInserts[insertIndex].values[columnName] != newValue {
                    tab.captureEditSnapshot()
                    tab.pendingInserts[insertIndex].values[columnName] = newValue
                }
                DispatchQueue.main.async { [weak self] in self?.reload(rows: IndexSet(integer: row)) }
                return
            }

            guard row < result.rows.count else { return }
            let original = field.columnIndex < result.rows[row].count ? result.rows[row][field.columnIndex].text : nil

            if newValue == (original ?? "NULL") || newValue == original {
                if tab.edits[row]?[columnName] != nil {
                    tab.captureEditSnapshot()
                    tab.edits[row]?[columnName] = nil
                    if tab.edits[row]?.isEmpty == true { tab.edits[row] = nil }
                }
            } else if tab.edits[row]?[columnName] != .some(.some(newValue)) {
                tab.captureEditSnapshot()
                tab.edits[row, default: [:]][columnName] = newValue
            }
            let editedRow = row
            DispatchQueue.main.async { [weak self] in
                self?.reload(rows: IndexSet(integer: editedRow))
            }
        }
    }
}
