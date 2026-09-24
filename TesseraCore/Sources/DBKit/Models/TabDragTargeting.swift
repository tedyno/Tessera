import Foundation
import CoreGraphics

/// Where a dragged tab would land if it were released now.
public enum TabDropTarget: Equatable, Sendable {
    /// Into a pane's tab strip, before the chip with this id — `nil` meaning
    /// after the last one.
    case insert(groupID: UUID, before: UUID?)
    /// Onto a pane's body, splitting it along that edge.
    case split(groupID: UUID, edge: DropEdge)
}

/// One pane's measured tab strip, in whatever coordinate space the caller shares
/// across every pane.
public struct TabStripGeometry: Equatable, Sendable {
    public let groupID: UUID
    public let frame: CGRect
    /// The pane's chips in the order they are drawn.
    public let chips: [Chip]

    public struct Chip: Equatable, Sendable {
        public let id: UUID
        public let frame: CGRect

        public init(id: UUID, frame: CGRect) {
            self.id = id
            self.frame = frame
        }
    }

    public init(groupID: UUID, frame: CGRect, chips: [Chip]) {
        self.groupID = groupID
        self.frame = frame
        self.chips = chips
    }
}

/// One pane's measured body — everything below its strip.
public struct PaneBodyGeometry: Equatable, Sendable {
    public let groupID: UUID
    public let frame: CGRect

    public init(groupID: UUID, frame: CGRect) {
        self.groupID = groupID
        self.frame = frame
    }
}

/// Turns a pointer position into the tab-drag target under it.
///
/// This is the whole decision behind dragging a tab: reorder within a strip,
/// move into another pane's strip, or split a pane. It is pure geometry on
/// purpose — the view layer measures the frames and draws the result, so the
/// rule itself can be tested without a running window.
public enum TabDragTargeting {

    /// - Parameters:
    ///   - point: pointer position, in the shared space the frames are measured in.
    ///   - strips: every open pane's tab strip.
    ///   - bodies: every open pane's content area.
    /// - Returns: the target under the pointer, or nil when it is over neither.
    public static func target(at point: CGPoint,
                              strips: [TabStripGeometry],
                              bodies: [PaneBodyGeometry]) -> TabDropTarget? {
        // Strips are tested first. They don't overlap the bodies, but a pointer
        // resting exactly on the divider between them should reorder rather than
        // split — reordering is the cheaper mistake to make.
        if let strip = strips.first(where: { $0.frame.contains(point) }) {
            return .insert(groupID: strip.groupID, before: insertion(at: point.x, in: strip))
        }
        if let body = bodies.first(where: { $0.frame.contains(point) }) {
            return .split(groupID: body.groupID, edge: edge(for: point, in: body.frame))
        }
        return nil
    }

    /// The chip a drop at `x` would land in front of: the first one whose middle
    /// lies past the pointer. Past every middle there is none, and the tab goes
    /// to the end of the strip.
    ///
    /// Midpoints rather than leading edges, so the insertion point flips when the
    /// pointer passes the centre of a chip — which is where it looks like it
    /// should flip.
    public static func insertion(at x: CGFloat, in strip: TabStripGeometry) -> UUID? {
        strip.chips.first { x < $0.frame.midX }?.id
    }

    /// The nearest edge of `frame`, treating it as four triangles meeting at the
    /// centre.
    public static func edge(for point: CGPoint, in frame: CGRect) -> DropEdge {
        let fx = (point.x - frame.minX) / max(frame.width, 1)
        let fy = (point.y - frame.minY) / max(frame.height, 1)
        let distances: [(DropEdge, CGFloat)] = [
            (.left, fx), (.right, 1 - fx), (.top, fy), (.bottom, 1 - fy),
        ]
        return distances.min { $0.1 < $1.1 }?.0 ?? .right
    }
}
