import SwiftUI

/// The horizontal strip of tab chips for one pane (`TabGroup`) plus its "+" and,
/// when more than one pane is open, a close-pane button. Chips reorder within the
/// pane by drag, and a chip dragged onto another pane's body splits it.
struct DetailTabBar: View {
    @Bindable var model: QueryConsoleModel
    var group: TabGroup
    /// Non-nil when this pane can be closed (more than one pane exists).
    var onCloseGroup: (() -> Void)?
    @State private var hoveredTabID: UUID?

    private var tabs: [QueryTab] { model.tabs(in: group) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    if let onCloseGroup {
                        Button(action: onCloseGroup) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .padding(.trailing, 2)
                        .help("Close this pane and its tabs")
                    }
                    ForEach(tabs) { tab in
                        tabChip(tab)
                            .id(tab.id)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                    Button {
                        model.addTab(in: group)
                    } label: {
                        Image(systemName: "plus").padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderless)
                    // Drop past the last chip moves the tab to the end of this pane —
                    // from this pane (reorder) or another (move it in).
                    Color.clear
                        .frame(minWidth: 30, maxWidth: .infinity, minHeight: 1)
                        .contentShape(Rectangle())
                        .dropDestination(for: String.self) { items, _ in
                            guard let first = items.first, let dragged = UUID(uuidString: first) else { return false }
                            model.moveTab(dragged, toGroup: group, before: nil)
                            return true
                        }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .animation(.snappy(duration: 0.2), value: group.tabIDs)
            }
            .frame(height: 34)
            // Keep the active tab in view — a newly opened tab past the viewport,
            // or a partially clipped one the user just clicked, scrolls into sight.
            // Deferred a runloop: activating a tab changes its font weight (and can
            // reveal its connection label), so the chip's frame isn't final until
            // the re-layout settles; scrolling to the stale frame would do nothing.
            .onChange(of: group.activeID) { _, newID in
                scrollToActive(newID, using: proxy)
            }
            .onAppear { scrollToActive(group.activeID, using: proxy) }
        }
    }

    private func scrollToActive(_ id: UUID?, using proxy: ScrollViewProxy) {
        guard let id else { return }
        Task { @MainActor in
            withAnimation(.snappy(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private func tabChip(_ tab: QueryTab) -> some View {
        let isActive = tab.id == group.activeID
        let showConnection = model.sessions.count > 1
        return HStack(spacing: 6) {
            if tab.isRunning {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: tab.kind.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            // Always present, so a tab never loses its connection status just
            // because it isn't reconnected yet.
            StatusDot(tab.session?.status)
            Text(tab.title)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
            if tab.hasEdits {
                Circle().fill(.orange).frame(width: 6, height: 6)
                    .help("Uncommitted changes")
                    .transition(.scale.combined(with: .opacity))
            }
            if showConnection, let session = tab.session {
                Text(session.qualifiedName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(session.pathLabel)
            }
            Button {
                model.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
            .help("Close tab")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            tabChipFill(isActive: isActive, tint: connectionTint(tab), isHovered: hoveredTabID == tab.id),
            in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? (connectionTint(tab) ?? Color.accentColor).opacity(0.4) : .clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                if hovering { hoveredTabID = tab.id }
                else if hoveredTabID == tab.id { hoveredTabID = nil }
            }
        }
        .onTapGesture { model.activate(tab) }
        .overlay { MiddleClickCatcher { model.closeTab(tab.id) } }
        .contextMenu { tabMenu(tab.id) }
        // Drag to reorder within the pane, move into this pane from another (drop on
        // a chip), or split (drop on another pane's body).
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let first = items.first, let dragged = UUID(uuidString: first) else { return false }
            model.moveTab(dragged, toGroup: group, before: tab.id)
            return true
        }
    }

    private func connectionTint(_ tab: QueryTab) -> Color? {
        ConnectionPalette.color(tab.session?.colorName)
    }

    private func tabChipFill(isActive: Bool, tint: Color?, isHovered: Bool) -> AnyShapeStyle {
        let base = tint ?? Color.accentColor
        if isActive { return AnyShapeStyle(base.opacity(tint == nil ? 0.22 : 0.30)) }
        if isHovered { return AnyShapeStyle(base.opacity(tint == nil ? 0.10 : 0.16)) }
        return AnyShapeStyle(tint == nil ? Color.primary.opacity(0.04) : base.opacity(0.09))
    }

    @ViewBuilder
    private func tabMenu(_ tabID: UUID) -> some View {
        Button("Close") { model.closeTab(tabID) }
            .keyboardShortcut("w", modifiers: .command)
        Button("Close Other Tabs") { model.closeOtherTabs(tabID) }
            .disabled(group.tabIDs.count < 2)
        Button("Close All Tabs") { model.closeAllTabs() }
        Divider()
        Button("Close Tabs to the Left") { model.closeTabsToLeft(of: tabID) }
            .disabled(!model.hasTabs(toLeftOf: tabID))
        Button("Close Tabs to the Right") { model.closeTabsToRight(of: tabID) }
            .disabled(!model.hasTabs(toRightOf: tabID))
    }
}
