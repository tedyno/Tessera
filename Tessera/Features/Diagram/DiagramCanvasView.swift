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
            // Offscreen renders (MCP export) must draw the final style at once —
            // a transition frame at progress 0 would bake in the OLD routing.
            guard window != nil else { needsDisplay = true; return }
            beginStyleTransition(from: oldValue)
        }
    }
    var backgroundStyle: DiagramBackgroundStyle = .plain {
        didSet {
            guard backgroundStyle != oldValue else { return }
            guard window != nil else { needsDisplay = true; return }
            beginBackgroundTransition(from: oldValue)
        }
    }

    private var nodeViews: [String: TableNodeView] = [:]
    /// Which model the node views were built for — a swap (switching between
    /// two diagram tabs reuses this canvas) must not reuse boxes by bare table
    /// name, or `users` would keep another schema's columns.
    private weak var renderedModel: DiagramModel?
    /// Empty pannable space kept around the content on every side — the
    /// "infinite canvas" feel: the diagram floats mid-canvas instead of being
    /// pinned to the top-left corner.
    private static let canvasMargin: CGFloat = 1600
    /// Where the actual diagram content sits within the padded canvas, in view
    /// coordinates. Zoom-to-fit and PNG export target this, never `bounds`.
    private(set) var contentRect = NSRect.zero
    /// Scroll to the content centre once per shown model, so a fresh diagram
    /// opens centred in its margin.
    private var didInitialCenter = false
    /// Shift applied to model positions so every frame stays in positive
    /// coordinates (dragging can push boxes past the origin).
    private var contentOffset = CGPoint.zero
    private var dragged: (table: String, grabOffset: CGPoint)?
    /// A drag that started on empty canvas pans the scroll view like a map.
    private var panning = false
    /// Whether the closed-hand pan cursor is currently pushed (drag moved).
    private var panCursorPushed = false

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
            didInitialCenter = false
        }

        let visible = model.visibleEntities
        let visibleNames = Set(visible.map(\.name))
        for (name, view) in nodeViews where !visibleNames.contains(name) {
            view.removeFromSuperview()
            nodeViews[name] = nil
        }

        let bounds = model.contentBounds()
        contentOffset = CGPoint(x: Self.canvasMargin - bounds.origin.x,
                                y: Self.canvasMargin - bounds.origin.y)
        contentRect = NSRect(x: Self.canvasMargin, y: Self.canvasMargin,
                             width: bounds.width, height: bounds.height)
        setFrameSize(NSSize(width: bounds.width + 2 * Self.canvasMargin,
                            height: bounds.height + 2 * Self.canvasMargin))

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

        if !didInitialCenter, window != nil, enclosingScrollView != nil {
            // The same fit Default Layout performs, so a freshly opened
            // diagram and a reset one look identical. The flag only burns on
            // success — a pre-layout call (zero viewport) retries next render.
            didInitialCenter = fitContent()
        }

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

    /// Fits the content into the viewport, never magnifying past 100 % — the
    /// scale is computed here rather than via `magnify(toFit:)`, whose
    /// animated application defeats any post-hoc clamp. Returns false when
    /// the viewport has no size yet (pre-layout), so callers can retry.
    @discardableResult
    func fitContent() -> Bool {
        guard let scroll = enclosingScrollView else { return false }
        let viewport = scroll.contentView.frame.size
        let content = contentRect.insetBy(dx: -24, dy: -24)
        guard viewport.width > 0, viewport.height > 0,
              content.width > 0, content.height > 0 else { return false }
        let scale = min(viewport.width / content.width,
                        viewport.height / content.height, 1)
        scroll.setMagnification(max(scale, scroll.minMagnification),
                                centeredAt: NSPoint(x: content.midX, y: content.midY))
        // Centre explicitly — setMagnification alone doesn't scroll when the
        // magnification didn't change (the at-100 % case).
        let clip = scroll.contentView
        let origin = NSPoint(x: content.midX - clip.bounds.width / 2,
                             y: content.midY - clip.bounds.height / 2)
        clip.setBoundsOrigin(clip.constrainBoundsRect(
            NSRect(origin: origin, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
        return true
    }

    private func frame(for table: String) -> NSRect? {
        guard let model, let origin = model.positions[table],
              let entity = model.entitiesByName[table] else { return nil }
        return NSRect(origin: CGPoint(x: origin.x + contentOffset.x,
                                      y: origin.y + contentOffset.y),
                      size: model.size(of: entity))
    }

    // MARK: Edges

    /// Exports fill a real page background; the live canvas only washes the
    /// app's gradient backdrop so the diagram floats on it.
    var drawsOpaqueBackground = true

    override func draw(_ dirtyRect: NSRect) {
        if drawsOpaqueBackground {
            NSColor.underPageBackgroundColor.setFill()
        } else {
            NSColor.underPageBackgroundColor.withAlphaComponent(0.35).setFill()
        }
        dirtyRect.fill()
        if let transition = backgroundTransition {
            let t = Self.ease(transition.progress)
            drawBackdrop(transition.from, phase: t, outgoing: true, in: dirtyRect)
            drawBackdrop(backgroundStyle, phase: t, outgoing: false, in: dirtyRect)
        } else {
            drawBackdrop(backgroundStyle, phase: 1, outgoing: false, in: dirtyRect)
        }
        guard let model else { return }
        let selected = model.selectedTable
        // Unrelated edges recede when a table is selected — draw them first so
        // the highlighted ones stay on top.
        let edges = model.visibleEdges
        rebuildHopObstacles(edges)
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

    /// `phase` runs 0→1 for both directions: an incoming backdrop builds up, an
    /// `outgoing` one drains as a continuation of the same motion. The whole
    /// wave travels from the top-left corner: vertical lines arrive from the
    /// top (cascading left to right), horizontal ones from the left (cascading
    /// top to bottom) — one coherent sweep, never two fronts meeting in the
    /// middle. Dots fade.
    private func drawBackdrop(_ style: DiagramBackgroundStyle, phase: CGFloat,
                              outgoing: Bool, in rect: NSRect) {
        guard style != .plain else { return }
        if outgoing ? phase >= 1 : phase <= 0 { return }
        let step: CGFloat = 24
        let minX = (rect.minX / step).rounded(.down) * step
        let minY = (rect.minY / step).rounded(.down) * step
        switch style {
        case .plain:
            break
        case .dots:
            // Each dot fades in (and out) at its own moment — a mild diagonal
            // order with mostly random timing. Per-dot alpha is bucketed into
            // a few levels so the whole field still fills in ~10 calls.
            let buckets = 10
            var byAlpha = [NSBezierPath?](repeating: nil, count: buckets + 1)
            let anchor = window != nil ? visibleRect : bounds
            var x = minX
            while x <= rect.maxX {
                var y = minY
                while y <= rect.maxY {
                    let local = Self.dotProgress(phase, x: x, y: y, anchor: anchor)
                    let strength = outgoing ? 1 - local : local
                    let bucket = Int((strength * CGFloat(buckets)).rounded())
                    if bucket > 0 {
                        let path = byAlpha[bucket] ?? NSBezierPath()
                        path.appendOval(in: NSRect(x: x - 1, y: y - 1, width: 2, height: 2))
                        byAlpha[bucket] = path
                    }
                    y += step
                }
                x += step
            }
            for (bucket, path) in byAlpha.enumerated() {
                guard let path else { continue }
                NSColor.separatorColor
                    .withAlphaComponent(0.35 * CGFloat(bucket) / CGFloat(buckets)).set()
                path.fill()
            }
        case .grid:
            NSColor.separatorColor.withAlphaComponent(0.35).set()
            let lines = NSBezierPath()
            lines.lineWidth = 0.5
            // The flow is anchored to the viewport, not the (possibly huge)
            // canvas — and a finished phase draws unclamped, so no cached
            // mid-animation strip can ever leave the grid half-drawn. Every
            // line starts at its own moment and draws at its own pace (seeded
            // by its coordinate), so the sweep feels sketched, not mechanical.
            let anchor = window != nil ? visibleRect : bounds
            let columns = max(1, anchor.width / step)
            var x = minX
            while x <= rect.maxX {
                let local = Self.lineProgress(phase, index: (x - anchor.minX) / step,
                                              count: columns, seed: x)
                let segment: (from: CGFloat, to: CGFloat)? = if outgoing {
                    local >= 1 ? nil
                        : (max(rect.minY, anchor.minY + anchor.height * local), rect.maxY)
                } else {
                    local <= 0 ? nil
                        : (rect.minY, local >= 1 ? rect.maxY
                            : min(rect.maxY, anchor.minY + anchor.height * local))
                }
                if let segment, segment.to > segment.from {
                    lines.move(to: NSPoint(x: x, y: segment.from))
                    lines.line(to: NSPoint(x: x, y: segment.to))
                }
                x += step
            }
            let rows = max(1, anchor.height / step)
            var y = minY
            while y <= rect.maxY {
                let local = Self.lineProgress(phase, index: (y - anchor.minY) / step,
                                              count: rows, seed: y)
                let segment: (from: CGFloat, to: CGFloat)? = if outgoing {
                    local >= 1 ? nil
                        : (max(rect.minX, anchor.minX + anchor.width * local), rect.maxX)
                } else {
                    local <= 0 ? nil
                        : (rect.minX, local >= 1 ? rect.maxX
                            : min(rect.maxX, anchor.minX + anchor.width * local))
                }
                if let segment, segment.to > segment.from {
                    lines.move(to: NSPoint(x: segment.from, y: y))
                    lines.line(to: NSPoint(x: segment.to, y: y))
                }
                y += step
            }
            lines.stroke()
        }
    }

    /// While set, the backdrop draws as a cross-fade/flow between two styles.
    private var backgroundTransition: (from: DiagramBackgroundStyle, progress: CGFloat)?
    private var backgroundAnimation: Task<Void, Never>?

    private func beginBackgroundTransition(from old: DiagramBackgroundStyle) {
        backgroundAnimation?.cancel()
        backgroundTransition = (old, 0)
        needsDisplay = true
        backgroundAnimation = Task { [weak self] in
            let steps = 28   // ~0.45 s at 60 fps — room for the cascade to read
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let self else { return }
                self.backgroundTransition = (old, CGFloat(step) / CGFloat(steps))
                self.needsDisplay = true
            }
            guard let self, !Task.isCancelled else { return }
            self.backgroundTransition = nil
            self.needsDisplay = true
        }
    }

    private static func ease(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }

    /// Per-line progress: the sweep still travels across the viewport (the
    /// position term dominates the delay), but every line starts at its own
    /// moment and draws at its own speed — both seeded deterministically from
    /// its coordinate, so frames stay coherent and everything lands by phase 1.
    private static func lineProgress(_ phase: CGFloat, index: CGFloat, count: CGFloat,
                                     seed: CGFloat) -> CGFloat {
        guard phase < 1 else { return 1 }
        guard phase > 0 else { return 0 }
        let position = min(max(index / count, 0), 1)
        let delay = 0.55 * (0.65 * position + 0.35 * random01(seed))
        let duration = (1 - delay) * (0.45 + 0.55 * random01(seed + 17.3))
        return min(max((phase - delay) / duration, 0), 1)
    }

    /// Cheap deterministic 0…1 hash — stable per line, different per seed.
    private static func random01(_ seed: CGFloat) -> CGFloat {
        let value = sin(seed * 12.9898) * 43758.5453
        return value - value.rounded(.down)
    }

    /// Per-dot progress: starts are spread across most of the timeline
    /// (mostly random, a hint of diagonal order) and each dot then fades in
    /// gently over its own window — individual, but soft.
    private static func dotProgress(_ phase: CGFloat, x: CGFloat, y: CGFloat,
                                    anchor: NSRect) -> CGFloat {
        guard phase < 1 else { return 1 }
        guard phase > 0 else { return 0 }
        let diagonal = ((x - anchor.minX) / max(anchor.width, 1)
            + (y - anchor.minY) / max(anchor.height, 1)) / 2
        let delay = 0.65 * (0.25 * min(max(diagonal, 0), 1)
            + 0.75 * random01(x * 3.1 + y * 7.7))
        return min(max((phase - delay) / 0.35, 0), 1)
    }

    /// Landing in a window replays the backdrop entrance — opening a diagram
    /// tab gets the same flow-in the style switch has.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, backgroundStyle != .plain else { return }
        beginBackgroundTransition(from: .plain)
    }

    /// Torn down mid-pan (⌘W, schema refresh emptying the diagram): balance
    /// the pushed closed-hand cursor, or it sticks app-wide.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        panning = false
        if panCursorPushed {
            panCursorPushed = false
            NSCursor.pop()
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
            let t = Self.ease(transition.progress)
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
                for (a, b) in zip(points, points.dropFirst()) {
                    // Horizontal runs hop over vertical runs of *other* edges, so a
                    // crossing reads as a bridge, not a merge. Verticals draw
                    // straight (they're the ones hopped over).
                    if abs(a.y - b.y) < 0.5, abs(a.x - b.x) > 0.5 {
                        appendHorizontal(path, from: a, to: b, edgeIndex: lane)
                    } else {
                        path.line(to: b)
                    }
                }
            }
        }
        path.stroke()

        drawStartMark(at: geo.start, dir: geo.startDir, edge: edge, lineWidth: path.lineWidth)
        drawEndMark(at: geo.end, dir: geo.endDir, edge: edge, lineWidth: path.lineWidth)
    }



    // MARK: Line hops

    /// Vertical runs of every edge, so a horizontal run can bridge over the ones
    /// that belong to *other* edges. Rebuilt each draw pass; only populated for
    /// the orthogonal style outside a style transition (curved edges and morphs
    /// have no axis-aligned runs to cross cleanly).
    private var hopVerticals: [(x: CGFloat, y0: CGFloat, y1: CGFloat, edge: Int)] = []

    private func rebuildHopObstacles(_ edges: [DiagramModel.Edge]) {
        hopVerticals.removeAll(keepingCapacity: true)
        guard edgeStyle == .orthogonal, styleTransition == nil else { return }
        for (index, edge) in edges.enumerated() {
            guard let geo = geometry(for: edge, lane: index),
                  case .polyline(let points) = geo.path else { continue }
            for (a, b) in zip(points, points.dropFirst())
            where abs(a.x - b.x) < 0.5 && abs(a.y - b.y) > 0.5 {
                hopVerticals.append((x: a.x, y0: min(a.y, b.y), y1: max(a.y, b.y), edge: index))
            }
        }
    }

    /// Extends `path` along a horizontal run, arching a small semicircular hop
    /// over each vertical run of another edge it crosses. `path` must already be
    /// positioned at `a`.
    private func appendHorizontal(_ path: NSBezierPath, from a: NSPoint, to b: NSPoint,
                                  edgeIndex: Int) {
        let radius: CGFloat = 5
        let dir: CGFloat = b.x >= a.x ? 1 : -1
        let lo = min(a.x, b.x), hi = max(a.x, b.x)
        // Crossing x-positions, far enough from the run's ends to leave a straight
        // stub on either side of the bridge.
        var crossings = hopVerticals
            .filter { $0.edge != edgeIndex
                && a.y > $0.y0 + 1 && a.y < $0.y1 - 1
                && $0.x > lo + radius && $0.x < hi - radius }
            .map(\.x)
            .sorted { dir > 0 ? $0 < $1 : $0 > $1 }
        // Collapse near-coincident crossings (parallel edges sharing a corridor)
        // so their bridges don't overlap into a blob.
        crossings = crossings.reduce(into: [CGFloat]()) { kept, x in
            if let last = kept.last, abs(x - last) < 2 * radius + 1 { return }
            kept.append(x)
        }
        for cx in crossings {
            let entry = NSPoint(x: cx - dir * radius, y: a.y)
            let exit = NSPoint(x: cx + dir * radius, y: a.y)
            let lift = radius * 1.4   // control-point pull for a rounded arch
            path.line(to: entry)
            path.curve(to: exit,
                       controlPoint1: NSPoint(x: entry.x, y: entry.y + lift),
                       controlPoint2: NSPoint(x: exit.x, y: exit.y + lift))
        }
        path.line(to: b)
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
            panning = true
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
        if panning {
            guard let scroll = enclosingScrollView else { return }
            if !panCursorPushed {
                panCursorPushed = true
                NSCursor.closedHand.push()
            }
            let clip = scroll.contentView
            // Window-point deltas divided by the magnification: one screen point
            // of mouse travel moves the content one screen point at any zoom.
            var origin = clip.bounds.origin
            origin.x -= event.deltaX / scroll.magnification
            origin.y -= event.deltaY / scroll.magnification
            origin = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
            clip.setBoundsOrigin(origin)
            scroll.reflectScrolledClipView(clip)
            return
        }
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
        if panning {
            panning = false
            if panCursorPushed {
                panCursorPushed = false
                NSCursor.pop()
            }
            return
        }
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
            // Constrained: a shrunken document must not leave the viewport
            // hanging over undrawn space.
            clip.setBoundsOrigin(clip.constrainBoundsRect(
                NSRect(origin: origin, size: clip.bounds.size)).origin)
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    /// ⌘+ / ⌘− step the zoom, anchored under the mouse when it hovers the
    /// canvas (map behaviour), falling back to the viewport centre.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Exact modifier match (⇧ allowed for ⌘⇧+): a loose `.contains`
        // would swallow ⌘⌥±/⌘⌃± meant for someone else.
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard let window, !isHiddenOrHasHiddenAncestor,
              modifiers == .command || modifiers == [.command, .shift],
              let scroll = enclosingScrollView,
              let characters = event.charactersIgnoringModifiers else {
            return super.performKeyEquivalent(with: event)
        }
        let factor: CGFloat
        switch characters {
        case "+", "=": factor = 1.25
        case "-", "_": factor = 1 / 1.25
        default: return super.performKeyEquivalent(with: event)
        }
        let target = min(max(scroll.magnification * factor,
                             scroll.minMagnification), scroll.maxMagnification)
        let mouse = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let anchor = visibleRect.contains(mouse)
            ? mouse
            : NSPoint(x: visibleRect.midX, y: visibleRect.midY)
        scroll.setMagnification(target, centeredAt: anchor)
        return true
    }

    /// ⌘ + scroll zooms around the cursor, matching the map convention; plain
    /// scrolling (and trackpad pinch, via `allowsMagnification`) stays native.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command),
              let scroll = enclosingScrollView else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * 8
        let proposed = scroll.magnification * pow(1.0035, delta)
        let magnification = min(max(proposed, scroll.minMagnification),
                                scroll.maxMagnification)
        scroll.setMagnification(magnification,
                                centeredAt: convert(event.locationInWindow, from: nil))
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
