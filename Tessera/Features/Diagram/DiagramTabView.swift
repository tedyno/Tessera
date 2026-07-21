import SwiftUI
import DBKit

/// The ER-diagram tab: toolbar (connected-only filter, re-layout, zoom, PNG
/// export) over the AppKit canvas.
struct DiagramTabView: View {
    @Bindable var model: DiagramModel
    var onOpenTable: (String, String) -> Void
    /// Table-scoped diagrams offer a jump to the full schema diagram.
    var onShowWholeSchema: () -> Void = { }

    @State private var zoomToFitToken = 0
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
                DiagramCanvasRepresentable(model: model,
                                           zoomToFitToken: zoomToFitToken,
                                           edgeStyle: DiagramEdgeStyle(rawValue: edgeStyleRaw) ?? .curved,
                                           backgroundStyle: DiagramBackgroundStyle(rawValue: backgroundRaw) ?? .plain,
                                           onOpenTable: onOpenTable,
                                           onCanvasReady: { canvas = $0 })
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
            Menu {
                Picker("Edges", selection: $edgeStyleRaw) {
                    Text("Curved").tag(DiagramEdgeStyle.curved.rawValue)
                    Text("Right-angled").tag(DiagramEdgeStyle.orthogonal.rawValue)
                }
                Picker("Background", selection: $backgroundRaw) {
                    Text("Plain").tag(DiagramBackgroundStyle.plain.rawValue)
                    Text("Dots").tag(DiagramBackgroundStyle.dots.rawValue)
                    Text("Grid").tag(DiagramBackgroundStyle.grid.rawValue)
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Diagram appearance")
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
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
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            exportError = String(localized: "The diagram could not be rendered.")
            return
        }
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
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
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.25
        scroll.maxMagnification = 3.0
        scroll.drawsBackground = true
        scroll.backgroundColor = .underPageBackgroundColor

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
        if context.coordinator.lastZoomToken != zoomToFitToken {
            context.coordinator.lastZoomToken = zoomToFitToken
            scroll.magnify(toFit: canvas.frame)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var lastZoomToken = 0
    }
}
