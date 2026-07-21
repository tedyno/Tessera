import AppKit
import DBKit

/// How FK edges are routed. Raw values back the @AppStorage preference.
enum DiagramEdgeStyle: String {
    case curved, orthogonal
}

/// Canvas backdrop. Raw values back the @AppStorage preference.
enum DiagramBackgroundStyle: String {
    case plain, dots, grid
}

/// The ER canvas document view: hosts one `TableNodeView` per table, draws the
/// FK edges beneath them, and owns all mouse interaction (select, drag,
/// double-click to open the table).
final class DiagramCanvasView: NSView {
    weak var model: DiagramModel?
    var onOpenTable: ((String, String) -> Void)?
    var edgeStyle: DiagramEdgeStyle = .curved {
        didSet {
            guard edgeStyle != oldValue else { return }
            beginStyleTransition(from: oldValue)
        }
    }
    var backgroundStyle: DiagramBackgroundStyle = .plain {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
    }

    private var nodeViews: [String: TableNodeView] = [:]
    /// Which model the node views were built for — a swap (switching between
    /// two diagram tabs reuses this canvas) must not reuse boxes by bare table
    /// name, or `users` would keep another schema's columns.
    private weak var renderedModel: DiagramModel?
    /// Shift applied to model positions so every frame stays in positive
    /// coordinates (dragging can push boxes past the origin).
    private var contentOffset = CGPoint.zero
    private var dragged: (table: String, grabOffset: CGPoint)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Rebuilds subviews and frames from the model. Skipped mid-drag — the drag
    /// handlers move the box directly, and reflowing the offset underneath the
    /// cursor would make the box jitter.
    func render() {
        guard let model, dragged == nil else { return }

        if renderedModel !== model {
            for view in nodeViews.values { view.removeFromSuperview() }
            nodeViews = [:]
            renderedModel = model
        }

        let visible = model.visibleEntities
        let visibleNames = Set(visible.map(\.name))
        for (name, view) in nodeViews where !visibleNames.contains(name) {
            view.removeFromSuperview()
            nodeViews[name] = nil
        }

        let bounds = model.contentBounds()
        contentOffset = CGPoint(x: -bounds.origin.x, y: -bounds.origin.y)
        setFrameSize(bounds.size)

        for table in visible {
            let view = nodeViews[table.name] ?? {
                let created = TableNodeView(table: table)
                nodeViews[table.name] = created
                addSubview(created)
                return created
            }()
            view.frame = frame(for: table.name) ?? .zero
            view.isSelected = model.selectedTable == table.name
            view.keysOnly = model.showKeysOnly
        }
        needsDisplay = true

        if let focus = model.focusTable {
            if let frame = frame(for: focus) {
                scrollToVisible(frame.insetBy(dx: -40, dy: -40))
            }
            // Clearing state during a SwiftUI-driven update would re-enter the
            // update; defer it a tick.
            Task { @MainActor [weak model] in
                model?.focusTable = nil
            }
        }
    }

    private func frame(for table: String) -> NSRect? {
        guard let model, let origin = model.positions[table],
              let entity = model.entitiesByName[table] else { return nil }
        return NSRect(origin: CGPoint(x: origin.x + contentOffset.x,
                                      y: origin.y + contentOffset.y),
                      size: model.size(of: entity))
    }

    // MARK: Edges

    override func draw(_ dirtyRect: NSRect) {
        // A real background (not just the scroll view showing through), so a
        // PNG export isn't transparent between the boxes.
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()
        drawBackdrop(dirtyRect)
        guard let model else { return }
        let selected = model.selectedTable
        // Unrelated edges recede when a table is selected — draw them first so
        // the highlighted ones stay on top.
        let edges = model.visibleEdges
        for (index, edge) in edges.enumerated() {
            let involved = edge.fromTable == selected || edge.toTable == selected
            if selected != nil, involved { continue }
            drawEdge(edge, highlighted: false, dimmed: selected != nil, lane: index)
        }
        if selected != nil {
            for (index, edge) in edges.enumerated()
            where edge.fromTable == selected || edge.toTable == selected {
                drawEdge(edge, highlighted: true, dimmed: false, lane: index)
            }
        }
    }

    private func drawBackdrop(_ rect: NSRect) {
        guard backgroundStyle != .plain else { return }
        let step: CGFloat = 24
        NSColor.separatorColor.withAlphaComponent(0.35).set()
        let minX = (rect.minX / step).rounded(.down) * step
        let minY = (rect.minY / step).rounded(.down) * step
        switch backgroundStyle {
        case .plain:
            break
        case .dots:
            let dots = NSBezierPath()
            var x = minX
            while x <= rect.maxX {
                var y = minY
                while y <= rect.maxY {
                    dots.appendOval(in: NSRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    y += step
                }
                x += step
            }
            dots.fill()
        case .grid:
            let lines = NSBezierPath()
            lines.lineWidth = 0.5
            var x = minX
            while x <= rect.maxX {
                lines.move(to: NSPoint(x: x, y: rect.minY))
                lines.line(to: NSPoint(x: x, y: rect.maxY))
                x += step
            }
            var y = minY
            while y <= rect.maxY {
                lines.move(to: NSPoint(x: rect.minX, y: y))
                lines.line(to: NSPoint(x: rect.maxX, y: y))
                y += step
            }
            lines.stroke()
        }
    }

    /// The connector's shape, kept as data so drawing and tooltip sampling
    /// share one source of truth.
    private enum EdgePath {
        case cubic(from: NSPoint, c1: NSPoint, c2: NSPoint, to: NSPoint)
        case polyline([NSPoint])
    }

    private struct EdgeGeometry {
        var start: NSPoint      // on the referencing box's edge
        var end: NSPoint        // on the referenced box's edge
        var startDir: CGFloat   // +1 = the path leaves the box to the right
        var endDir: CGFloat     // +1 = the path arrives from the right side
        var path: EdgePath
    }

    private func geometry(for edge: DiagramModel.Edge, lane: Int,
                          style: DiagramEdgeStyle? = nil) -> EdgeGeometry? {
        let style = style ?? edgeStyle
        guard let model,
              let fromFrame = nodeViews[edge.fromTable]?.frame,
              let toFrame = nodeViews[edge.toTable]?.frame,
              let fromEntity = model.entitiesByName[edge.fromTable],
              let toEntity = model.entitiesByName[edge.toTable] else { return nil }

        let keysOnly = model.showKeysOnly
        let fromY = fromFrame.minY
            + TableNodeView.anchorY(forColumn: edge.fromColumn, in: fromEntity, keysOnly: keysOnly)
        // Edges sharing a target column all converge on its row midline — the
        // user prefers the overlap over any fanned-out endpoints.
        let toY = toFrame.minY
            + TableNodeView.anchorY(forColumn: edge.toColumn, in: toEntity, keysOnly: keysOnly)
        let laneOffset = CGFloat(lane % 5 - 2) * 9

        if edge.fromTable == edge.toTable {
            // Self-reference: a loop off the right edge.
            let start = NSPoint(x: fromFrame.maxX, y: fromY)
            let end = NSPoint(x: toFrame.maxX, y: toY)
            let lineStart = markStart(at: start, dir: 1, edge: edge)
            let lineEnd = markEnd(at: end, dir: 1, edge: edge)
            let reach = fromFrame.maxX + 36 + abs(laneOffset)
            let path: EdgePath = style == .orthogonal
                ? .polyline([lineStart, NSPoint(x: reach, y: start.y),
                             NSPoint(x: reach, y: end.y), lineEnd])
                : .cubic(from: lineStart, c1: NSPoint(x: reach, y: start.y),
                         c2: NSPoint(x: reach, y: end.y), to: lineEnd)
            return EdgeGeometry(start: start, end: end, startDir: 1, endDir: 1, path: path)
        }

        let exitRight = toFrame.midX >= fromFrame.midX
        let start = NSPoint(x: exitRight ? fromFrame.maxX : fromFrame.minX, y: fromY)
        let end = NSPoint(x: exitRight ? toFrame.minX : toFrame.maxX, y: toY)
        let startDir: CGFloat = exitRight ? 1 : -1
        let endDir: CGFloat = exitRight ? -1 : 1
        let lineStart = markStart(at: start, dir: startDir, edge: edge)
        let lineEnd = markEnd(at: end, dir: endDir, edge: edge)

        let path: EdgePath
        switch style {
        case .curved:
            let reach = max(30, abs(end.x - start.x) / 2) + abs(laneOffset)
            path = .cubic(from: lineStart,
                          c1: NSPoint(x: start.x + startDir * reach, y: start.y),
                          c2: NSPoint(x: end.x + endDir * reach, y: end.y),
                          to: lineEnd)
        case .orthogonal:
            // Right-angled: out, across the corridor lane, in.
            var midX = (start.x + end.x) / 2 + laneOffset
            if startDir > 0 { midX = max(midX, start.x + 16) }
            else { midX = min(midX, start.x - 16) }
            path = .polyline([lineStart, NSPoint(x: midX, y: start.y),
                              NSPoint(x: midX, y: end.y), lineEnd])
        }
        return EdgeGeometry(start: start, end: end, startDir: startDir, endDir: endDir, path: path)
    }

    // MARK: Edge-style transition

    /// While set, edges draw as an interpolation between the old and the new
    /// routing; driven by a short main-actor animation task.
    private var styleTransition: (from: DiagramEdgeStyle, progress: CGFloat)?
    private var styleAnimation: Task<Void, Never>?

    private func beginStyleTransition(from old: DiagramEdgeStyle) {
        styleAnimation?.cancel()
        styleTransition = (old, 0)
        needsDisplay = true
        styleAnimation = Task { [weak self] in
            let steps = 16   // ~0.26 s at 60 fps
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let self else { return }
                self.styleTransition = (old, CGFloat(step) / CGFloat(steps))
                self.needsDisplay = true
            }
            guard let self, !Task.isCancelled else { return }
            self.styleTransition = nil
            self.needsDisplay = true
        }
    }

    /// `count` evenly spaced points along the connector, for morphing.
    private static func samples(of path: EdgePath, count: Int) -> [NSPoint] {
        switch path {
        case .cubic(let p0, let c1, let c2, let p1):
            return (0..<count).map { step in
                let t = CGFloat(step) / CGFloat(count - 1)
                let u = 1 - t
                return NSPoint(
                    x: u*u*u*p0.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*p1.x,
                    y: u*u*u*p0.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*p1.y)
            }
        case .polyline(let points):
            guard points.count > 1 else {
                return Array(repeating: points.first ?? .zero, count: count)
            }
            let segments = zip(points, points.dropFirst())
                .map { (a: $0, b: $1, length: hypot($1.x - $0.x, $1.y - $0.y)) }
            let total = segments.reduce(0) { $0 + $1.length }
            guard total > 0 else { return Array(repeating: points[0], count: count) }
            return (0..<count).map { step in
                var target = total * CGFloat(step) / CGFloat(count - 1)
                for segment in segments {
                    if target <= segment.length, segment.length > 0 {
                        let t = target / segment.length
                        return NSPoint(x: segment.a.x + (segment.b.x - segment.a.x) * t,
                                       y: segment.a.y + (segment.b.y - segment.a.y) * t)
                    }
                    target -= segment.length
                }
                return points[points.count - 1]
            }
        }
    }

    private static func mix(_ a: NSPoint, _ b: NSPoint, _ t: CGFloat) -> NSPoint {
        NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// Crow's-foot edge: the referencing (FK) end carries the "many" claw —
    /// or a single tick when the FK is unique (1:1) — and the referenced end a
    /// "one" tick, preceded by a circle when the FK is nullable (0..1).
    /// `lane` staggers parallel edges so they don't collapse onto one line.
    private func drawEdge(_ edge: DiagramModel.Edge, highlighted: Bool, dimmed: Bool, lane: Int) {
        guard let geo = geometry(for: edge, lane: lane) else { return }

        let color = highlighted
            ? NSColor.controlAccentColor
            : NSColor.secondaryLabelColor.withAlphaComponent(dimmed ? 0.2 : 0.65)
        color.setStroke()
        color.setFill()

        let path = NSBezierPath()
        path.lineWidth = highlighted ? 2 : 1
        path.lineJoinStyle = .round
        if let transition = styleTransition,
           let fromGeo = geometry(for: edge, lane: lane, style: transition.from) {
            // Mid-transition: morph between the two routings by interpolating
            // equal-length point samples of both shapes.
            let a = Self.samples(of: fromGeo.path, count: 33)
            let b = Self.samples(of: geo.path, count: 33)
            let t = transition.progress * transition.progress * (3 - 2 * transition.progress)
            path.move(to: Self.mix(a[0], b[0], t))
            for index in 1..<min(a.count, b.count) {
                path.line(to: Self.mix(a[index], b[index], t))
            }
        } else {
            switch geo.path {
            case .cubic(let from, let c1, let c2, let to):
                path.move(to: from)
                path.curve(to: to, controlPoint1: c1, controlPoint2: c2)
            case .polyline(let points):
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() { path.line(to: point) }
            }
        }
        path.stroke()

        drawStartMark(at: geo.start, dir: geo.startDir, edge: edge, lineWidth: path.lineWidth)
        drawEndMark(at: geo.end, dir: geo.endDir, edge: edge, lineWidth: path.lineWidth)
    }



    /// Where the connector line itself begins, leaving room for the claw/tick.
    private func markStart(at point: NSPoint, dir: CGFloat, edge: DiagramModel.Edge) -> NSPoint {
        NSPoint(x: point.x + dir * 11, y: point.y)
    }

    private func markEnd(at point: NSPoint, dir: CGFloat, edge: DiagramModel.Edge) -> NSPoint {
        NSPoint(x: point.x + dir * (edge.isOptional ? 20 : 12), y: point.y)
    }

    /// Referencing end: crow's foot (many) or a tick (unique FK → one).
    private func drawStartMark(at point: NSPoint, dir: CGFloat, edge: DiagramModel.Edge,
                               lineWidth: CGFloat) {
        let mark = NSBezierPath()
        mark.lineWidth = lineWidth
        if edge.isUnique {
            mark.move(to: NSPoint(x: point.x + dir * 7, y: point.y - 5))
            mark.line(to: NSPoint(x: point.x + dir * 7, y: point.y + 5))
            mark.move(to: point)
            mark.line(to: NSPoint(x: point.x + dir * 11, y: point.y))
        } else {
            let heel = NSPoint(x: point.x + dir * 11, y: point.y)
            for offset: CGFloat in [-5, 0, 5] {
                mark.move(to: heel)
                mark.line(to: NSPoint(x: point.x, y: point.y + offset))
            }
        }
        mark.stroke()
    }

    /// Referenced end: "one" tick, with an optionality circle when nullable.
    private func drawEndMark(at point: NSPoint, dir: CGFloat, edge: DiagramModel.Edge,
                             lineWidth: CGFloat) {
        let mark = NSBezierPath()
        mark.lineWidth = lineWidth
        mark.move(to: NSPoint(x: point.x + dir * 6, y: point.y - 5))
        mark.line(to: NSPoint(x: point.x + dir * 6, y: point.y + 5))
        mark.move(to: point)
        mark.line(to: NSPoint(x: point.x + dir * (edge.isOptional ? 12 : 12), y: point.y))
        mark.stroke()
        if edge.isOptional {
            let circle = NSBezierPath(ovalIn: NSRect(x: point.x + dir * 16 - 3.5,
                                                     y: point.y - 3.5, width: 7, height: 7))
            circle.lineWidth = lineWidth
            circle.stroke()
        }
    }

    // MARK: Mouse

    private func table(at point: NSPoint) -> String? {
        // Later subviews draw on top; hit-test in reverse for the visual order.
        for view in subviews.reversed() {
            if let node = view as? TableNodeView, node.frame.contains(point) {
                return node.table.name
            }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let name = table(at: point) else {
            model.selectedTable = nil
            applySelection()
            return
        }
        if event.clickCount == 2 {
            onOpenTable?(model.schemaName, name)
            return
        }
        model.selectedTable = name
        applySelection()
        if let view = nodeViews[name] {
            // Raise the grabbed box above its siblings.
            view.removeFromSuperview()
            addSubview(view)
            dragged = (name, CGPoint(x: point.x - view.frame.minX,
                                     y: point.y - view.frame.minY))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, let dragged, let view = nodeViews[dragged.table] else { return }
        let point = convert(event.locationInWindow, from: nil)
        let origin = NSPoint(x: point.x - dragged.grabOffset.x,
                             y: point.y - dragged.grabOffset.y)
        view.setFrameOrigin(origin)
        model.positions[dragged.table] = CGPoint(x: origin.x - contentOffset.x,
                                                 y: origin.y - contentOffset.y)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragged != nil else { return }
        dragged = nil
        // Reflow the canvas size around the box's new home. When the dragged
        // box redefined the content's min edge, every frame shifts by the
        // offset delta — scroll by the same delta so nothing jumps on screen.
        let before = contentOffset
        render()
        let delta = CGPoint(x: contentOffset.x - before.x, y: contentOffset.y - before.y)
        if delta != .zero, let clip = enclosingScrollView?.contentView {
            var origin = clip.bounds.origin
            origin.x += delta.x
            origin.y += delta.y
            clip.setBoundsOrigin(origin)
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    /// Selection changes redraw directly — `render()` is skipped mid-drag.
    private func applySelection() {
        guard let model else { return }
        for (name, view) in nodeViews {
            view.isSelected = model.selectedTable == name
        }
        needsDisplay = true
    }
}
