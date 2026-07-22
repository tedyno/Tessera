import SwiftUI
import DBKit

/// The ER-diagram tab: toolbar (connected-only filter, re-layout, zoom, PNG
/// export) over the AppKit canvas.
struct DiagramTabView: View {
    @Bindable var model: DiagramModel
    var onOpenTable: (String, String) -> Void
    /// Table-scoped diagrams offer a jump to the full schema diagram.
    var onShowWholeSchema: () -> Void = { }

    /// The scroll view's magnification range, shared with the zoom slider.
    static let zoomRange: ClosedRange<CGFloat> = 0.25...3.0

    @State private var zoomToFitToken = 0
    /// Mirror of the scroll view's magnification — the slider writes it, and
    /// pinch/⌘-scroll/⌘± changes flow back via the clip-bounds observer.
    @State private var zoom: CGFloat = 1
    @State private var canvas: DiagramCanvasView?
    @State private var exportError: String?
    @AppStorage("tessera.diagram.edgeStyle") private var edgeStyleRaw = DiagramEdgeStyle.curved.rawValue
    @AppStorage("tessera.diagram.background") private var backgroundRaw = DiagramBackgroundStyle.plain.rawValue

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.entities.isEmpty {
                ContentUnavailableView("No tables in this schema",
                                       systemImage: "point.3.connected.trianglepath.dotted")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack(alignment: .bottomTrailing) {
                    DiagramCanvasRepresentable(model: model,
                                               zoomToFitToken: zoomToFitToken,
                                               zoom: $zoom,
                                               edgeStyle: DiagramEdgeStyle(rawValue: edgeStyleRaw) ?? .curved,
                                               backgroundStyle: DiagramBackgroundStyle(rawValue: backgroundRaw) ?? .plain,
                                               onOpenTable: onOpenTable,
                                               onCanvasReady: { canvas = $0 })
                    stylePill
                }
            }
        }
        .alert(Text("Export failed"), isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: exportError ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Label {
                Text(verbatim: model.schemaName)
            } icon: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
            }
            .font(.callout.weight(.semibold))
            Spacer()
            Toggle("Keys only", isOn: $model.showKeysOnly)
                .toggleStyle(.checkbox)
                .font(.caption)
            if model.scope == .schema {
                Toggle("Only connected tables", isOn: $model.showOnlyConnected)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            } else {
                Button("Show Whole Schema") { onShowWholeSchema() }
                    .font(.caption)
            }
            Button("Re-layout") { model.performLayout() }
                .font(.caption)
            Button("Zoom to Fit") { zoomToFitToken += 1 }
                .font(.caption)
            Button("Export PNG…") { exportPNG() }
                .font(.caption)
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    /// Floating appearance controls in the canvas corner: edge routing on top,
    /// backdrop below — always at hand without reaching for the toolbar.
    private var stylePill: some View {
        VStack(spacing: 5) {
            pillButton("point.topleft.down.curvedto.point.bottomright.up", help: "Curved",
                       isOn: edgeStyleRaw == DiagramEdgeStyle.curved.rawValue) {
                edgeStyleRaw = DiagramEdgeStyle.curved.rawValue
            }
            pillButton("arrow.turn.down.right", help: "Right-angled",
                       isOn: edgeStyleRaw == DiagramEdgeStyle.orthogonal.rawValue) {
                edgeStyleRaw = DiagramEdgeStyle.orthogonal.rawValue
            }
            Divider().frame(width: 16)
            pillButton("square", help: "Plain",
                       isOn: backgroundRaw == DiagramBackgroundStyle.plain.rawValue) {
                backgroundRaw = DiagramBackgroundStyle.plain.rawValue
            }
            pillButton("circle.grid.3x3.fill", help: "Dots",
                       isOn: backgroundRaw == DiagramBackgroundStyle.dots.rawValue) {
                backgroundRaw = DiagramBackgroundStyle.dots.rawValue
            }
            pillButton("grid", help: "Grid",
                       isOn: backgroundRaw == DiagramBackgroundStyle.grid.rawValue) {
                backgroundRaw = DiagramBackgroundStyle.grid.rawValue
            }
            Divider().frame(width: 16)
            pillButton("plus.magnifyingglass", help: "Zoom in", isOn: false) {
                zoom = min(zoom * 1.25, Self.zoomRange.upperBound)
            }
            zoomSlider
            pillButton("minus.magnifyingglass", help: "Zoom out", isOn: false) {
                zoom = max(zoom / 1.25, Self.zoomRange.lowerBound)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 5)
        .glassEffect(.regular, in: Capsule())
        .padding(14)
    }

    /// Vertical zoom slider in log space, so equal travel feels like an equal
    /// zoom factor at both ends of the range.
    private var zoomSlider: some View {
        Slider(value: Binding(get: { log2(zoom) },
                              set: { zoom = pow(2, $0) }),
               in: log2(Self.zoomRange.lowerBound)...log2(Self.zoomRange.upperBound))
            .controlSize(.mini)
            .labelsHidden()
            .frame(width: 64)
            .rotationEffect(.degrees(-90))
            .frame(width: 24, height: 64)
    }

    private func pillButton(_ icon: String, help: LocalizedStringKey, isOn: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .background(isOn ? Color.accentColor.opacity(0.16) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Renders the full canvas (at the display's backing scale, so Retina gets
    /// a 2× PNG) into a file, mirroring the result-export flow — same default
    /// folder, timestamped name, reveal-in-Finder preference. Unaffected by the
    /// current zoom: magnification scales the clip view, not the canvas bounds.
    private func exportPNG() {
        guard let canvas else { return }
        let panel = NSSavePanel()
        panel.directoryURL = ExportSettings.directory
        panel.nameFieldStringValue = ExportSettings.fileName(base: "\(model.schemaName)-erd",
                                                            extension: "png")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.contentRect) else {
            exportError = String(localized: "The diagram could not be rendered.")
            return
        }
        canvas.cacheDisplay(in: canvas.contentRect, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            exportError = String(localized: "The diagram could not be rendered.")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            if ExportSettings.revealAfterExport {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            exportError = error.localizedDescription
        }
    }
}

/// Wraps the canvas in an `NSScrollView` with native magnification — the
/// codebase convention for heavy custom surfaces.
private struct DiagramCanvasRepresentable: NSViewRepresentable {
    let model: DiagramModel
    let zoomToFitToken: Int
    @Binding var zoom: CGFloat
    let edgeStyle: DiagramEdgeStyle
    let backgroundStyle: DiagramBackgroundStyle
    var onOpenTable: (String, String) -> Void
    var onCanvasReady: (DiagramCanvasView) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let canvas = DiagramCanvasView()
        canvas.model = model
        canvas.onOpenTable = onOpenTable
        canvas.edgeStyle = edgeStyle
        canvas.backgroundStyle = backgroundStyle

        let scroll = NSScrollView()
        scroll.documentView = canvas
        // No scrollers: the canvas navigates like a map (drag pan, pinch,
        // ⌘-scroll, ⌘±, zoom slider) and legacy scrollers would overlay the
        // floating style/zoom controls.
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.allowsMagnification = true
        scroll.minMagnification = DiagramTabView.zoomRange.lowerBound
        scroll.maxMagnification = DiagramTabView.zoomRange.upperBound
        scroll.drawsBackground = true
        scroll.backgroundColor = .underPageBackgroundColor

        // Magnification has no direct change callback, but every zoom resizes
        // the clip view's bounds — observe those to keep the slider in sync
        // with pinch/⌘-scroll/⌘± zooming.
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        context.coordinator.scroll = scroll
        context.coordinator.zoom = $zoom
        context.coordinator.boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated { coordinator?.magnificationChanged() }
        }

        canvas.render()
        let ready = onCanvasReady
        Task { @MainActor in ready(canvas) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let canvas = scroll.documentView as? DiagramCanvasView else { return }
        canvas.model = model
        canvas.onOpenTable = onOpenTable
        canvas.edgeStyle = edgeStyle
        canvas.backgroundStyle = backgroundStyle
        canvas.render()
        context.coordinator.zoom = $zoom
        if context.coordinator.lastZoomToken != zoomToFitToken {
            context.coordinator.lastZoomToken = zoomToFitToken
            scroll.magnify(toFit: canvas.contentRect)
        } else if abs(scroll.magnification - zoom) > 0.0005 {
            // The slider (or ± buttons) moved: zoom around the viewport centre.
            scroll.setMagnification(zoom, centeredAt: NSPoint(x: canvas.visibleRect.midX,
                                                              y: canvas.visibleRect.midY))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var lastZoomToken = 0
        var zoom: Binding<CGFloat> = .constant(1)
        weak var scroll: NSScrollView?
        /// `nonisolated(unsafe)`: only ever touched on the main thread, but the
        /// (nonisolated) deinit must be able to remove the observer.
        nonisolated(unsafe) var boundsObserver: NSObjectProtocol?

        /// Pushes the live magnification back into SwiftUI state. Deferred a
        /// tick: bounds changes can land mid-view-update (e.g. from
        /// `magnify(toFit:)` inside `updateNSView`).
        func magnificationChanged() {
            guard let scroll else { return }
            let magnification = scroll.magnification
            guard abs(magnification - zoom.wrappedValue) > 0.0005 else { return }
            Task { @MainActor in self.zoom.wrappedValue = magnification }
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }
    }
}
