import SwiftUI
import AppKit
import DBKit
import DBPersistence

/// Reference wrapper so NSOutlineView has stable, id-based item identity.
final class OrganizerItem: NSObject {
    enum Category { case workspace, project, folder, connection }

    let id: UUID
    let title: String
    let category: Category
    let profileKind: DatabaseKind?
    let color: String?
    let children: [OrganizerItem]

    var isContainer: Bool { category != .connection }

    init(id: UUID, title: String, category: Category,
         profileKind: DatabaseKind? = nil, color: String? = nil, children: [OrganizerItem] = []) {
        self.id = id
        self.title = title
        self.category = category
        self.profileKind = profileKind
        self.color = color
        self.children = children
    }

    override func isEqual(_ object: Any?) -> Bool { (object as? OrganizerItem)?.id == id }
    override var hash: Int { id.hashValue }
}

/// Live-connection indicator drawn on a connection row.
enum ConnectionDot: Equatable { case none, connecting, disconnecting, connected, failed }

/// NSOutlineView subclass that builds a context menu for the right-clicked row.
final class ContextualOutlineView: NSOutlineView {
    var contextMenuProvider: (@MainActor (Int) -> NSMenu?)?
    /// ⌘↩ — connects every selected connection, the keyboard equivalent of
    /// double-clicking one (a plain click never connects; see the Coordinator).
    var onCommandReturn: (() -> Void)?

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

    /// A pointing-hand cursor over each row — AppKit gives list rows no cursor
    /// feedback by default. Scoped to actual row rects (not the whole view) so it
    /// doesn't bleed into the empty space below the last item.
    override func resetCursorRects() {
        super.resetCursorRects()
        let visible = rows(in: visibleRect)
        guard visible.location != NSNotFound, visible.length > 0 else { return }
        for row in visible.location..<(visible.location + visible.length) {
            addCursorRect(rect(ofRow: row), cursor: .pointingHand)
        }
    }

    /// Row rects shift on scroll without changing the view's own bounds, so cursor
    /// rects need an explicit nudge to recompute — they aren't invalidated for free.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let clipView = enclosingScrollView?.contentView else { return }
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(invalidateCursorRects),
            name: NSView.boundsDidChangeNotification, object: clipView)
    }

    @objc private func invalidateCursorRects() {
        window?.invalidateCursorRects(for: self)
    }
}

/// The connection organizer backed by NSOutlineView for reliable drag & drop.
struct OrganizerOutlineView: NSViewRepresentable {
    let model: ConnectionsModel
    @Binding var selection: UUID?
    var onNewConnection: (UUID?) -> Void
    var onNewFolder: (UUID) -> Void
    var onNewProject: (UUID) -> Void
    var onNewWorkspace: () -> Void
    var onRename: (UUID, String) -> Void
    var onSetColor: (UUID, String?) -> Void
    var onSetConnectionColor: (UUID, String?) -> Void
    var onEditConnection: (UUID) -> Void
    /// Connection lifecycle actions, keyed by profile id.
    var onConnectProfile: (UUID) -> Void = { _ in }
    var onDisconnect: (UUID) -> Void = { _ in }
    var onReconnect: (UUID) -> Void = { _ in }
    var onIntrospect: (UUID) -> Void = { _ in }
    var onExport: (UUID) -> Void = { _ in }
    var onImport: (UUID) -> Void = { _ in }
    /// Opens a query tab bound to a connection (⌘T from its context menu).
    var onNewQueryTab: (UUID) -> Void = { _ in }
    /// Live status of a connection (profile id → dot), for the green indicator.
    var connectionDot: (UUID) -> ConnectionDot = { _ in .none }
    /// A value that changes with the organizer/profiles so SwiftUI re-invokes
    /// updateNSView (which refreshes the tree) on renames/recolors.
    var version: Int = 0
    /// Changes when any connection's live status changes, so the dots refresh.
    var statusVersion: Int = 0

    private static let nodeType = NSPasteboard.PasteboardType("io.github.tedyno.tessera.node")

    func makeNSView(context: Context) -> NSScrollView {
        let outline = ContextualOutlineView()
        outline.style = .sourceList
        outline.headerView = nil
        outline.rowHeight = 22
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        outline.allowsMultipleSelection = true
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.registerForDraggedTypes([Self.nodeType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        outline.contextMenuProvider = { [coordinator = context.coordinator] row in
            coordinator.menu(forRow: row)
        }
        // A click only ever selects — connecting is always an explicit action
        // (double-click here, ⌘↩ below), so building a multi-selection to drag
        // several items into a folder never fires off a connection attempt.
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClick(_:))
        outline.onCommandReturn = { [coordinator = context.coordinator] in coordinator.connectSelection() }

        let scrollView = NSScrollView()
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        context.coordinator.outlineView = outline
        context.coordinator.pasteboardType = Self.nodeType
        applyClosures(to: context.coordinator)
        context.coordinator.rebuild(expandingAll: true)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        applyClosures(to: context.coordinator)
        context.coordinator.statusVersion = statusVersion
        context.coordinator.sync()
    }

    private func applyClosures(to coordinator: Coordinator) {
        coordinator.connectionDot = connectionDot
        coordinator.onConnectProfile = onConnectProfile
        coordinator.onDisconnect = onDisconnect
        coordinator.onReconnect = onReconnect
        coordinator.onIntrospect = onIntrospect
        coordinator.onExport = onExport
        coordinator.onImport = onImport
        coordinator.onNewQueryTab = onNewQueryTab
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, selection: $selection,
                    onNewConnection: onNewConnection, onNewFolder: onNewFolder,
                    onNewProject: onNewProject, onNewWorkspace: onNewWorkspace,
                    onRename: onRename, onSetColor: onSetColor,
                    onSetConnectionColor: onSetConnectionColor, onEditConnection: onEditConnection)
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        let model: ConnectionsModel
        let selection: Binding<UUID?>
        let onNewConnection: (UUID?) -> Void
        let onNewFolder: (UUID) -> Void
        let onNewProject: (UUID) -> Void
        let onNewWorkspace: () -> Void
        let onRename: (UUID, String) -> Void
        let onSetColor: (UUID, String?) -> Void
        let onSetConnectionColor: (UUID, String?) -> Void
        let onEditConnection: (UUID) -> Void
        var onConnectProfile: (UUID) -> Void = { _ in }
        var onDisconnect: (UUID) -> Void = { _ in }
        var onReconnect: (UUID) -> Void = { _ in }
        var onIntrospect: (UUID) -> Void = { _ in }
        var onExport: (UUID) -> Void = { _ in }
        var onImport: (UUID) -> Void = { _ in }
        var onNewQueryTab: (UUID) -> Void = { _ in }
        var connectionDot: (UUID) -> ConnectionDot = { _ in .none }
        var statusVersion = 0

        weak var outlineView: NSOutlineView?
        var pasteboardType: NSPasteboard.PasteboardType = .string
        private var roots: [OrganizerItem] = []
        private var lastHash: Int?
        private var isSyncingSelection = false

        init(model: ConnectionsModel, selection: Binding<UUID?>,
             onNewConnection: @escaping (UUID?) -> Void, onNewFolder: @escaping (UUID) -> Void,
             onNewProject: @escaping (UUID) -> Void, onNewWorkspace: @escaping () -> Void,
             onRename: @escaping (UUID, String) -> Void, onSetColor: @escaping (UUID, String?) -> Void,
             onSetConnectionColor: @escaping (UUID, String?) -> Void, onEditConnection: @escaping (UUID) -> Void) {
            self.model = model
            self.selection = selection
            self.onNewConnection = onNewConnection
            self.onNewFolder = onNewFolder
            self.onNewProject = onNewProject
            self.onNewWorkspace = onNewWorkspace
            self.onRename = onRename
            self.onSetColor = onSetColor
            self.onSetConnectionColor = onSetConnectionColor
            self.onEditConnection = onEditConnection
        }

        // MARK: Building

        private var currentHash: Int {
            var hasher = Hasher()
            hasher.combine(model.organizer)
            hasher.combine(model.profiles)
            hasher.combine(statusVersion)
            return hasher.finalize()
        }

        func rebuild(expandingAll: Bool) {
            // Connections belonging to no workspace list first, at the top level.
            roots = model.organizer.looseConnections.map(Self.item(forNode:))
                + model.organizer.workspaces.map(Self.item(forWorkspace:))
            lastHash = currentHash
            outlineView?.reloadData()
            if expandingAll { outlineView?.expandItem(nil, expandChildren: true) }
            applySelection()
        }

        /// Rebuilds only when the organizer changed; always re-syncs selection.
        func sync() {
            if currentHash != lastHash {
                rebuild(expandingAll: false)
            } else {
                applySelection()
            }
        }

        private static func item(forWorkspace workspace: Workspace) -> OrganizerItem {
            OrganizerItem(id: workspace.id, title: workspace.name, category: .workspace,
                          children: workspace.children.map(item(forNode:)))
        }

        private static func item(forNode node: OrganizerNode) -> OrganizerItem {
            switch node {
            case .project(let p):
                OrganizerItem(id: p.id, title: p.name, category: .project,
                              children: p.children.map(item(forNode:)))
            case .folder(let f):
                OrganizerItem(id: f.id, title: f.name, category: .folder,
                              color: f.color, children: f.children.map(item(forNode:)))
            case .connection(let ref):
                OrganizerItem(id: ref.id, title: "", category: .connection,
                              profileKind: nil)
            }
        }

        private func title(for item: OrganizerItem) -> String {
            if item.category == .connection {
                // Resolve the live profile name (title on the item is a placeholder).
                if let profileID = model.organizer.profileID(forNode: item.id),
                   let profile = model.profile(id: profileID) {
                    return profile.name
                }
                return "Connection"
            }
            return item.title
        }

        private func profileKind(for item: OrganizerItem) -> DatabaseKind? {
            guard item.category == .connection,
                  let profileID = model.organizer.profileID(forNode: item.id) else { return nil }
            return model.profile(id: profileID)?.kind
        }

        // MARK: Selection

        private func applySelection() {
            guard let outlineView, let id = selection.wrappedValue else { return }
            guard let item = find(id, in: roots) else { return }
            let row = outlineView.row(forItem: item)
            // Only force a single-row selection when the primary id isn't already
            // part of the current one — `sync()` calls this on every organizer/status
            // tick, and a live multi-selection (mid-drag setup, about to be bulk
            // deleted, …) would otherwise get collapsed back to one row underneath it.
            guard row >= 0, !outlineView.selectedRowIndexes.contains(row) else { return }
            isSyncingSelection = true
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isSyncingSelection = false
        }

        private func find(_ id: UUID, in items: [OrganizerItem]) -> OrganizerItem? {
            for item in items {
                if item.id == id { return item }
                if let found = find(id, in: item.children) { return found }
            }
            return nil
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let outlineView else { return }
            // Only mirror a single selected row into the "primary" binding — that
            // binding drives auto-connect (see the outer view's `onChange(of: selection)`),
            // so extending a multi-selection with ⌘/⇧-click must not auto-connect
            // every row added to it.
            guard outlineView.selectedRowIndexes.count == 1 else { return }
            let row = outlineView.selectedRow
            guard row >= 0, let item = outlineView.item(atRow: row) as? OrganizerItem else { return }
            selection.wrappedValue = item.id
        }

        // MARK: DataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? OrganizerItem)?.children.count ?? roots.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? OrganizerItem)?.children[index] ?? roots[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? OrganizerItem)?.isContainer ?? false
        }

        // MARK: Delegate — cells

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let orgItem = item as? OrganizerItem else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("cell")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
                ?? Self.makeCellView(identifier: identifier)
            cell.textField?.stringValue = title(for: orgItem)
            let custom = currentColorName(for: orgItem)

            // Live-connection dot (green connected / red failed) — connecting and
            // disconnecting show a small spinner instead, since a static dot gave no
            // sense that anything was actually happening during either.
            let statusDot = cell.subviews.first { $0.identifier?.rawValue == "statusDot" }
            let statusSpinner = cell.subviews.first { $0.identifier?.rawValue == "statusSpinner" }
                as? NSProgressIndicator
            if orgItem.category == .connection, let profileID = model.organizer.profileID(forNode: orgItem.id) {
                let dotStatus = connectionDot(profileID)
                let isBusy = dotStatus == .connecting || dotStatus == .disconnecting
                statusDot?.isHidden = dotStatus == .none || isBusy
                statusDot?.layer?.backgroundColor = Self.dotColor(dotStatus)?.cgColor
                statusSpinner?.isHidden = !isBusy
                if isBusy { statusSpinner?.startAnimation(nil) } else { statusSpinner?.stopAnimation(nil) }
            } else {
                statusDot?.isHidden = true
                statusSpinner?.isHidden = true
                statusSpinner?.stopAnimation(nil)
            }

            // Connections show the database mascot (elephant / dolphin). A custom
            // color renders it as a tinted template; otherwise the branded colors show.
            if orgItem.category == .connection, let kind = profileKind(for: orgItem),
               let mascot = NSImage(named: kind == .postgres ? "postgres" : "mysql")?.copy() as? NSImage {
                if let tint = Self.nsColor(custom) {
                    mascot.isTemplate = true
                    cell.imageView?.contentTintColor = tint
                } else {
                    mascot.isTemplate = false
                    cell.imageView?.contentTintColor = nil
                }
                cell.imageView?.image = mascot
                return cell
            }

            let (symbol, color) = Self.symbol(for: orgItem, kind: profileKind(for: orgItem), custom: custom)
            cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            cell.imageView?.contentTintColor = color
            return cell
        }

        /// The color the user assigned to this item (folder color, or profile color).
        private func currentColorName(for item: OrganizerItem) -> String? {
            switch item.category {
            case .folder: return item.color
            case .connection:
                guard let profileID = model.organizer.profileID(forNode: item.id) else { return nil }
                return model.profile(id: profileID)?.color
            default: return nil
            }
        }

        private static func makeCellView(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            textField.font = .systemFont(ofSize: 13)
            let dot = NSView()
            dot.identifier = NSUserInterfaceItemIdentifier("statusDot")
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 4
            dot.isHidden = true
            // Shown instead of the dot while connecting/disconnecting, so there's some
            // sign of life during what can otherwise look like a stuck, silent wait.
            let spinner = NSProgressIndicator()
            spinner.identifier = NSUserInterfaceItemIdentifier("statusSpinner")
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.style = .spinning
            spinner.controlSize = .mini
            spinner.isIndeterminate = true
            spinner.isHidden = true
            cell.addSubview(imageView)
            cell.addSubview(textField)
            cell.addSubview(dot)
            cell.addSubview(spinner)
            cell.imageView = imageView
            cell.textField = textField
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: dot.leadingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                dot.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                dot.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: 8),
                dot.heightAnchor.constraint(equalToConstant: 8),
                spinner.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                spinner.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                spinner.widthAnchor.constraint(equalToConstant: 12),
                spinner.heightAnchor.constraint(equalToConstant: 12),
            ])
            return cell
        }

        private static func dotColor(_ status: ConnectionDot) -> NSColor? {
            switch status {
            case .connected: .systemGreen
            case .failed: .systemRed
            case .connecting, .disconnecting, .none: nil
            }
        }

        static let palette: [(name: String, color: NSColor)] =
            ConnectionPalette.names.compactMap { name in
                ConnectionPalette.nsColor(name).map { (name: name, color: $0) }
            }

        static func nsColor(_ name: String?) -> NSColor? { ConnectionPalette.nsColor(name) }

        private static func symbol(for item: OrganizerItem, kind: DatabaseKind?, custom: String?) -> (String, NSColor?) {
            switch item.category {
            case .workspace: return ("rectangle.3.group", nil)
            case .project: return ("square.stack.3d.up.fill", nil)
            case .folder: return ("folder.fill", nsColor(custom) ?? .controlAccentColor)
            case .connection:
                let base: NSColor = switch kind {
                case .postgres: .systemBlue
                case .mysql: .systemOrange
                case nil: .secondaryLabelColor
                }
                return ("circle.fill", nsColor(custom) ?? base)
            }
        }

        // MARK: Drag & drop

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let orgItem = item as? OrganizerItem, orgItem.category != .workspace else { return nil }
            let pbItem = NSPasteboardItem()
            pbItem.setString(orgItem.id.uuidString, forType: pasteboardType)
            return pbItem
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            let ids = draggedIDs(from: info)
            guard !ids.isEmpty else { return [] }
            // Dropping on empty space (no item) means the loose level, which holds
            // connections only — a folder or workspace has nowhere to go there.
            guard let target = item as? OrganizerItem else {
                let allConnections = ids.allSatisfy { model.organizer.node(id: $0)?.isContainer == false }
                return allConnections ? .move : []
            }
            // All-or-nothing at hover time: if any one dragged item can't legally land
            // here, reject the whole drop rather than silently dropping just some of it.
            let allValid = ids.allSatisfy { id in
                target.id != id && !model.organizer.descendants(of: id).contains(target.id)
            }
            return target.isContainer && allValid ? .move : []
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                         item: Any?, childIndex index: Int) -> Bool {
            let ids = draggedIDs(from: info)
            guard !ids.isEmpty else { return false }
            let parentID = (item as? OrganizerItem)?.id ?? OrganizerDocument.looseParentID
            let ok = model.moveBatch(nodeIDs: ids, toParent: parentID, at: index >= 0 ? index : nil)
            rebuild(expandingAll: false)   // the tree may have changed even when `ok` is false
            return ok
        }

        /// The ids of every row participating in the drag — AppKit calls
        /// `pasteboardWriterForItem` once per selected row when a drag starts from a
        /// row that's part of the current (possibly multi-row) selection, so a drag
        /// carries one pasteboard item per dragged row, not just the one clicked.
        private func draggedIDs(from info: NSDraggingInfo) -> [UUID] {
            guard let items = info.draggingPasteboard.pasteboardItems else { return [] }
            return items.compactMap { $0.string(forType: pasteboardType).flatMap(UUID.init(uuidString:)) }
        }

        // MARK: Context menu

        func menu(forRow row: Int) -> NSMenu? {
            guard let outlineView else { return nil }
            let menu = NSMenu()
            guard row >= 0, let item = outlineView.item(atRow: row) as? OrganizerItem else {
                // The loose level takes connections only — no folders to organize.
                add(menu, String(localized: "New Connection"), #selector(actionNewConnection), nil)
                add(menu, String(localized: "New Workspace"), #selector(actionNewWorkspace), nil)
                return menu
            }
            if item.isContainer {
                add(menu, String(localized: "New Connection"), #selector(actionNewConnection), item)
                add(menu, String(localized: "New Folder"), #selector(actionNewFolder), item)
                if item.category == .workspace {
                    add(menu, String(localized: "New Project"), #selector(actionNewProject), item)
                }
                menu.addItem(.separator())
                if item.category == .folder {
                    menu.addItem(colorMenuItem(for: item))
                }
                add(menu, String(localized: "Rename"), #selector(actionRename), item)
            } else {
                let status = (model.organizer.profileID(forNode: item.id)).map { connectionDot($0) } ?? .none
                switch status {
                case .connected:
                    add(menu, String(localized: "Disconnect"), #selector(actionDisconnect), item)
                    add(menu, String(localized: "Reconnect"), #selector(actionReconnect), item)
                    add(menu, String(localized: "Refresh Schema"), #selector(actionIntrospect), item)
                case .connecting:
                    add(menu, String(localized: "Disconnect"), #selector(actionDisconnect), item)
                case .disconnecting:
                    break   // already tearing down — nothing useful to offer
                case .failed, .none:
                    add(menu, String(localized: "Connect"), #selector(actionConnect), item)
                }
                let queryTab = add(menu, String(localized: "New Query Tab"),
                                   #selector(actionNewQueryTab), item)
                queryTab.keyEquivalent = "t"
                queryTab.keyEquivalentModifierMask = .command
                menu.addItem(.separator())
                add(menu, String(localized: "Export…"), #selector(actionExport), item)
                add(menu, String(localized: "Import…"), #selector(actionImport), item)
                add(menu, String(localized: "Edit…"), #selector(actionEdit), item)
                menu.addItem(colorMenuItem(for: item))
            }
            add(menu, String(localized: "Delete"), #selector(actionDelete), item)
            return menu
        }

        @discardableResult
        private func add(_ menu: NSMenu, _ title: String, _ action: Selector,
                         _ item: OrganizerItem?) -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item
            menu.addItem(menuItem)
            return menuItem
        }

        private final class ColorChoice: NSObject {
            let item: OrganizerItem
            let color: String?
            init(item: OrganizerItem, color: String?) { self.item = item; self.color = color }
        }

        private func colorMenuItem(for item: OrganizerItem) -> NSMenuItem {
            let current = currentColorName(for: item)
            let parent = NSMenuItem(title: String(localized: "Color"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (name, color) in Self.palette {
                let entry = NSMenuItem(title: name.capitalized, action: #selector(actionSetColor(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = ColorChoice(item: item, color: name)
                entry.image = Self.swatch(color)
                entry.state = current == name ? .on : .off
                submenu.addItem(entry)
            }
            submenu.addItem(.separator())
            let none = NSMenuItem(title: String(localized: "None"), action: #selector(actionSetColor(_:)), keyEquivalent: "")
            none.target = self
            none.representedObject = ColorChoice(item: item, color: nil)
            none.state = current == nil ? .on : .off
            submenu.addItem(none)
            parent.submenu = submenu
            return parent
        }

        private static func swatch(_ color: NSColor) -> NSImage {
            let image = NSImage(size: NSSize(width: 12, height: 12))
            image.lockFocus()
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 12, height: 12), xRadius: 3, yRadius: 3).fill()
            image.unlockFocus()
            return image
        }

        @objc private func actionSetColor(_ sender: NSMenuItem) {
            guard let choice = sender.representedObject as? ColorChoice else { return }
            switch choice.item.category {
            case .folder:
                onSetColor(choice.item.id, choice.color)
            case .connection:
                if let profileID = model.organizer.profileID(forNode: choice.item.id) {
                    onSetConnectionColor(profileID, choice.color)
                }
            default:
                break
            }
            rebuild(expandingAll: false)
        }

        @objc private func actionEdit(_ sender: NSMenuItem) {
            if let item = sender.representedObject as? OrganizerItem { onEditConnection(item.id) }
        }

        @objc private func actionNewQueryTab(_ sender: NSMenuItem) {
            if let profileID = profileID(from: sender) { onNewQueryTab(profileID) }
        }
        @objc private func actionNewConnection(_ sender: NSMenuItem) {
            onNewConnection((sender.representedObject as? OrganizerItem)?.id)
        }
        @objc private func actionNewFolder(_ sender: NSMenuItem) {
            if let item = sender.representedObject as? OrganizerItem { onNewFolder(item.id) }
        }
        @objc private func actionNewProject(_ sender: NSMenuItem) {
            if let item = sender.representedObject as? OrganizerItem { onNewProject(item.id) }
        }
        @objc private func actionNewWorkspace(_ sender: NSMenuItem) { onNewWorkspace() }
        @objc private func actionRename(_ sender: NSMenuItem) {
            if let item = sender.representedObject as? OrganizerItem { onRename(item.id, title(for: item)) }
        }
        /// Double-clicking a connection connects it (or retries a failed/idle one),
        /// unless it's already ready or mid-connect — a plain click never connects.
        @objc func doubleClick(_ sender: Any?) {
            guard let outlineView, outlineView.clickedRow >= 0,
                  let item = outlineView.item(atRow: outlineView.clickedRow) as? OrganizerItem,
                  item.category == .connection,
                  let profileID = model.organizer.profileID(forNode: item.id) else { return }
            let dot = connectionDot(profileID)
            guard dot != .connected, dot != .connecting, dot != .disconnecting else { return }
            onConnectProfile(profileID)
        }

        /// ⌘↩ — connects every selected connection row (skipping folders/projects/
        /// workspaces and anything already connected/connecting), the keyboard
        /// equivalent of double-clicking each one.
        func connectSelection() {
            guard let outlineView else { return }
            for row in outlineView.selectedRowIndexes {
                guard let item = outlineView.item(atRow: row) as? OrganizerItem, item.category == .connection,
                      let profileID = model.organizer.profileID(forNode: item.id) else { continue }
                let dot = connectionDot(profileID)
                guard dot != .connected, dot != .connecting, dot != .disconnecting else { continue }
                onConnectProfile(profileID)
            }
        }

        @objc private func actionConnect(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? OrganizerItem else { return }
            selection.wrappedValue = item.id
            if let profileID = model.organizer.profileID(forNode: item.id) { onConnectProfile(profileID) }
        }
        @objc private func actionDisconnect(_ sender: NSMenuItem) {
            if let profileID = profileID(from: sender) { onDisconnect(profileID) }
        }
        @objc private func actionReconnect(_ sender: NSMenuItem) {
            if let profileID = profileID(from: sender) { onReconnect(profileID) }
        }
        @objc private func actionIntrospect(_ sender: NSMenuItem) {
            if let profileID = profileID(from: sender) { onIntrospect(profileID) }
        }
        @objc private func actionExport(_ sender: NSMenuItem) {
            if let profileID = profileID(from: sender) { onExport(profileID) }
        }
        @objc private func actionImport(_ sender: NSMenuItem) {
            if let profileID = profileID(from: sender) { onImport(profileID) }
        }
        private func profileID(from sender: NSMenuItem) -> UUID? {
            guard let item = sender.representedObject as? OrganizerItem else { return nil }
            return model.organizer.profileID(forNode: item.id)
        }
        @objc private func actionDelete(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? OrganizerItem else { return }
            let isWorkspace = model.organizer.workspaces.contains { $0.id == item.id }
            let isContainer = isWorkspace || model.organizer.node(id: item.id)?.children != nil
            let summary = model.deletionSummary(item.id)

            // A connection, or an empty container, has nothing to lose — delete it.
            guard isContainer, !summary.isEmpty else {
                model.delete(id: item.id)
                rebuild(expandingAll: false)
                return
            }
            guard let remove = confirmDelete(item, isWorkspace: isWorkspace,
                                             connections: summary.connections) else { return }
            model.deleteContainer(item.id, removingContents: remove)
            rebuild(expandingAll: false)
        }

        /// Asks what to do with a non-empty container. Returns whether to delete the
        /// contents too, or nil when the user cancelled.
        private func confirmDelete(_ item: OrganizerItem, isWorkspace: Bool,
                                   connections: Int) -> Bool? {
            let name = model.name(forNode: item.id) ?? ""
            // A workspace has no parent to promote children to, so they move to another
            // workspace — and if it is the last one, they cannot be kept at all.
            let moveTarget = isWorkspace ? model.fallbackWorkspaceName(excluding: item.id) : nil
            let canKeepContents = !isWorkspace || moveTarget != nil

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Delete “\(name)”?")
            var detail = connections > 0 ? String(localized: "\(connections) connections inside.") : ""
            if canKeepContents {
                detail += " " + (moveTarget.map {
                    String(localized: "Unless you remove them, its contents move to “\($0)”.")
                } ?? String(localized: "Unless you remove them, its contents move up one level."))
            } else {
                detail += " " + String(localized: "This is the last workspace, so its contents go too.")
            }
            alert.informativeText = detail.trimmingCharacters(in: .whitespaces)

            let checkbox = NSButton(
                checkboxWithTitle: String(localized: "Remove nested folders and connections"),
                target: nil, action: nil)
            checkbox.state = canKeepContents ? .off : .on
            checkbox.isEnabled = canKeepContents
            checkbox.sizeToFit()
            alert.accessoryView = checkbox

            alert.addButton(withTitle: String(localized: "Delete"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            return checkbox.state == .on
        }
    }
}
