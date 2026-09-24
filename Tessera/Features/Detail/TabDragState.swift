import SwiftUI
import DBKit

/// The state behind dragging a tab chip, shared by every pane in the detail area.
///
/// Tabs used to be dragged with the system's drag & drop. That gave a drag image
/// the app couldn't control: AppKit treats the drop as a *copy* (SwiftUI offers no
/// way through `dragConfiguration`/`dropConfiguration` to say otherwise here), and
/// a copy's image always animates back to where it started — so the tab appeared
/// twice, once settled in its new slot and once flying home. Driving the drag
/// ourselves means the chip under the cursor is an ordinary view, and it simply
/// stops existing when the drag ends.
@MainActor
@Observable
final class TabDragState {
    /// The coordinate space every frame here is measured in — the detail area,
    /// so panes can be compared against each other.
    static let space = "tessera.detailArea"

    /// The tab in flight, or nil when nothing is being dragged.
    private(set) var draggedID: UUID?
    /// The pane it came from, so a drop back onto its own pane can be recognised.
    private(set) var sourceGroupID: UUID?
    /// Pointer position, in `space`.
    var location: CGPoint = .zero
    /// Pointer offset within the chip when it was grabbed, so the floating chip
    /// stays under the same point of itself rather than jumping to its corner.
    private(set) var grabOffset: CGSize = .zero
    private(set) var chipSize: CGSize = .zero
    /// Whether the tab was the active one in its pane. The floating chip has to
    /// match: an active chip's title is a heavier weight, and a heavier title is
    /// a wider chip — which would land a few points off.
    private(set) var draggedWasActive = false

    /// How wide a gap to open. The dragged chip's own width, so when it lands it
    /// fills the space exactly and nothing around it has to shuffle over.
    var gapWidth: CGFloat { chipSize.width }
    /// Where a release right now would put the tab.
    private(set) var target: TabDropTarget?
    /// True while the released chip is gliding into its slot. The floating chip
    /// grows its close button back over this stretch, so it ends the animation
    /// the same width as the real one and the swap is invisible.
    private(set) var isSettling = false

    /// Measured geometry, replaced by the panes as they lay out.
    var strips: [UUID: TabStripGeometry] = [:]
    var bodies: [UUID: PaneBodyGeometry] = [:]

    var isDragging: Bool { draggedID != nil }

    func begin(tab: UUID, in group: UUID, at point: CGPoint,
               grabOffset: CGSize, chipSize: CGSize, isActive: Bool) {
        draggedID = tab
        sourceGroupID = group
        draggedWasActive = isActive
        location = point
        self.grabOffset = grabOffset
        self.chipSize = chipSize
        updateTarget(to: point)
    }

    func updateTarget(to point: CGPoint) {
        location = point
        let resolved = TabDragTargeting.target(at: point,
                                               strips: Array(strips.values),
                                               bodies: Array(bodies.values))
        guard resolved != target else { return }
        withAnimation(.snappy(duration: 0.18)) { target = resolved }
    }

    /// Where the floating chip should come to rest — the leading edge of the gap
    /// currently held open for it, in the shared space.
    ///
    /// Only meaningful for an insert: a split has no slot to aim at yet, since
    /// the pane it lands in doesn't exist until the drop.
    func landingOrigin() -> CGPoint? {
        guard case .insert(let groupID, let before) = target,
              let strip = strips[groupID] else { return nil }
        if let before, let chip = strip.chips.first(where: { $0.id == before }) {
            // The gap sits on that chip's leading edge, so the slot starts a
            // gap's width before it.
            return CGPoint(x: chip.frame.minX - gapWidth, y: chip.frame.minY)
        }
        if let last = strip.chips.last {
            return CGPoint(x: last.frame.maxX + 3, y: last.frame.minY)
        }
        // An otherwise empty strip: its own leading inset.
        return CGPoint(x: strip.frame.minX + 6, y: strip.frame.minY + 4)
    }

    /// Slides the floating chip to `origin`, for the settle animation. The chip
    /// is drawn at `location - grabOffset`, so aim the pointer accordingly.
    func settle(at origin: CGPoint) {
        isSettling = true
        location = CGPoint(x: origin.x + grabOffset.width,
                           y: origin.y + grabOffset.height)
    }

    /// Clears the drag. Returns what it was aiming at, for the caller to apply.
    @discardableResult
    func end() -> (tab: UUID, target: TabDropTarget)? {
        defer {
            draggedID = nil
            sourceGroupID = nil
            target = nil
            isSettling = false
        }
        guard let draggedID, let target else { return nil }
        return (draggedID, target)
    }

    // MARK: Queries the views ask while a drag is in flight

    /// The gap a strip should open before `chip`, if any.
    func insertionGap(inGroup group: UUID, before chip: UUID) -> Bool {
        guard isDragging, case .insert(let groupID, let before) = target else { return false }
        return groupID == group && before == chip
    }

    /// Whether a strip should open a gap at its end.
    func insertionGapAtEnd(inGroup group: UUID) -> Bool {
        guard isDragging, case .insert(let groupID, let before) = target else { return false }
        return groupID == group && before == nil
    }

    /// The edge a pane should preview a split on, if any.
    func splitEdge(inGroup group: UUID) -> DropEdge? {
        guard isDragging, case .split(let groupID, let edge) = target,
              groupID == group else { return nil }
        return edge
    }
}
