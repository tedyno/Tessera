import SwiftUI
import DBKit

/// The horizontal strip of tab chips for one pane (`TabGroup`) plus its "+" and,
/// when more than one pane is open, a close-pane button. Chips reorder within the
/// pane by drag, move into another pane by dropping on its strip, and split a pane
/// by dropping on its body.
///
/// The drag is driven by the app rather than by system drag & drop — see
/// `TabDragState` for why — so this view's job is to measure itself into that
/// state, open a gap where the tab would land, and hide the chip in flight.
struct DetailTabBar: View {
    @Bindable var model: QueryConsoleModel
    var group: TabGroup
    /// Shared with every other pane, so a chip can travel between strips.
    var drag: TabDragState
    /// Non-nil when this pane can be closed (more than one pane exists).
    var onCloseGroup: (() -> Void)?
    @State private var hoveredTabID: UUID?
    @State private var chipFrames: [UUID: CGRect] = [:]
    @State private var stripFrame: CGRect = .zero

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
                    // The empty run past the last chip: releasing here puts the tab
                    // at the end of this pane, so it opens a gap of its own.
                    Color.clear
                        .frame(minWidth: 30, maxWidth: .infinity, minHeight: 1)
                        .padding(.leading, drag.insertionGapAtEnd(inGroup: group.id) ? drag.gapWidth : 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .animation(.snappy(duration: 0.2), value: group.tabIDs)
            }
            .frame(height: 34)
            // A strip wider than the pane fades out at the ends instead of
            // slicing the first and last chip in half.
            .scrollEdgeEffectStyle(.soft, for: .horizontal)
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(TabDragState.space))
            } action: { frame in
                stripFrame = frame
                publishGeometry()
            }
            // Keep the active tab in view — a newly opened tab past the viewport,
            // or a partially clipped one the user just clicked, scrolls into sight.
            // Deferred a runloop: activating a tab changes its font weight (and can
            // reveal its connection label), so the chip's frame isn't final until
            // the re-layout settles; scrolling to the stale frame would do nothing.
            .onChange(of: group.activeID) { _, newID in
                scrollToActive(newID, using: proxy)
            }
            .onAppear { scrollToActive(group.activeID, using: proxy) }
            .onDisappear { drag.strips[group.id] = nil }
        }
    }

    /// Hands this strip's measurements to the shared drag state.
    ///
    /// The chip in flight is left out: it is collapsed to nothing on screen, and
    /// a zero-width chip still in the list would be a landing place the user
    /// can't see.
    private func publishGeometry() {
        let chips = tabs.compactMap { tab -> TabStripGeometry.Chip? in
            guard tab.id != drag.draggedID, let frame = chipFrames[tab.id] else { return nil }
            return .init(id: tab.id, frame: frame)
        }
        let geometry = TabStripGeometry(groupID: group.id, frame: stripFrame, chips: chips)
        // Every chip reports its frame on every layout pass; writing an identical
        // value back would invalidate each pane that reads this state, for nothing.
        guard drag.strips[group.id] != geometry else { return }
        drag.strips[group.id] = geometry
    }

    private func scrollToActive(_ id: UUID?, using proxy: ScrollViewProxy) {
        guard let id else { return }
        Task { @MainActor in
            // No anchor: scroll the minimum to reveal the chip — a no-op when it's
            // already fully in view, so a plain click never yanks the whole strip.
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(id)
            }
        }
    }

    private func tabChip(_ tab: QueryTab) -> some View {
        let isDragging = drag.draggedID == tab.id
        return TabChipBody(tab: tab,
                           isActive: tab.id == group.activeID,
                           showConnection: model.sessions.count > 1,
                           isHovered: hoveredTabID == tab.id,
                           onClose: { model.closeTab(tab.id) })
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    if hovering { hoveredTabID = tab.id }
                    else if hoveredTabID == tab.id { hoveredTabID = nil }
                }
            }
            .onTapGesture { model.activate(tab) }
            .overlay { MiddleClickCatcher { model.closeTab(tab.id) } }
            .contextMenu { tabMenu(tab.id) }
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(TabDragState.space))
            } action: { frame in
                chipFrames[tab.id] = frame
                publishGeometry()
            }
            // Collapsed, not removed: the gesture below lives on this view, and a
            // chip taken out of the `ForEach` mid-drag would take its own gesture
            // with it — the release would never be reported.
            .opacity(isDragging ? 0 : 1)
            .frame(width: isDragging ? 0 : nil)
            .clipped()
            // `moveTab` inserts *before* this chip, so the gap opens on its
            // leading edge: what you see during the drag is where the tab lands.
            .padding(.leading, drag.insertionGap(inGroup: group.id, before: tab.id) ? drag.gapWidth : 0)
            .gesture(chipDrag(tab))
    }

    /// The drag itself. `minimumDistance` keeps a plain click on the chip — which
    /// activates the tab — from being swallowed as a one-pixel drag.
    private func chipDrag(_ tab: QueryTab) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(TabDragState.space))
            .onChanged { value in
                if !drag.isDragging {
                    let frame = chipFrames[tab.id] ?? .zero
                    drag.begin(tab: tab.id, in: group.id, at: value.location,
                               grabOffset: CGSize(
                                   width: value.startLocation.x - frame.minX,
                                   height: value.startLocation.y - frame.minY),
                               chipSize: frame.size,
                               isActive: tab.id == group.activeID)
                    publishGeometry()   // drop the chip in flight from the targets
                }
                drag.updateTarget(to: value.location)
            }
            .onEnded { value in
                drag.updateTarget(to: value.location)
                // Let go over a slot: glide the chip into it first, and only then
                // swap it for the real one. Releasing straight into the model
                // would make the tab appear in place without ever travelling
                // there.
                if let origin = drag.landingOrigin() {
                    withAnimation(.snappy(duration: 0.22)) {
                        drag.settle(at: origin)
                    } completion: {
                        finishDrop()
                    }
                } else {
                    finishDrop()
                }
            }
    }

    /// Swaps the floating chip for the real tab, without animation: it has just
    /// glided into the gap, and the gap is exactly its width, so the model
    /// catching up changes nothing on screen. Animating here would replay the
    /// move a second time.
    private func finishDrop() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let landing = drag.end() {
                apply(landing.target, to: landing.tab)
            }
        }
        publishGeometry()
    }

    private func apply(_ target: TabDropTarget, to tabID: UUID) {
        switch target {
        case .insert(let groupID, let before):
            guard let destination = model.workspace.groups.first(where: { $0.id == groupID })
            else { return }
            model.moveTab(tabID, toGroup: destination, before: before)
        case .split(let groupID, let edge):
            // A split rebuilds the pane tree, which is a big enough change that
            // it should be seen happening.
            withAnimation(.snappy(duration: 0.2)) {
                model.splitDrop(tabID, into: groupID, edge: edge)
            }
        }
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

/// A tab chip's visuals, with no behaviour of its own.
///
/// Shared by the strip and by the copy that follows the cursor during a drag, so
/// the thing you are dragging looks exactly like the thing you picked up.
struct TabChipBody: View {
    let tab: QueryTab
    var isActive: Bool
    var showConnection: Bool
    var isHovered: Bool = false
    /// Whether the close button takes up its space. The floating copy starts
    /// without it — a close button under the cursor is a target you can't hit —
    /// and grows it back as it settles, so it reaches its slot at exactly the
    /// width of the chip it's about to become.
    var showsClose: Bool = true
    var onClose: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            // Always the kind icon — a running spinner here is a different width, so
            // a refresh would resize the chip and jitter the strip. Progress shows in
            // the results area and the toolbar instead.
            Image(systemName: tab.kind.icon)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
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
            // Always built, never conditionally inserted: collapsing its width
            // animates smoothly, whereas adding the view would pop it in.
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
            .help("Close tab")
            .frame(width: showsClose ? nil : 0)
            .opacity(showsClose ? 1 : 0)
            .clipped()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(fill, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? (tint ?? Color.accentColor).opacity(0.4) : .clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private var tint: Color? { ConnectionPalette.color(tab.session?.colorName) }

    private var fill: AnyShapeStyle {
        let base = tint ?? Color.accentColor
        if isActive { return AnyShapeStyle(base.opacity(tint == nil ? 0.22 : 0.30)) }
        if isHovered { return AnyShapeStyle(base.opacity(tint == nil ? 0.10 : 0.16)) }
        return AnyShapeStyle(tint == nil ? Color.primary.opacity(0.04) : base.opacity(0.09))
    }
}
