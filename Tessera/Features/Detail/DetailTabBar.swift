import SwiftUI

/// The horizontal strip of query/data/diagram tab chips plus the "+" button,
/// at the top of the detail column. Each chip wears its connection's colour and
/// carries an unsaved-changes dot; middle-click or the × closes it.
struct DetailTabBar: View {
    @Bindable var model: QueryConsoleModel
    @State private var hoveredTabID: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(model.tabs) { tab in
                    tabChip(tab)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                Button {
                    model.addTab()
                } label: {
                    Image(systemName: "plus").padding(.horizontal, 8)
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            // Opening/closing a tab slides its neighbours over instead of snapping.
            .animation(.snappy(duration: 0.2), value: model.tabs.map(\.id))
        }
        .frame(height: 34)
    }

    private func chipIcon(_ tab: QueryTab) -> String {
        switch tab.kind {
        case .console: "terminal"
        case .data: "tablecells"
        case .diagram: "point.3.connected.trianglepath.dotted"
        }
    }

    private func tabChip(_ tab: QueryTab) -> some View {
        let isActive = tab.id == model.activeTabID
        // Label each tab with its connection when more than one is open, so the same
        // table from staging vs production is distinguishable.
        let showConnection = model.sessions.count > 1
        return HStack(spacing: 6) {
            if tab.isRunning {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: chipIcon(tab))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if showConnection, let session = tab.session {
                Circle().fill(connectionColor(session)).frame(width: 7, height: 7)
            }
            Text(tab.title)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
            if tab.hasEdits {
                // Uncommitted changes — the editor-world "unsaved" dot.
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
        // Capture only the tab's id here, never the `QueryTab` itself: SwiftUI keeps
        // the context-menu responder alive past the tab's removal and tears it down
        // lazily on a later hover, so a captured `QueryTab` would be released a second
        // time during that teardown (a use-after-free crash in QueryTab.deinit).
        .contextMenu { tabMenu(tab.id) }
    }

    /// The tab's connection dot reflects live status: green connected, yellow
    /// connecting, red failed, grey disconnected.
    private func connectionColor(_ session: ConnectionSession) -> Color {
        switch session.status {
        case .ready: .green
        case .connecting: .yellow
        case .failed: .red
        case .idle: .secondary
        }
    }

    /// The colour the user tagged this tab's connection with, if any.
    private func connectionTint(_ tab: QueryTab) -> Color? {
        ConnectionPalette.color(tab.session?.colorName)
    }

    /// Every tab wears its connection's colour; the active one noticeably stronger
    /// (plus a stroke), inactive ones dimmed — so the colour identifies the
    /// connection everywhere, and intensity identifies the active tab.
    private func tabChipFill(isActive: Bool, tint: Color?, isHovered: Bool) -> AnyShapeStyle {
        // Untinted tabs fall back to the accent colour, so the active chip
        // always reads as the selected one (the mockups' blue chip).
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
            .disabled(model.tabs.count < 2)
        Button("Close All Tabs") { model.closeAllTabs() }
        Divider()
        Button("Close Tabs to the Left") { model.closeTabsToLeft(of: tabID) }
            .disabled(!model.hasTabs(toLeftOf: tabID))
        Button("Close Tabs to the Right") { model.closeTabsToRight(of: tabID) }
            .disabled(!model.hasTabs(toRightOf: tabID))
    }
}
